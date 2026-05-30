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
        let sentences = splitSentencesPreservingTrailingSpace(text)
        return sentences.map { fixSentence($0) }.joined()
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

    /// Проверка на свободно стоящую частицу «ли». Использует padding по краям,
    /// чтобы lookbehind/lookahead работали и в начале/конце строки.
    private static let liRegex = try! NSRegularExpression(
        pattern: #"(?<=\s)ли(?=\s|[,.!?])"#, options: [.caseInsensitive]
    )

    private static func containsLiParticle(_ s: String) -> Bool {
        let padded = " " + s + " "
        let ns = padded as NSString
        return liRegex.firstMatch(in: padded, options: [],
                                   range: NSRange(location: 0, length: ns.length)) != nil
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

    private static func startsWithQuestionWord(_ s: String) -> Bool {
        var words = wordTokens(s)
        // Пропускаем дискурсивные маркеры в начале.
        while let first = words.first, discourseMarkers.contains(first) {
            words.removeFirst()
        }
        guard let head = words.first else { return false }
        return questionWords.contains(head)
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
