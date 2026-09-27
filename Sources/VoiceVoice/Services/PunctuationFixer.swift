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

    // MARK: - Продолжения после терминатора

    /// «…маржинальность. Но покупатель увидит…» → «…маржинальность, но покупатель
    /// увидит…»; «…поставилась точка? Хотя по смыслу это целое предложение.» →
    /// «…поставилась точка, хотя по смыслу это целое предложение?». Движок (у GigaAM
    /// пунктуация встроенная) ставит терминатор по паузе или интонации, и одна мысль
    /// рассыпается на фразы, начинающиеся с союза. LLM это правило выполнять
    /// отказалась даже с примером в промпте (проверено на Qwen3-1.7B), а знак
    /// вопроса ей менять запрещено вовсе, поэтому шаг детерминированный. Меры:
    ///   • результат не длиннее `maxMergedLength`;
    ///   • к уже склеенному предложению третье не присоединяем.
    private static let maxMergedLength = 220

    /// После точки: сочинительные «а/но/и» и подчинительные союзы — с них в диктовке
    /// начинается продолжение предыдущей мысли, а не новая.
    private static let leadsAfterPeriod: [String] = [
        "потому что", "так как", "то есть",
        "а", "но", "и", "хотя", "поскольку", "чтобы",
        "который", "которая", "которое", "которые", "которых", "которым", "которой",
        "которую", "которого", "котором", "которыми", "которому",
    ]
    /// После вопросительного знака — только уступительное «хотя». «Почему ушёл?
    /// Потому что устал.» — это вопрос и ответ, а «Ты придёшь? Если нет, напиши.» —
    /// два предложения; склеивать их нельзя.
    private static let leadsAfterQuestion: [String] = ["хотя"]

    static func mergeContinuationClauses(_ text: String) -> String {
        let sentences = splitSentencesPreservingTrailingSpace(text)
        guard sentences.count > 1 else { return text }
        var out: [String] = []
        var lastWasMerged = false
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            func starts(with leads: [String]) -> Bool {
                leads.contains { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ",") }
            }
            guard var prev = out.last, !lastWasMerged,
                  trimmed.first?.isUppercase == true else {
                out.append(sentence); lastWasMerged = false; continue
            }
            let prevTrim = prev.trimmingCharacters(in: .whitespaces)
            let afterPeriod = prevTrim.hasSuffix(".") && !prevTrim.hasSuffix("..") && starts(with: leadsAfterPeriod)
            let afterQuestion = prevTrim.hasSuffix("?") && starts(with: leadsAfterQuestion)
            guard afterPeriod || afterQuestion, prev.count + trimmed.count <= maxMergedLength else {
                out.append(sentence); lastWasMerged = false; continue
            }
            while let last = prev.last, last.isWhitespace { prev.removeLast() }
            while let last = prev.last, ".?".contains(last) { prev.removeLast() }
            var tail = ""
            for ch in sentence.reversed() {
                guard ch.isWhitespace else { break }
                tail.append(ch)
            }
            var body: String = trimmed.prefix(1).lowercased() + trimmed.dropFirst()
            if afterQuestion {
                // Вопрос относится ко всей склеенной фразе — знак переезжает в её конец.
                while let last = body.last, ".!…".contains(last) { body.removeLast() }
                body.append("?")
            }
            out[out.count - 1] = prev + ", " + body + tail
            lastWasMerged = true
        }
        return out.joined()
    }

    // MARK: - Потерянный знак вопроса

    /// Движок ставит «?» только по интонации и часто его теряет: у вопроса с «или»
    /// интонация в конце падает («Что-то ещё было или это всё»), вопрос-просьба
    /// звучит как утверждение («Ты можешь сделать тремя файлами»). LLM (1.7B) вопрос
    /// от утверждения не отличает — на проверке отвечала «вопрос» почти на всё,
    /// включая «Нужно обновить логотип». Поэтому только грамматика, и только там, где
    /// она однозначна; «?» лишь добавляется (вместо точки или на пустое место), уже
    /// стоящие знаки не трогаются. Последнее предложение без знака получает точку.
    ///
    /// В отличие от `fix` работает для всех движков: там правило «?» → «.» ломало бы
    /// вопросы, которые GigaAM честно услышал по интонации.
    static func restoreQuestionMarks(_ text: String) -> String {
        let sentences = splitSentencesPreservingTrailingSpace(text)
        return sentences.enumerated().map { k, sentence -> String in
            var content = sentence
            var trailing = ""
            while let last = content.last, last.isWhitespace {
                trailing = String(last) + trailing
                content.removeLast()
            }
            guard let term = content.last, !"?!…".contains(term) else { return sentence }
            var body = content
            if term == "." { body.removeLast() }
            // Оборванный хвост («…представить покупателям,») — висячий знак убираем.
            while let last = body.last, ",;:—-".contains(last) || last.isWhitespace { body.removeLast() }
            guard !body.isEmpty else { return sentence }
            if isQuestion(body) { return body + "?" + trailing }
            if term != "." && k == sentences.count - 1 { return body + "." + trailing }
            return sentence
        }.joined()
    }

    private static let questionLeadWords: Set<String> = [
        "а", "и", "но", "ну", "так", "тогда", "слушай", "кстати", "вот", "ой",
        "скажи", "скажите", "подскажи", "подскажите",
    ]
    private static let interrogatives: Set<String> = [
        "кто", "кого", "кому", "кем", "что", "чего", "чему", "где", "куда", "откуда",
        "почему", "зачем", "отчего", "сколько", "когда", "как", "каков",
        "какой", "какая", "какое", "какие", "каким", "какую", "какого", "каких",
        "какому", "какими", "каком", "чей", "чья", "чье", "чьи",
    ]
    /// Вопросительное слово в начале, но оборот утвердительный: «как только
    /// закончишь», «что касается цен», «сколько бы ни стоило», «как в прошлый раз».
    private static let declarativeFollowers: [String: Set<String>] = [
        "как": ["только", "будто", "всегда", "обычно", "договорились", "договаривались", "в", "и", "бы", "раз"],
        "что": ["касается", "ж", "же", "бы", "б", "до"],
        "сколько": ["бы"], "кто": ["бы"], "где": ["бы"], "когда": ["бы"], "куда": ["бы"],
    ]

    static func isQuestion(_ body: String) -> Bool {
        let lower = body.lowercased().replacingOccurrences(of: "ё", with: "е")
        // Слова вместе с позициями — чтобы знать, что стоит после вводных «Подскажи,».
        let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
        let ns = lower as NSString
        let tokens = pattern.matches(in: lower, range: NSRange(location: 0, length: ns.length))
            .map { (word: ns.substring(with: $0.range), start: $0.range.location) }
        var lead = 0
        while lead < tokens.count, questionLeadWords.contains(tokens[lead].word) { lead += 1 }
        let w = tokens[lead...].map(\.word)
        guard w.count >= 2 else { return false }
        let rest = lead < tokens.count ? ns.substring(from: tokens[lead].start) : ""
        let all = tokens.map(\.word)

        // «Можем ли мы…», «Есть ли смысл…» — «ли» вторым словом (косвенное «не знаю,
        // будет ли он» сюда не попадает).
        if w[1] == "ли", !["вряд", "едва", "навряд", "чуть", "мало", "то"].contains(w[0]) { return true }
        // Альтернативный вопрос и переспрос в конце: «…или это всё», «…, да».
        let tail = all.suffix(4).joined(separator: " ")
        if tail.hasSuffix("или нет") || tail.hasSuffix("или это все") || tail.hasSuffix("или как")
            || tail.hasSuffix("или что") || tail.hasSuffix("или как то еще") { return true }
        if lower.range(of: #",\s*(да|нет|верно|правильно|ок)$"#, options: .regularExpression) != nil { return true }
        // Вопрос-просьба: «Ты можешь…», «Сможешь…», «А можно…». «Можно…» и «Можешь
        // не торопиться» без этих опор — обычно утверждение.
        if ["ты", "вы"].contains(w[0]), ["можешь", "можете", "сможешь", "сможете"].contains(w[1]) { return true }
        if ["сможешь", "сможете", "успеешь", "успеете"].contains(w[0]) { return true }
        if w[0] == "можно", lead > 0, tokens[lead - 1].word == "а" { return true }
        if w[0] == "неужели" || (w[0] == "разве" && w[1] != "что") { return true }
        // Вопросительное слово в начале — только если дальше нет второй части через
        // запятую, тире или двоеточие: «Когда придёт машина, позвони мне» — не вопрос.
        if interrogatives.contains(w[0]), !indefiniteSuffixes.contains(w[1]),
           declarativeFollowers[w[0]]?.contains(w[1]) != true,
           rest.rangeOfCharacter(from: CharacterSet(charactersIn: ",—:;")) == nil,
           !rest.contains(" - ") {
            return true
        }
        return false
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
