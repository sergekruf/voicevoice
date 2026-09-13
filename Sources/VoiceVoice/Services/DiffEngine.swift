import Foundation

enum DiffOp: Equatable {
    case equal(Token)
    case insert(Token)
    case delete(Token)
    case replace(Token, Token)
}

enum DiffEngine {
    static func diff(_ a: [Token], _ b: [Token]) -> [DiffOp] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { .insert($0) } }
        if m == 0 { return a.map { .delete($0) } }

        // LCS DP comparing tokens case-insensitively for words.
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                if eq(a[i], b[j]) {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var ops: [DiffOp] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            if eq(a[i - 1], b[j - 1]) {
                ops.append(.equal(b[j - 1]))
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                ops.append(.delete(a[i - 1]))
                i -= 1
            } else {
                ops.append(.insert(b[j - 1]))
                j -= 1
            }
        }
        while i > 0 { ops.append(.delete(a[i - 1])); i -= 1 }
        while j > 0 { ops.append(.insert(b[j - 1])); j -= 1 }

        ops.reverse()
        return collapseToReplace(ops)
    }

    private static func eq(_ a: Token, _ b: Token) -> Bool {
        if a.kind != b.kind { return false }
        if a.kind == .word { return a.text.lowercased() == b.text.lowercased() }
        return a.text == b.text
    }

    /// Схлопывает блок удалений и вставок в ОДНУ замену — в том числе многословную.
    ///
    /// Раньше схлопывалась только соседняя пара delete+insert, то есть замена
    /// строго «слово на слово». Если пользователь правил «вент система» →
    /// «Вентсистема», получалось три удаления и одна вставка, и в словарь уходил
    /// огрызок вроде «система» → «Вентсистема» — правило, которое в жизни не
    /// срабатывает. Теперь соседние удаления и вставки собираются целиком, а
    /// пробелы внутри блока сохраняются: в словарь попадает «вент система» →
    /// «Вентсистема».
    ///
    /// Ограничение `maxPhraseWords`: длинные куски — это переписывание смысла, а не
    /// ослышка, такие блоки оставляем как есть (их отсеют фильтры выше по стеку).
    private static let maxPhraseWords = 3

    private static func collapseToReplace(_ ops: [DiffOp]) -> [DiffOp] {
        var result: [DiffOp] = []
        var i = 0
        while i < ops.count {
            switch ops[i] {
            case .equal, .replace:
                result.append(ops[i])
                i += 1
                continue
            case .delete, .insert:
                break
            }
            // Границы блока: идём вперёд, пока встречаются удаления и вставки.
            // Пробелы и знаки, совпавшие в обеих версиях, блок не разрывают —
            // иначе «вент система» → «Вентсистема» распалось бы на огрызки, —
            // а вот совпавшее СЛОВО означает конец правки.
            var j = i
            var lastChange = i - 1
            scan: while j < ops.count {
                switch ops[j] {
                case .delete, .insert: lastChange = j
                case .equal(let t): if t.isWord { break scan }
                case .replace: break scan
                }
                j += 1
            }
            let blockEnd = lastChange + 1
            guard blockEnd > i else { result.append(ops[i]); i += 1; continue }

            var deleted: [Token] = []
            var inserted: [Token] = []
            for op in ops[i..<blockEnd] {
                switch op {
                case .delete(let t): deleted.append(t)
                case .insert(let t): inserted.append(t)
                case .equal(let t): deleted.append(t); inserted.append(t)   // общий пробел
                case .replace(let o, let n): deleted.append(o); inserted.append(n)
                }
            }
            let dWords = deleted.filter(\.isWord).count
            let iWords = inserted.filter(\.isWord).count
            if dWords > 0, iWords > 0, dWords <= maxPhraseWords, iWords <= maxPhraseWords {
                result.append(.replace(joinedToken(deleted), joinedToken(inserted)))
            } else {
                result.append(contentsOf: ops[i..<blockEnd])
            }
            i = blockEnd
        }
        return result
    }

    /// Склеивает токены блока в один «фразовый» токен, обрезая крайние пробелы:
    /// внутренние остаются, чтобы «вент система» не превратилось в «вентсистема».
    private static func joinedToken(_ tokens: [Token]) -> Token {
        let text = tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return Token(kind: .word, text: text)
    }
}

/// High-level learner: given raw Whisper output, the text shown to the user after
/// dictionary application, and the user's final edit, produce learning signals.
struct LearningSignals {
    /// Brand-new (wrong → right) confirmations to add to the dictionary.
    let confirmations: [(wrong: String, right: String, context: String?)]
    /// Auto-applied substitutions the user reverted — penalise these.
    let rejections: [(wrong: String, right: String, context: String?)]
}

enum CorrectionLearner {
    /// Extract learning signals.
    ///
    /// - Parameters:
    ///   - raw: text from the speech-to-text engine (no dictionary applied).
    ///   - applied: text as displayed/pasted (dictionary was applied to `raw`).
    ///   - final: text after user edits.
    ///   - autoApplied: the set of (wrongLowered → right) actually applied this round,
    ///     so we can detect which were reverted.
    static func extract(
        raw: String,
        applied: String,
        final: String,
        autoApplied: [(wrong: String, right: String, context: String?)]
    ) -> LearningSignals {
        let rawTokens = Tokenizer.tokenize(raw)
        let finalTokens = Tokenizer.tokenize(final)

        let ops = DiffEngine.diff(rawTokens, finalTokens)

        var confirmations: [(wrong: String, right: String, context: String?)] = []

        // Re-walk ops to recover preceding-word context.
        var idxInRaw = 0
        for op in ops {
            switch op {
            case .equal:
                idxInRaw += 1
            case .delete:
                idxInRaw += 1
            case .insert:
                break
            case .replace(let oldT, let newT):
                let oldWord = oldT.text
                let newWord = newT.text
                if !oldWord.isEmpty && !newWord.isEmpty && oldWord.lowercased() != newWord.lowercased() {
                    let ctx = Tokenizer.previousWord(in: rawTokens, beforeIndex: idxInRaw)
                    confirmations.append((wrong: oldWord.lowercased(), right: newWord, context: ctx))
                }
                // Замена может покрывать несколько токенов оригинала («вент система»),
                // иначе контекст последующих правок съедет.
                idxInRaw += max(1, Tokenizer.tokenize(oldWord).count)
            }
        }

        // Detect rejected auto-applications: substitution was applied but user
        // reverted (the `right` token doesn't appear at the corresponding spot
        // in `final`).
        var rejections: [(wrong: String, right: String, context: String?)] = []
        let appliedTokens = Tokenizer.tokenize(applied)
        let appliedToFinalOps = DiffEngine.diff(appliedTokens, finalTokens)
        var idxInApplied = 0
        for op in appliedToFinalOps {
            switch op {
            case .equal: idxInApplied += 1
            case .delete: idxInApplied += 1
            case .insert: break
            case .replace(let oldT, _):
                let oldLower = oldT.text.lowercased()
                if let match = autoApplied.first(where: { $0.right.lowercased() == oldLower }) {
                    rejections.append(match)
                }
                idxInApplied += 1
            }
        }

        return LearningSignals(confirmations: confirmations, rejections: rejections)
    }
}
