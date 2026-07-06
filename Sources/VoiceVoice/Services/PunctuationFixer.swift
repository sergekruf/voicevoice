import Foundation

/// Пост-обработчик пунктуации в конце предложений.
///
/// Whisper-turbo 4-bit на русской речи иногда ошибается с финальным знаком:
/// вопрос получает «.», утверждение получает «?». Этот фиксер применяет простые
/// грамматические правила (без анализа аудио) и исправляет очевидные случаи:
///
///   1. «ли»-частица: если в предложении есть «ли» как отдельное слово —
///      это вопрос. `.` → `?`.
///   2. Вопросительное слово в начале (после необязательных дискурсивных
///      «А / Ну / Так / И»): что, где, когда, почему, куда, откуда, зачем,
///      кто, сколько, разве, неужели, отчего. `.` → `?`.
///   3. Длинное предложение (≥ 5 слов) **без** маркеров вопроса, но с `?` в
///      конце → почти всегда ошибка интонации. `?` → `.`.
///
/// Не трогает «!» (восклицание ↔ эмоциональный вопрос неразличимы без аудио).
/// Не трогает «как», «какой» — они часто восклицания («Как красиво!»), а не
/// вопросы.
enum PunctuationFixer {
    static func fix(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // Сначала «разжалуем» ложные точки перед связками-продолжениями (то есть,
        // потому что, который…) — их ставят и модель, и стыки кусков на паузах.
        let merged = mergeContinuations(text)
        let sentences = splitSentencesPreservingTrailingSpace(merged)
        return sentences.map { fixSentence($0) }.joined()
    }

    // MARK: - False sentence-break demotion

    /// Связки/подчинительные слова, которые НИКОГДА не начинают самостоятельное
    /// предложение — это продолжение предыдущей мысли. Если перед ними стоит точка
    /// (модель так решила, или стык кусков пришёлся на паузу), меняем «.» на «,» и
    /// строчим первую букву: «…за 5 месяцев. То есть с января» → «…за 5 месяцев, то
    /// есть с января». Набор НАМЕРЕННО консервативный — сюда НЕ входят «и/а/но/что»,
    /// которые в речи вполне могут начинать предложение.
    private static let continuationRegex: NSRegularExpression = {
        let alts = [
            "то\\s+есть", "то\\s+бишь", "потому\\s+что", "так\\s+как", "тогда\\s+как",
            "поскольку", "чтобы", "котор(?:ый|ая|ое|ые|ых|ым|ой|ую|ого|ом|ыми|ому)",
        ].joined(separator: "|")
        // «.» или «…», пробелы, затем связка как отдельное слово.
        return try! NSRegularExpression(
            pattern: "([.…])\\s+(\(alts))(?=\\s|[,.!?…]|$)",
            options: [.caseInsensitive]
        )
    }()

    private static func mergeContinuations(_ text: String) -> String {
        let ns = text as NSString
        let matches = continuationRegex.matches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return text }
        var result = text
        // В обратном порядке, чтобы диапазоны из исходной строки не сдвигались.
        for m in matches.reversed() {
            let word = ns.substring(with: m.range(at: 2))
            let replacement = ", " + word.lowercased()
            result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return result
    }

    // MARK: - Per-sentence

    private static func fixSentence(_ sent: String) -> String {
        // 1) Отделяем хвостовой whitespace.
        var content = sent
        var trailing = ""
        while let last = content.last, last.isWhitespace {
            trailing = String(last) + trailing
            content.removeLast()
        }
        // 2) Финальный знак — `. ! ?` (иначе нечего фиксить).
        guard let term = content.last, "!.?".contains(term) else { return sent }
        let bodyRaw = String(content.dropLast())
        let body = bodyRaw.trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return sent }

        let hasLi = containsLiParticle(body)
        let startsWithQ = startsWithQuestionWord(body)

        // Правило 1+2: маркер вопроса есть, а знак — «.». Меняем на «?».
        if (hasLi || startsWithQ) && term == "." {
            return body + "?" + trailing
        }

        // Правило 3: знак «?», маркера вопроса нет, длинное предложение → «.».
        if term == "?" && !hasLi && !startsWithQ && wordCount(body) >= 5 {
            return body + "." + trailing
        }

        return sent
    }

    // MARK: - Detectors

    /// Слова, после которых «ли» — часть утвердительного оборота, а не вопросительная
    /// частица: «вряд ли», «едва ли», «навряд ли», «чуть ли (не)», «мало ли»,
    /// «то ли… то ли…». Без этого списка «Он вряд ли успеет.» превращалось в вопрос.
    private static let liIdiomPredecessors: Set<String> = [
        "вряд", "едва", "навряд", "чуть", "мало", "то",
    ]

    /// Проверка на свободно стоящую вопросительную частицу «ли» (вне устойчивых
    /// утвердительных оборотов).
    private static func containsLiParticle(_ s: String) -> Bool {
        let words = wordTokens(s)
        for (i, w) in words.enumerated() where w == "ли" {
            let prev = i > 0 ? words[i - 1] : ""
            if !liIdiomPredecessors.contains(prev) { return true }
        }
        return false
    }

    /// Консервативный список вопросительных слов. Намеренно НЕ включает «как»,
    /// «какой», «который» — они часто восклицания.
    private static let questionWords: Set<String> = [
        "что", "где", "когда", "почему", "куда", "откуда",
        "зачем", "кто", "сколько", "разве", "неужели", "отчего",
    ]

    /// Слова-«затравки» перед основным вопросительным словом: «А что…»,
    /// «Ну где…», «Так когда…». Их разрешено пропускать.
    private static let discourseMarkers: Set<String> = [
        "а", "ну", "так", "и", "ой",
    ]

    /// Неопределённые суффиксы: «что-то», «где-нибудь», «кто-либо» — дефис
    /// токенизатор режет, поэтому проверяем следующее слово. Такие обороты
    /// НЕ делают предложение вопросом («Что-то пошло не так.»).
    private static let indefiniteSuffixes: Set<String> = ["то", "нибудь", "либо"]

    /// Продолжения, при которых конкретное вопросительное слово — часть
    /// декларативного оборота: «что касается…», «что ж…», «разве что…».
    private static let nonQuestionFollowers: [String: Set<String>] = [
        "что": ["касается", "ж", "же", "до", "бы", "б"],
        "разве": ["что"],
    ]

    private static func startsWithQuestionWord(_ s: String) -> Bool {
        var words = wordTokens(s)
        // Пропускаем дискурсивные маркеры в начале.
        while let first = words.first, discourseMarkers.contains(first) {
            words.removeFirst()
        }
        guard let head = words.first, questionWords.contains(head) else { return false }
        let next = words.count > 1 ? words[1] : ""
        if indefiniteSuffixes.contains(next) { return false }
        if nonQuestionFollowers[head]?.contains(next) == true { return false }
        return true
    }

    /// Разбиение строки на «словесные» токены: только буквы/цифры, всё остальное
    /// — разделитель. Приводим к нижнему регистру и нормализуем «ё→е» для
    /// сравнения со списками.
    private static func wordTokens(_ s: String) -> [String] {
        let normalized = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        return normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    // MARK: - Sentence splitting

    /// Делит текст на предложения, **сохраняя трейлинговый whitespace** на
    /// каждом куске. Конкатенация результата воспроизводит исходный текст.
    private static func splitSentencesPreservingTrailingSpace(_ s: String) -> [String] {
        let ns = s as NSString
        let regex = try! NSRegularExpression(pattern: #"(?<=[\.\!\?])\s+"#, options: [])
        let matches = regex.matches(in: s, options: [],
                                     range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return [s] }
        var result: [String] = []
        var cursor = 0
        for m in matches {
            let sentLen = m.range.location - cursor
            let sent = ns.substring(with: NSRange(location: cursor, length: sentLen))
            let sep = ns.substring(with: m.range)
            result.append(sent + sep)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result.append(ns.substring(from: cursor))
        }
        return result
    }
}
