import Foundation

/// Декодирование RNNT поиском по нескольким вариантам (modified beam search, как в
/// k2/sherpa-onnx: не больше одного токена на кадр) с подсказкой терминов (hotwords,
/// contextual biasing). Жадный декод на каждом кадре сразу берёт самый вероятный токен
/// и не может передумать; здесь держатся `beamSize` версий фразы, а токены терминов из
/// словаря получают прибавку к оценке — движок выбирает «Claude», «Ozon», «ФБС», когда
/// звучание близко, вместо «клот», «озон», «пбс». Прибавка за незавершённый термин
/// снимается, если совпадение оборвалось, — полусловом ничего не протолкнуть.
///
/// Сети (joint, decoder) — через замыкания: сам поиск не знает о Core ML.
enum RNNTBeamSearch {
    struct DecoderState {
        var decOut: [Float]
        var h: [Float]
        var c: [Float]
    }

    struct Result {
        let tokens: [Int]
        let frames: [Int]   // кадр, на котором выдан каждый токен
    }

    private struct Hyp {
        var tokens: [Int]
        var frames: [Int]
        var score: Double          // log-вероятность + уже начисленные прибавки терминов
        var state: DecoderState
        var node: Int              // позиция в дереве терминов
        var partial: Double        // прибавка незавершённого совпадения (снимается при обрыве)
        var pendingToken: Int?     // токен выдан, состояние декодера ещё не обновлено
    }

    /// - joint: (кадр, dec_out) → логиты/лог-вероятности по словарю (+ blank).
    /// - decoderStep: (токен, состояние) → новое состояние.
    static func decode(frames: Int, blank: Int, beamSize: Int, initial: DecoderState,
                       hotwords: HotwordGraph?,
                       joint: (Int, [Float]) throws -> [Float],
                       decoderStep: (Int, DecoderState) throws -> DecoderState) rethrows -> Result {
        var beam = [Hyp(tokens: [], frames: [], score: 0, state: initial, node: 0, partial: 0, pendingToken: nil)]
        for t in 0..<frames {
            var candidates: [[Int]: Hyp] = [:]
            func add(_ h: Hyp) {
                if let old = candidates[h.tokens] {
                    // Один и тот же текст разными путями — вероятности складываются.
                    var merged = old.score >= h.score ? old : h
                    merged.score = logAdd(old.score, h.score)
                    candidates[h.tokens] = merged
                } else {
                    candidates[h.tokens] = h
                }
            }
            for hyp in beam {
                let lp = logSoftmax(try joint(t, hyp.state.decOut))
                var stay = hyp
                stay.score += Double(lp[blank])
                add(stay)
                for tok in topK(lp, k: beamSize, excluding: blank) {
                    var next = hyp
                    next.tokens.append(tok)
                    next.frames.append(t)
                    var delta = 0.0
                    if let g = hotwords {
                        let step = g.step(node: hyp.node, partial: hyp.partial, token: tok)
                        next.node = step.node; next.partial = step.partial; delta = step.delta
                    }
                    next.score += Double(lp[tok]) + delta
                    next.pendingToken = tok
                    add(next)
                }
            }
            beam = Array(candidates.values.sorted { $0.score > $1.score }.prefix(beamSize))
            for i in beam.indices {
                if let tok = beam[i].pendingToken {
                    beam[i].state = try decoderStep(tok, beam[i].state)
                    beam[i].pendingToken = nil
                }
            }
        }
        // Незавершённый термин в конце не должен давать прибавку.
        let best = beam.max { ($0.score - $0.partial) < ($1.score - $1.partial) }!
        return Result(tokens: best.tokens, frames: best.frames)
    }

    private static func logAdd(_ a: Double, _ b: Double) -> Double {
        let m = max(a, b)
        return m + log(exp(a - m) + exp(b - m))
    }

    /// Идемпотентно: если сеть уже отдаёт log-softmax, сумма exp равна 1 и значения не меняются.
    private static func logSoftmax(_ x: [Float]) -> [Float] {
        guard let m = x.max() else { return x }
        var sum: Float = 0
        for v in x { sum += expf(v - m) }
        let lse = m + logf(sum)
        return x.map { $0 - lse }
    }

    private static func topK(_ x: [Float], k: Int, excluding: Int) -> [Int] {
        var best: [(Int, Float)] = []
        for (i, v) in x.enumerated() where i != excluding {
            if best.count < k {
                best.append((i, v)); best.sort { $0.1 > $1.1 }
            } else if v > best[k - 1].1 {
                best[k - 1] = (i, v); best.sort { $0.1 > $1.1 }
            }
        }
        return best.map(\.0)
    }
}

/// Дерево терминов по токенам модели. Совпадение копит прибавку `bonus` за токен;
/// обрыв снимает накопленное и пробует начать заново с корня. Завершённый термин
/// фиксирует прибавку.
final class HotwordGraph {
    private struct Node { var children: [Int: Int] = [:]; var isEnd = false }
    private var nodes = [Node()]
    let bonus: Double
    private(set) var count = 0

    init(bonus: Double) { self.bonus = bonus }

    func insert(_ tokens: [Int]) {
        guard !tokens.isEmpty else { return }
        var n = 0
        for t in tokens {
            if let c = nodes[n].children[t] { n = c } else {
                nodes.append(Node()); nodes[n].children[t] = nodes.count - 1; n = nodes.count - 1
            }
        }
        if !nodes[n].isEnd { nodes[n].isEnd = true; count += 1 }
    }

    func step(node: Int, partial: Double, token: Int) -> (node: Int, partial: Double, delta: Double) {
        if let child = nodes[node].children[token] {
            return advance(to: child, partial: partial, delta: bonus)
        }
        // Обрыв: снимаем незавершённое и пробуем начать термин с этого токена.
        if node != 0, let child = nodes[0].children[token] {
            return advance(to: child, partial: 0, delta: -partial + bonus)
        }
        return (0, 0, -partial)
    }

    private func advance(to child: Int, partial: Double, delta: Double) -> (node: Int, partial: Double, delta: Double) {
        if nodes[child].isEnd {
            // Термин целиком — прибавка остаётся за гипотезой.
            return (nodes[child].children.isEmpty ? 0 : child, 0, delta)
        }
        return (child, partial + bonus, delta)
    }
}

/// Разбиение текста на куски словаря SentencePiece (unigram, Витерби по оценкам кусков) —
/// те же токены, которыми декодер пишет слово.
struct SentencePieceSegmenter {
    private let pieces: [String: (id: Int, score: Double)]
    private let maxLen: Int

    init?(vocab: [String], scores: [Double]) {
        guard !scores.isEmpty, scores.count == vocab.count else { return nil }
        var p: [String: (Int, Double)] = [:]
        for (i, s) in vocab.enumerated() where !s.isEmpty && !s.hasPrefix("<") { p[s] = (i, scores[i]) }
        pieces = p
        maxLen = p.keys.map(\.count).max() ?? 1
    }

    func encode(_ text: String) -> [Int]? {
        let s = Array("▁" + text.split(separator: " ").joined(separator: "▁"))
        let n = s.count
        var best = [Double](repeating: -.infinity, count: n + 1)
        var back = [(start: Int, id: Int)](repeating: (0, -1), count: n + 1)
        best[0] = 0
        for end in 1...n {
            for start in max(0, end - maxLen)..<end where best[start] > -.infinity {
                guard let piece = pieces[String(s[start..<end])] else { continue }
                let score = best[start] + piece.score
                if score > best[end] { best[end] = score; back[end] = (start, piece.id) }
            }
        }
        guard best[n] > -.infinity else { return nil }
        var ids: [Int] = []
        var i = n
        while i > 0 { ids.append(back[i].id); i = back[i].start }
        return ids.reversed()
    }
}
