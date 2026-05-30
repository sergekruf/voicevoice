import Foundation

/// Распознаёт структурные паттерны в одностроковом тексте от Whisper и превращает
/// их в Markdown-совместимую разметку:
///   • перечисления «первое… второе…» / «во-первых… во-вторых…» (≥ 2 ordinal'ов)
///     → нумерованный список (`1. … 2. …`)
///   • sequence-маркеры «сначала… потом… затем…» (≥ 3 маркера) → нумерованный
///   • «список покупок: a, b, c, d», «нужно купить: …», «три задачи: …»
///     → маркированный список (`- a\n- b\n…`)
///   • Action-verb + ≥ 3 запятых: «надо купить хлеб, молоко, масло, яйца»
///     → маркированный список с заголовком «<вся часть до глагола включительно>:»
///   • «новый абзац» / «с новой строки» → `\n\n`
///
/// Логика regex-based, без зависимостей. Подключается опционально через
/// `AppSettings.autoFormat` (по умолчанию ON).
enum TextFormatter {
    static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let withParagraphs = applyParagraphBreaks(text)
        // Списки обрабатываем по абзацам независимо, чтобы один не «прорастал»
        // через `\n\n` в другой.
        let paragraphs = withParagraphs.components(separatedBy: "\n\n")
        let formatted = paragraphs.map { p -> String in
            var x = applyNumberedLists(p)
            x = applySequenceMarkers(x)
            x = applyBulletLists(x)
            x = applyActionVerbLists(x)
            return x
        }
        return formatted.joined(separator: "\n\n")
    }

    // MARK: - Paragraph breaks

    /// Триггеры абзацев — как самостоятельная фраза, ограниченная пунктуацией.
    /// Захватывает прилегающую пунктуацию, чтобы не оставлять висячих знаков.
    private static let paragraphTriggers: NSRegularExpression = {
        let pattern = #"(?:^|(?<=[\.\!\?\…\;]))\s*(?:новый\s+абзац|с\s+новой\s+строки|новая\s+строка|абзац)\s*[\.\,\;\!\?]?\s*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func applyParagraphBreaks(_ s: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        var t = paragraphTriggers.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "\n\n")
        t = t.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Numbered lists (ordinals)

    /// Допустимые формы ordinal-триггеров по позициям 1..10. Регистронезависимо;
    /// «ё» нормализуется в «е» при сравнении.
    private static let ordinalForms: [[String]] = [
        ["первое",   "во-первых",   "пункт один",     "пункт первый",   "номер один"],
        ["второе",   "во-вторых",   "пункт два",      "пункт второй",   "номер два"],
        ["третье",   "в-третьих",   "пункт три",      "пункт третий",   "номер три"],
        ["четвёртое","четвертое",   "в-четвёртых",    "в-четвертых",
         "пункт четыре", "пункт четвёртый", "пункт четвертый", "номер четыре"],
        ["пятое",    "в-пятых",     "пункт пять",     "пункт пятый",    "номер пять"],
        ["шестое",   "в-шестых",    "пункт шесть",    "пункт шестой",   "номер шесть"],
        ["седьмое",  "в-седьмых",   "пункт семь",     "пункт седьмой",  "номер семь"],
        ["восьмое",  "в-восьмых",   "пункт восемь",   "пункт восьмой",  "номер восемь"],
        ["девятое",  "в-девятых",   "пункт девять",   "пункт девятый",  "номер девять"],
        ["десятое",  "в-десятых",   "пункт десять",   "пункт десятый",  "номер десять"],
    ]

    private static let ordinalRegex: NSRegularExpression = {
        let allForms = ordinalForms.flatMap { $0 }.sorted { $0.count > $1.count }
        let escaped = allForms.map {
            NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#)
        }
        let alts = escaped.joined(separator: "|")
        let pattern = #"(?:^|(?<=[\s\.\,\;\!\?\—\-]))(\#(alts))\s*[\,\.\:\—\-]?\s*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func ordinalIndex(of trigger: String) -> Int? {
        let lower = trigger.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for (idx, forms) in ordinalForms.enumerated() {
            for form in forms {
                if form.replacingOccurrences(of: "ё", with: "е") == lower {
                    return idx
                }
            }
        }
        return nil
    }

    private static func applyNumberedLists(_ s: String) -> String {
        guard !isAlreadyList(s) else { return s }
        let ns = s as NSString
        let matches = ordinalRegex.matches(in: s, options: [],
                                           range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return s }

        struct Hit { let fullRange: NSRange; let idx: Int }
        var hits: [Hit] = []
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let trigger = ns.substring(with: m.range(at: 1))
            guard let idx = ordinalIndex(of: trigger) else { continue }
            hits.append(Hit(fullRange: m.range, idx: idx))
        }

        // Простая возрастающая цепочка с первой позиции (0,1,2,…).
        // Порог снижен до 2: пары «во-первых … во-вторых …» — это часто настоящий
        // список из двух пунктов, и пользователи ожидают форматирование.
        var sequence: [Hit] = []
        var expected = 0
        for h in hits {
            if h.idx == expected {
                sequence.append(h)
                expected += 1
            } else if h.idx > expected {
                break
            }
        }
        guard sequence.count >= 2 else { return s }

        let first = sequence[0].fullRange
        let prefix = ns.substring(with: NSRange(location: 0, length: first.location))

        var items: [String] = []
        for i in 0..<sequence.count {
            let bodyStart = sequence[i].fullRange.location + sequence[i].fullRange.length
            let bodyEnd: Int
            if i + 1 < sequence.count {
                bodyEnd = sequence[i + 1].fullRange.location
            } else {
                bodyEnd = ns.length
            }
            let raw = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:—-\n\t"))
            if !cleaned.isEmpty { items.append(cleaned) }
        }
        guard items.count >= 2 else { return s }

        let list = items.enumerated().map { (i, body) in "\(i + 1). \(body)" }.joined(separator: "\n")
        let prefixTrimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefixTrimmed.isEmpty ? list : (prefixTrimmed + "\n" + list)
    }

    // MARK: - Sequence markers

    /// «сначала / потом / затем / далее / наконец / в конце …» — естественная
    /// разговорная нумерация шагов. Требуется ≥ 3 разных маркера, иначе слишком
    /// много ложных срабатываний (одиночное «потом я пошёл домой» — не список).
    private static let sequenceMarkers: [String] = [
        "сначала", "сперва", "вначале",
        "потом", "затем", "далее", "следом",
        "наконец", "напоследок",
        "в конце", "в итоге",
    ]

    private static let sequenceMarkerRegex: NSRegularExpression = {
        let markers = sequenceMarkers.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
            .joined(separator: "|")
        let pattern = #"(?:^|(?<=[\s\.\!\?\;\,\—\n]))(\#(markers))\s*[\,\:\—\-]?\s*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func applySequenceMarkers(_ s: String) -> String {
        guard !isAlreadyList(s) else { return s }
        let ns = s as NSString
        let matches = sequenceMarkerRegex.matches(in: s, options: [],
                                                   range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 3 else { return s }

        let first = matches[0].range
        let prefix = ns.substring(with: NSRange(location: 0, length: first.location))

        var items: [String] = []
        for i in 0..<matches.count {
            let bodyStart = matches[i].range.location + matches[i].range.length
            let bodyEnd: Int
            if i + 1 < matches.count {
                bodyEnd = matches[i + 1].range.location
            } else {
                bodyEnd = ns.length
            }
            let raw = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:—-\n\t"))
            if !cleaned.isEmpty { items.append(cleaned) }
        }
        guard items.count >= 3 else { return s }

        let list = items.enumerated().map { (i, body) in "\(i + 1). \(body)" }.joined(separator: "\n")
        let prefixTrimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefixTrimmed.isEmpty ? list : (prefixTrimmed + "\n" + list)
    }

    // MARK: - Bullet lists (explicit triggers)

    /// «список <чего-то>:» / «нужно купить:» / «надо купить:» / «перечислю:» /
    /// «пункты:» / «три задачи:» / «несколько вещей:» — триггеры с двоеточием.
    private static let bulletIntroRegex: NSRegularExpression = {
        let collective = #"(?:несколько|две|три|четыре|пять|шесть|семь|восемь|девять|десять|пара|много)\s+(?:вещ(?:ей|и)|задач(?:и)?|пункт(?:ов|а)|шаг(?:ов|а)|причин(?:ы)?|вариант(?:ов|а)|способ(?:ов|а)|дел)"#
        let pattern = #"(?:^|(?<=[\s\.\!\?\;\,\—\n]))(список(?:\s+[\p{L}\-]+)?|нужно\s+купить|надо\s+купить|перечислю|перечисляю|пункты|\#(collective))\s*:\s*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Разделитель « и » перед последним элементом списка.
    private static let lastSeparatorRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s+и\s+"#, options: [.caseInsensitive])
    }()

    private static func applyBulletLists(_ s: String) -> String {
        guard !isAlreadyList(s) else { return s }
        let ns = s as NSString
        let matches = bulletIntroRegex.matches(in: s, options: [],
                                               range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }

        var result = s as NSString
        for m in matches.reversed() {
            let cur = result
            let triggerHead = cur.substring(with: m.range(at: 1))
            let afterIntroLoc = m.range.location + m.range.length
            guard afterIntroLoc <= cur.length else { continue }

            let tail = cur.substring(from: afterIntroLoc) as NSString
            let termRange = tail.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n"))
            let bodyLen = termRange.location == NSNotFound ? tail.length : termRange.location
            let body = tail.substring(with: NSRange(location: 0, length: bodyLen))

            let parts = splitIntoItems(body)
            guard parts.count >= 3 else { continue }

            let bullets = parts.map { "- \($0)" }.joined(separator: "\n")
            let head = triggerHead.prefix(1).uppercased() + triggerHead.dropFirst()
            let replacement = "\(head):\n\(bullets)"
            let replaceRange = NSRange(location: m.range.location,
                                       length: m.range.length + bodyLen)
            result = cur.replacingCharacters(in: replaceRange, with: replacement) as NSString
        }
        return result as String
    }

    // MARK: - Action-verb lists

    /// Глаголы-действия, которые часто открывают перечисление. После такого
    /// глагола + 3+ запятых тело сворачивается в маркированный список с
    /// автоматическим заголовком «<всё до глагола включительно>:».
    private static let actionVerbs: [String] = [
        "купить", "куплю", "купи",
        "сделать", "сделаю", "сделай",
        "позвонить", "позвоню", "позвони",
        "отправить", "отправлю", "отправь",
        "написать", "напишу", "напиши",
        "приготовить", "приготовлю", "приготовь",
        "заказать", "закажу", "закажи",
        "добавить", "добавлю", "добавь",
        "подготовить", "подготовлю", "подготовь",
        "принести", "принесу", "принеси",
        "забрать", "заберу", "забери",
        "получить", "получу", "получи",
        "собрать", "соберу", "собери",
        "узнать", "узнаю", "узнай",
        "проверить", "проверю", "проверь",
        "обновить", "обновлю", "обнови",
        "удалить", "удалю", "удали",
        "исправить", "исправлю", "исправь",
        "оформить", "оформлю", "оформи",
        "оплатить", "оплачу", "оплати",
        "запланировать",
        "запомнить", "запомни",
        "взять", "возьму", "возьми",
        "посетить", "посещу",
        "выполнить", "выполню", "выполни",
        "обсудить", "обсужу", "обсуди",
        "согласовать",
    ]

    private static let actionVerbRegex: NSRegularExpression = {
        let verbs = actionVerbs.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Глагол должен быть на границе слова: лидирующий пробел/пунктуация и
        // обязательный пробел после (чтобы «купить» совпало, а «купительный»
        // не нашёлся бы по подстроке).
        let pattern = #"(?:^|(?<=[\s\.\!\?\;\,\—\n]))(\#(verbs))(?=\s)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func applyActionVerbLists(_ s: String) -> String {
        guard !isAlreadyList(s) else { return s }
        let sentences = splitSentences(s)
        let formatted = sentences.map { sent -> String in
            formatActionVerbSentence(sent) ?? sent
        }
        return formatted.joined()
    }

    /// Подчинительные союзы в начале предложения — признак того, что глагол
    /// внутри не императив, а часть условного/временного/целевого clause'а.
    /// «Если добавить обратно не дает…» — здесь «добавить» это не команда,
    /// а часть условия.
    private static let subordinatingPrefixes: [String] = [
        "если ", "когда ", "пока ", "хотя ", "чтобы ",
        "поскольку ", "ведь ", "потому что ", "как только ",
        "раз ", "коль ", "будь то ",
    ]

    /// Слова-маркеры внутри элемента списка, указывающие на clause-структуру,
    /// а не на короткую именную группу. Если встречаются — это не список.
    private static let clauseMarkersInItem: [String] = [
        "то ", " то ",     // союз-«то» («если…, то…»)
        "потому", "поэтому",
        "чтобы",
        "который", "которая", "которое", "которые", "которых", "которым", "которой",
        "когда", "пока",
        "хотя", "если",
    ]

    private static func formatActionVerbSentence(_ sent: String) -> String? {
        // Sanity 0: пропускаем подчинённые предложения целиком.
        let lowered = sent.trimmingCharacters(in: .whitespaces).lowercased()
        if subordinatingPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return nil
        }

        let ns = sent as NSString
        guard let m = actionVerbRegex.firstMatch(in: sent, options: [],
                                                  range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let verbEnd = m.range.location + m.range.length
        // Срезаем хвостовые пробелы и пунктуацию.
        var tailEnd = ns.length
        let trimSet = CharacterSet(charactersIn: " \t\n.!?")
        while tailEnd > verbEnd,
              let scalar = UnicodeScalar(ns.character(at: tailEnd - 1)),
              trimSet.contains(scalar) {
            tailEnd -= 1
        }
        guard tailEnd > verbEnd else { return nil }
        let tail = ns.substring(with: NSRange(location: verbEnd, length: tailEnd - verbEnd))
        let items = splitIntoItems(tail)
        guard items.count >= 3 else { return nil }
        // Sanity 1: вложенный list-intro в элементе — не наш кейс.
        guard !items.contains(where: { $0.contains(":") }) else { return nil }
        // Sanity 2: символьная длина элемента.
        guard items.allSatisfy({ $0.count <= 60 }) else { return nil }
        // Sanity 3: каждый элемент — короткая именная группа (≤ 4 слов).
        // Длиннее — почти наверняка clause, а не пункт списка.
        guard items.allSatisfy({ itemWordCount($0) <= 4 }) else { return nil }
        // Sanity 4: clause-маркеры внутри элемента означают, что мы цепляемся
        // за связный текст («то просто пусть едет», «потому что устал»).
        let loweredItems = items.map { $0.lowercased() }
        if loweredItems.contains(where: { item in
            clauseMarkersInItem.contains(where: { item.contains($0) })
        }) {
            return nil
        }

        let header = ns.substring(with: NSRange(location: 0, length: verbEnd))
            .trimmingCharacters(in: .whitespaces)
        let bullets = items.map { "- \($0)" }.joined(separator: "\n")
        let h = header.prefix(1).uppercased() + header.dropFirst()
        return "\(h):\n\(bullets)"
    }

    /// Количество слов в элементе (split по whitespace).
    private static func itemWordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - Shared helpers

    /// Разделяет текст на предложения, **сохраняя** трейлинговые разделители
    /// (пробел после `.`/`!`/`?`). Соединение результата `.joined()` даёт исходный текст.
    private static func splitSentences(_ s: String) -> [String] {
        let ns = s as NSString
        let regex = try! NSRegularExpression(pattern: #"(?<=[\.\!\?])\s+"#, options: [])
        let matches = regex.matches(in: s, options: [],
                                     range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return [s] }
        var result: [String] = []
        var cursor = 0
        for m in matches {
            let len = m.range.location - cursor
            let sent = ns.substring(with: NSRange(location: cursor, length: len))
            let sep = ns.substring(with: m.range)
            result.append(sent + sep)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result.append(ns.substring(from: cursor))
        }
        return result
    }

    /// Разбивает тело списка по запятым, последний элемент — потенциально через « и ».
    private static func splitIntoItems(_ body: String) -> [String] {
        var parts = body
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if let last = parts.last, !last.isEmpty {
            let lastNS = last as NSString
            let andRange = lastSeparatorRegex.rangeOfFirstMatch(
                in: last, options: [], range: NSRange(location: 0, length: lastNS.length)
            )
            if andRange.location != NSNotFound {
                let left = lastNS.substring(with: NSRange(location: 0, length: andRange.location))
                    .trimmingCharacters(in: .whitespaces)
                let right = lastNS.substring(from: andRange.location + andRange.length)
                    .trimmingCharacters(in: .whitespaces)
                parts.removeLast()
                if !left.isEmpty  { parts.append(left)  }
                if !right.isEmpty { parts.append(right) }
            }
        }
        return parts.filter { !$0.isEmpty }
    }

    /// Текст уже выглядит как список (≥ 2 строк начинаются с `- ` или `N. `).
    /// В таком случае последующие apply*-функции должны пропустить его, чтобы
    /// не ломать уже построенную разметку.
    private static let listLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:-\s|\d+\.\s)"#, options: []
    )

    private static func isAlreadyList(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\n")
        var count = 0
        for line in lines {
            let ns = line as NSString
            let r = listLineRegex.rangeOfFirstMatch(in: line, options: [],
                                                     range: NSRange(location: 0, length: ns.length))
            if r.location == 0 { count += 1 }
            if count >= 2 { return true }
        }
        return false
    }
}
