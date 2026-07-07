import Foundation
import CoreML
import Tokenizers

/// On-device Russian punctuation + capitalization restoration via RUPunct_small
/// (rubert-tiny2 token-classifier, ~56 МБ Core ML). Takes lowercased, unpunctuated
/// text and returns it with punctuation and casing restored. Token-classifier =
/// cannot hallucinate/rewrite words. ANY failure falls back to the input text.
///
/// Model + tokenizer are bundled in Resources/RUPunct and loaded lazily. The .mlpackage
/// is compiled to .mlmodelc on first use and cached in Application Support.
@MainActor
final class RUPunctService {
    static let shared = RUPunctService()
    private init() {}

    enum State: Equatable { case notLoaded, loading, ready, failed }
    private(set) var state: State = .notLoaded

    // NB: qualify with the module — VoiceVoice has its own `enum Tokenizer` (word
    // tokenizer for diffing), which would otherwise shadow this protocol.
    private var tokenizer: (any Tokenizers.Tokenizer)?
    private var model: MLModel?
    private var loadTask: Task<Void, Never>?
    private var labelMap: [Int: String] = [:]

    /// Words per inference window — keeps token count safely under the model's 512 cap
    /// (Russian ≈ 2.5–3 wordpiece tokens/word, so 120 words ≈ 300–360 tokens, margin to
    /// spare). Большое окно → типичная диктовка обрабатывается ОДНИМ куском, без
    /// внутренних стыков-окон (на них модель могла ставить лишние заглавные).
    private let windowWords = 120

    private struct Err: LocalizedError { let m: String; var errorDescription: String? { m } }

    func ensureLoaded() {
        if state == .ready || state == .loading { return }
        loadTask = Task { await load() }
    }

    private func load() async {
        state = .loading
        DebugLog.log("RUPunct: load() begin")
        do {
            guard let folder = Bundle.module.url(forResource: "RUPunct", withExtension: nil) else {
                throw Err(m: "RUPunct resource folder not found in bundle")
            }
            labelMap = Self.loadLabels(folder: folder)
            guard !labelMap.isEmpty else { throw Err(m: "labels.json empty/missing") }

            tokenizer = try await AutoTokenizer.from(modelFolder: folder)

            // Модель — первый *.mlpackage в папке ресурсов: имя не зашито, чтобы
            // small/medium/big менялись простой заменой файла (+ токенизатор/labels).
            let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let mlpkg = contents.first(where: { $0.pathExtension == "mlpackage" }) else {
                throw Err(m: "no .mlpackage in RUPunct resources (нейро-пунктуация недоступна)")
            }
            DebugLog.log("RUPunct: using model \(mlpkg.lastPathComponent)")
            // Compile .mlpackage → .mlmodelc once, cache it (имя кэша — от имени пакета).
            let cached = AppPaths.appSupportDir.appendingPathComponent(
                mlpkg.deletingPathExtension().lastPathComponent + ".mlmodelc")
            let compiled: URL
            if FileManager.default.fileExists(atPath: cached.path) {
                compiled = cached
            } else {
                DebugLog.log("RUPunct: compiling model (first run)…")
                let tmp = try await MLModel.compileModel(at: mlpkg)
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.copyItem(at: tmp, to: cached)
                compiled = cached
            }
            model = try MLModel(contentsOf: compiled)
            state = .ready
            DebugLog.log("RUPunct: ready")
        } catch {
            DebugLog.log("RUPunct: load FAILED — \(error.localizedDescription)")
            state = .failed
        }
        loadTask = nil
    }

    /// Restore punctuation + casing. Returns the input unchanged on any failure.
    func punctuate(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        ensureLoaded()
        while state == .loading || state == .notLoaded {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard state == .ready, let tok = tokenizer, let model else { return text }

        let words = normalizeInput(trimmed).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return text }

        var pieces: [String] = []
        var i = 0
        while i < words.count {
            let end = min(i + windowWords, words.count)
            let windowWordsArr = Array(words[i..<end])
            let chunkText = windowWordsArr.joined(separator: " ")
            guard let punct = try? infer(chunkText, tokenizer: tok, model: model), !punct.isEmpty else {
                pieces.append(chunkText)   // fallback for this window
                i = end
                continue
            }
            let isLast = end >= words.count
            let outWords = punct.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            // Карри-овер: режем окно на ГРАНИЦЕ ПРЕДЛОЖЕНИЯ (последний терминатор в выводе),
            // а недописанное хвостовое предложение переносим в следующее окно — иначе на
            // стыке 120-го слова получался ложный разрыв «…обсудили. Поставки…».
            // RUPunct помечает каждое входное слово ровно одним выходным → индексы 1:1.
            // Ищем последний терминатор СРЕДИ ВСЕХ КРОМЕ ПОСЛЕДНЕГО слова: модель всегда
            // ставит точку на последнем слове окна искусственно (это не настоящая граница).
            var lastTerm = -1
            if !isLast, outWords.count == windowWordsArr.count, outWords.count >= 2 {
                for k in 0..<(outWords.count - 1) where outWords[k].last.map({ ".!?…".contains($0) }) == true {
                    lastTerm = k
                }
            }
            if !isLast, lastTerm >= 0 {
                pieces.append(outWords[0...lastTerm].joined(separator: " "))
                i += (lastTerm + 1)   // переносим хвост (raw-слова) в следующее окно
            } else {
                pieces.append(punct)  // последнее окно, или нет внутренней границы → целиком
                i = end
            }
        }
        let result = postFix(pieces.joined(separator: " ").trimmingCharacters(in: .whitespaces))
        return result.isEmpty ? text : result
    }

    // MARK: - Post-fix (small-model artifacts)

    /// Служебные слова, которые в середине предложения ВСЕГДА со строчной. Если модель
    /// влепила им заглавную без точки перед ними — понижаем. Имена собственные сюда не
    /// входят, их регистр не трогаем.
    private static let commonLowercaseWords: Set<String> = [
        "у", "я", "мы", "вы", "ты", "он", "она", "оно", "они", "мне", "меня", "мной",
        "тебя", "тебе", "тобой", "его", "ему", "им", "ее", "ей", "их", "ими", "нам",
        "нас", "нами", "вам", "вас", "вами", "это", "этот", "эта", "эти", "этого",
        "этом", "тот", "та", "то", "те", "того", "том", "и", "а", "но", "да", "же",
        "бы", "ли", "не", "ни", "в", "во", "на", "с", "со", "по", "к", "ко", "о", "об",
        "обо", "из", "от", "до", "за", "под", "над", "при", "про", "для", "без", "через",
        "между", "около", "что", "чтобы", "чтоб", "как", "когда", "если", "или", "чем",
        "где", "куда", "откуда", "там", "тут", "здесь", "уже", "еще", "очень", "просто",
        "только", "больше", "меньше", "тоже", "также", "хотя", "пока", "раз", "ведь",
        "потом", "затем", "значит", "давай", "давайте", "вот", "ну", "так",
    ]

    /// Слова, заглавная у которых в середине текста почти наверняка значит ПРОПУЩЕННУЮ
    /// точку (начало нового предложения), а не ошибку регистра → ставим точку перед ними,
    /// заглавную оставляем. Местоимения/указатели/открыватели.
    private static let sentenceStarters: Set<String> = [
        "я", "мы", "вы", "ты", "он", "она", "оно", "они", "это", "этот", "эта", "эти",
        "тот", "та", "те", "там", "тут", "здесь", "теперь", "потом", "затем", "значит",
        "давай", "давайте", "итак", "кстати",
    ]
    /// Притяжательные — чтобы «у» трактовать как начало предложения только в «У меня/
    /// У него…», а не как предлог «у двери».
    private static let possessiveAfterU: Set<String> = [
        "меня", "него", "нее", "нас", "них", "тебя", "вас", "вашего", "моего", "нашего",
    ]

    private func postFix(_ text: String) -> String {
        // 1) Дефис в составных словах: «почему - то» → «почему-то». Тире «—» не трогаем.
        let t0 = text.replacingOccurrences(of: " - ", with: "-")

        // 1б) Противоречивая граница от модели: «распознана. так» — точка есть, а
        //     заглавной у следующего слова нет. Настоящая граница размечается парой
        //     PERIOD + UPPER; точка перед строчным словом — слабый сигнал, убираем.
        //     «?» и «!» не трогаем — их потеря дороже ложного разрыва.
        var words = t0.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.count > 1 {
            for i in 0..<(words.count - 1) {
                let w = words[i]
                guard w.hasSuffix(".") || w.hasSuffix("…") else { continue }
                guard let nextFirst = words[i + 1].first, nextFirst.isLetter, nextFirst.isLowercase else { continue }
                var trimmed = w
                while trimmed.hasSuffix(".") || trimmed.hasSuffix("…") { trimmed.removeLast() }
                if !trimmed.isEmpty { words[i] = trimmed }
            }
        }

        // 2) Чиним ложные заглавные у служебных слов в середине предложения:
        //    • слово-начинатель (или «у» + притяжательное) → пропущена точка: ставим её,
        //      заглавную оставляем;
        //    • прочие служебные → просто ошибка регистра: понижаем.
        var atStart = true
        var out: [String] = []
        for (idx, w) in words.enumerated() {
            if w.isEmpty { out.append(w); continue }
            var token = w
            if !atStart, let first = w.first, first.isUppercase {
                let core = String(w.prefix(while: { $0.isLetter })).lowercased()
                    .replacingOccurrences(of: "ё", with: "е")
                if Self.commonLowercaseWords.contains(core) {
                    let nextCore = idx + 1 < words.count
                        ? String(words[idx + 1].prefix(while: { $0.isLetter })).lowercased()
                            .replacingOccurrences(of: "ё", with: "е")
                        : ""
                    let missedBoundary = Self.sentenceStarters.contains(core)
                        || (core == "у" && Self.possessiveAfterU.contains(nextCore))
                    if missedBoundary {
                        // Пропущена точка → добавляем её к предыдущему слову (если оно
                        // оканчивается буквой/цифрой), заглавную текущего слова оставляем.
                        if !out.isEmpty, let lc = out[out.count - 1].last, lc.isLetter || lc.isNumber {
                            out[out.count - 1] += "."
                        }
                    } else {
                        token = w.prefix(1).lowercased() + w.dropFirst()
                    }
                }
            }
            out.append(token)
            atStart = token.last.map { ".!?…".contains($0) } ?? false
        }
        return out.joined(separator: " ")
    }

    // MARK: - Inference

    private func infer(_ text: String, tokenizer tok: any Tokenizers.Tokenizer, model: MLModel) throws -> String {
        // Split into whitespace-words and keep the ORIGINAL word text. Each word is
        // sub-tokenized; we apply the FIRST sub-token's label to the WHOLE original word
        // (HF aggregation_strategy="first" — grouping by offset contiguity). Это важно
        // для дефисных слов: «по-моему» BERT бьёт на «по»/«-»/«моему», и группировка по
        // «##» делала их тремя «словами» → «по, -, моему». Группировка по пробелу даёт
        // одно слово «по-моему» с одной меткой.
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return text }

        let clsId = tok.convertTokenToId("[CLS]") ?? 101
        let sepId = tok.convertTokenToId("[SEP]") ?? 102
        let unkId = tok.unknownTokenId ?? 100

        var allSub: [String] = []
        var firstSubIdx: [Int] = []   // индекс первого сабтокена для каждого слова (или -1)
        for w in words {
            let subs = tok.tokenize(text: w)
            if subs.isEmpty { firstSubIdx.append(-1); continue }
            firstSubIdx.append(allSub.count)
            allSub.append(contentsOf: subs)
        }
        guard !allSub.isEmpty else { return text }

        var ids: [Int] = [clsId]
        ids.append(contentsOf: allSub.map { tok.convertTokenToId($0) ?? unkId })
        ids.append(sepId)
        let n = ids.count

        let inputIds = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        for k in 0..<n {
            inputIds[k] = NSNumber(value: ids[k])
            mask[k] = 1
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inputIds, "attention_mask": mask,
        ])
        let out = try model.prediction(from: provider)
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { return text }
        let numLabels = logits.shape[2].intValue

        // argmax per sub-token (positions 1..n-2 map to allSub[0..count-1]; skip CLS/SEP)
        var subLabels: [String] = []
        subLabels.reserveCapacity(allSub.count)
        for p in 1..<(n - 1) {
            var best = 0
            var bestVal = -Float.greatestFiniteMagnitude
            for c in 0..<numLabels {
                let v = logits[[0, NSNumber(value: p), NSNumber(value: c)]].floatValue
                if v > bestVal { bestVal = v; best = c }
            }
            subLabels.append(labelMap[best] ?? "LOWER_O")
        }

        // Apply each word's first-sub-token label to the original word.
        var outParts: [String] = []
        outParts.reserveCapacity(words.count)
        for (k, w) in words.enumerated() {
            let fi = firstSubIdx[k]
            let label = (fi >= 0 && fi < subLabels.count) ? subLabels[fi] : "LOWER_O"
            outParts.append(applyLabel(w, label))
        }
        return outParts.joined(separator: " ")
    }

    /// RUPunct трейнилась на тексте в нижнем регистре без знаков — нормализуем вход:
    /// lowercase + убираем знаки-терминаторы и запятые (модель их вернёт). Дефис
    /// внутри слов сохраняем. Знаки МЕЖДУ ЦИФРАМИ («2,5», «12:30», «10.06.2026») —
    /// часть числа, а не пунктуация: модель их не восстановит, поэтому не трогаем —
    /// раньше «12:30» необратимо превращалось в «12 30».
    private func normalizeInput(_ s: String) -> String {
        var t = s.lowercased()
        // Три альтернативы: всегда-мусорные знаки; «.,:» без цифры слева; «.,:» без
        // цифры справа. Разделитель, у которого цифры С ОБЕИХ сторон, не матчится
        // ни одной из них и выживает.
        t = t.replacingOccurrences(
            of: #"[!?;…—«»"()]|(?<!\d)[.,:]|[.,:](?!\d)"#,
            with: " ",
            options: .regularExpression
        )
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func applyLabel(_ word: String, _ label: String) -> String {
        let cased: String
        let suffix: String
        if label.hasPrefix("UPPER_TOTAL_") {
            cased = word.uppercased(); suffix = String(label.dropFirst("UPPER_TOTAL_".count))
        } else if label.hasPrefix("UPPER_") {
            cased = word.prefix(1).uppercased() + word.dropFirst(); suffix = String(label.dropFirst("UPPER_".count))
        } else {
            cased = word; suffix = label.hasPrefix("LOWER_") ? String(label.dropFirst("LOWER_".count)) : label
        }
        let punct: String
        switch suffix {
        case "PERIOD": punct = "."
        case "COMMA": punct = ","
        case "QUESTION": punct = "?"
        case "VOSKL": punct = "!"
        case "TIRE": punct = " —"
        case "DVOETOCHIE": punct = ":"
        case "PERIODCOMMA": punct = ";"
        case "DEFIS": punct = "-"
        case "MNOGOTOCHIE": punct = "..."
        case "QUESTIONVOSKL": punct = "?!"
        default: punct = ""
        }
        return cased + punct
    }

    private static func loadLabels(folder: URL) -> [Int: String] {
        let url = folder.appendingPathComponent("labels.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var m: [Int: String] = [:]
        for (k, v) in dict { if let i = Int(k) { m[i] = v } }
        return m
    }
}
