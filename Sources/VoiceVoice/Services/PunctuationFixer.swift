import Foundation

/// Пунктуация после распознавания — общая для всех движков, без моделей:
///   • `joinYandexServices` — «Яндекс. Метрики» → «Яндекс Метрики» (точка от движка);
///   • `mergeContinuationClauses` — рубленые фразы перед «а / но / хотя / потому что /
///     который…» склеиваются запятой (движок ставит точку по паузе в речи);
///   • `restoreQuestionMarks` — «?» там, где вопрос однозначен по грамматике (движок
///     ставит его только по интонации), и точка в конце последней фразы без знака.
/// Уже стоящие «?» и «!» не трогаются. (Старые правила «исправлять знаки в конце» с
/// заменой «?» на точку убраны в 1.1.8 — они ломали честно услышанные вопросы.)
enum PunctuationFixer {
    // MARK: - Сервисы Яндекса

    /// «Яндекс. Метрики» / «Яндекс.Маркет» → «Яндекс Метрики» / «Яндекс Маркет».
    /// GigaAM училась на текстах со старым написанием «Яндекс.Метрика» и ставит точку
    /// после «Яндекс» (часто ещё и с пробелом) — фраза рвётся на два предложения, а
    /// `restoreQuestionMarks` превращал её в «к Яндекс? Метрике». С 2021 года Яндекс
    /// сам пишет названия без точки. Только перед сервисами из списка: «Работаю в
    /// Яндекс. Мне нравится» — честные два предложения.
    private static let yandexServices = try! NSRegularExpression(
        pattern: #"\b(Яндекс)\.\s*((?:Метрик|Маркет|Директ|Диск|Карт|Такси|Лавк|Музык|Браузер|Бизнес|Вебмастер|Практикум|Касс|Почт|Трекер|Облак|Дзен|Алис|Доставк|Сплит|Телемост|Вордстат|Аудитори)[а-яё]{0,3}\b|(?:Cloud|Go|ID|Pay)\b)"#,
        options: [.caseInsensitive])

    static func joinYandexServices(_ text: String) -> String {
        guard text.contains("Яндекс.") || text.contains("яндекс.") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return yandexServices.stringByReplacingMatches(in: text, range: range, withTemplate: "$1 $2")
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

    /// Неопределённые частицы после дефиса: «что-то», «где-нибудь», «кто-либо» — не вопрос.
    private static let indefiniteSuffixes: Set<String> = ["то", "нибудь", "либо"]

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
