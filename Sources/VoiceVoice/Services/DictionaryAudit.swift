import Foundation
import AppKit

/// Ревизия словаря правок: какие записи безопасны, а какие будут портить будущие
/// диктовки.
///
/// Зачем: словарь пополняется автоматически (из ваших правок вставленного текста),
/// и туда попадают не только ослышки, но и контекстные переформулировки — «боты» →
/// «бота», «задаче» → «задачам», «листа» → «к листу». Правило применяется ко ВСЕМ
/// последующим текстам без разбора контекста, поэтому такая запись ломает любую
/// фразу с этим словом. На словаре автора: 108 записей, из них 102 ни разу не
/// сработали, а несколько были откровенно вредными.
///
/// Главный признак вредности — левая часть является нормальным русским словом.
/// Проверяем это системным словарём macOS (`NSSpellChecker`), а не языковой моделью:
/// на контрольной выборке из 29 записей орфограф дал 28 верных ответов мгновенно,
/// тогда как Qwen3-1.7B — около 70% и по секунде на запись (модель уверенно
/// принимала «клуд», «мейтинга», «такены» за настоящие слова).
enum DictionaryAudit {

    enum Issue: String, CaseIterable {
        case realWord        = "левая часть — обычное слово, замена сломает другие фразы"
        case duplicate       = "дубликат такого же правила"
        case rejected        = "вы уже отклоняли эту замену"
        case punctuation     = "в замене есть знак препинания"
        case selfReplacement = "замена слова на само себя"

        /// Насколько уверенно можно предлагать удаление (для сортировки списка).
        var severity: Int {
            switch self {
            case .selfReplacement, .duplicate: return 3
            case .rejected, .punctuation: return 2
            case .realWord: return 1
            }
        }
    }

    struct Finding: Identifiable {
        let entry: CorrectionEntry
        let issues: [Issue]
        var id: Int64 { entry.id ?? 0 }
        var neverUsed: Bool { entry.lastUsedAt == entry.createdAt }
        var reason: String { issues.map(\.rawValue).joined(separator: "; ") }
    }

    /// Проверяет весь словарь. Возвращает только записи с замечаниями,
    /// уверенные — первыми.
    static func audit(_ entries: [CorrectionEntry]) -> [Finding] {
        var seen = Set<String>()
        var findings: [Finding] = []
        for entry in entries {
            var issues: [Issue] = []
            let key = normalized(entry.wrong) + "→" + normalized(entry.right)
            if seen.contains(key) { issues.append(.duplicate) }
            seen.insert(key)

            if entry.rejectedCount > 0 { issues.append(.rejected) }
            if let last = entry.right.trimmingCharacters(in: .whitespaces).last,
               ".,;:!?".contains(last) { issues.append(.punctuation) }
            if normalized(entry.wrong) == normalized(entry.right) { issues.append(.selfReplacement) }
            if isRealRussian(entry.wrong), !looksLikeProperNameFix(entry) { issues.append(.realWord) }

            if !issues.isEmpty {
                findings.append(Finding(entry: entry, issues: issues))
            }
        }
        return findings.sorted {
            ($0.issues.map(\.severity).max() ?? 0, $0.neverUsed ? 1 : 0)
                > ($1.issues.map(\.severity).max() ?? 0, $1.neverUsed ? 1 : 0)
        }
    }

    /// Правая часть выглядит как название или аббревиатура — тогда левая, даже будучи
    /// словарным словом, скорее ослышка бренда: «пеке» → «ПЭК», «купи пола» →
    /// «Купипола». Такие правила не бракуем.
    static func looksLikeProperNameFix(_ entry: CorrectionEntry) -> Bool {
        looksLikeProperNameFix(wrong: entry.wrong, right: entry.right)
    }

    static func looksLikeProperNameFix(wrong: String, right: String) -> Bool {
        // Две заглавные подряд — аббревиатура (ПЭК, ФБС, DBS).
        var uppercaseRun = 0
        for ch in right where ch.isLetter {
            uppercaseRun = ch.isUppercase ? uppercaseRun + 1 : 0
            if uppercaseRun >= 2 { return true }
        }
        // Латиница в замене — название сервиса или термин.
        if right.contains(where: { $0.isASCII && $0.isLetter }) { return true }
        // Склейка нескольких слов в одно название: «купи пола» → «Купипола».
        if wrong.contains(" "), !right.contains(" "),
           right.first?.isUppercase == true { return true }
        return false
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Все слова фразы есть в русском словаре macOS. Короткие токены (≤3 букв)
    /// орфограф пропускает без проверки, поэтому считаем их аббревиатурами
    /// («влк», «бпл») — то есть законной целью для замены.
    static func isRealRussian(_ phrase: String) -> Bool {
        // Знаки препинания — не слова («, какое-то» раньше проходило как не-слово из-за
        // запятой); «какое-то», «где-нибудь» проверяем по основе до частицы.
        var words: [String] = []
        for token in phrase.split(separator: " ") {
            var parts = token.split(separator: "-").map { String($0.filter { $0.isLetter }) }
                .filter { !$0.isEmpty }
            if parts.count > 1, let last = parts.last,
               ["то", "либо", "нибудь", "ка", "таки", "де"].contains(last.lowercased()) {
                parts.removeLast()
            }
            words += parts
        }
        guard !words.isEmpty else { return false }
        let checker = NSSpellChecker.shared
        for word in words {
            let letters = word.filter { $0.isLetter }
            guard letters.count > 3 else { return false }
            // Кириллица: латиницу русским словарём не проверить, а англицизмы
            // («prime», «unity») в словаре автозамен обычно и есть цель правки.
            guard letters.allSatisfy({ $0.isCyrillic }) else { return false }
            let range = checker.checkSpelling(of: letters, startingAt: 0, language: "ru",
                                              wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if range.location != NSNotFound { return false }   // слова нет в словаре
        }
        return true
    }
}

private extension Character {
    var isCyrillic: Bool {
        unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
}
