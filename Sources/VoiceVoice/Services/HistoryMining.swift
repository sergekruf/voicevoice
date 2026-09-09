import Foundation

/// Разбор истории диктовок: какие исправления повторяются раз за разом и потому
/// заслуживают места в словаре правок.
///
/// Откуда берутся кандидаты. В записи истории теперь лежит и сырой выход движка
/// (`engineText`), и итоговый текст, так что видно каждое исправление, сделанное
/// пост-обработкой — прежде всего языковой моделью. Если LLM в двадцатый раз чинит
/// «вотов» → «ботов», это правило лучше держать в словаре: замена станет мгновенной
/// и перестанет зависеть от того, включена ли «Глубокая чистка».
///
/// Что НЕ делаем: не переписываем историю задним числом (текст уже вставлен в чужие
/// документы) и не добавляем правила автоматически — именно автопополнение когда-то
/// и намусорило в словаре. Разбор только предлагает, решение за пользователем.
enum HistoryMining {

    struct Candidate: Identifiable {
        let wrong: String
        let right: String
        /// Сколько раз встретилось в истории.
        let count: Int
        /// Пример фразы, где это исправление понадобилось.
        let example: String
        var id: String { wrong + "→" + right }
    }

    /// Минимум повторов: однократные правки — почти всегда разовая особенность
    /// конкретной фразы, а не устойчивая ослышка. Именно они замусорили словарь.
    static let minOccurrences = 2

    /// Ищет повторяющиеся исправления в истории. `existing` — что уже есть в словаре
    /// (такие пары не предлагаем).
    static func candidates(from records: [TranscriptionRecord],
                           existing: [CorrectionEntry]) -> [Candidate] {
        let known = Set(existing.map { $0.wrong.lowercased() + "→" + $0.right.lowercased() })
        var counts: [String: (wrong: String, right: String, count: Int, example: String)] = [:]

        for record in records {
            let before = record.engineText
            let after = record.finalText.isEmpty ? record.appliedText : record.finalText
            guard !before.isEmpty, !after.isEmpty, before != after else { continue }
            for (wrong, right) in replacements(from: before, to: after) {
                guard isWorthLearning(wrong: wrong, right: right) else { continue }
                let key = wrong.lowercased() + "→" + right.lowercased()
                if known.contains(key) { continue }
                if let cur = counts[key] {
                    counts[key] = (cur.wrong, cur.right, cur.count + 1, cur.example)
                } else {
                    counts[key] = (wrong, right, 1, String(after.prefix(90)))
                }
            }
        }
        return counts.values
            .filter { $0.count >= minOccurrences }
            .sorted { $0.count > $1.count }
            .map { Candidate(wrong: $0.wrong, right: $0.right, count: $0.count, example: $0.example) }
    }

    /// Те же требования, что у автословаря: замена одного-двух слов на созвучные,
    /// и левая часть не должна быть обычным словом (иначе правило сломает другие
    /// фразы — см. DictionaryAudit).
    static func isWorthLearning(wrong: String, right: String) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 3, r.count >= 2, w.count <= 40, r.count <= 40 else { return false }
        guard w.lowercased() != r.lowercased() else { return false }
        // Пунктуация и регистр — работа моделей, а не словаря. Пробел при этом
        // значим: «и того» → «итого» это ослышка, которую словарь чинить должен.
        func meaningful(_ x: String) -> String {
            x.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
        }
        guard meaningful(w) != meaningful(r) else { return false }
        guard w.split(separator: " ").count <= 2, r.split(separator: " ").count <= 2 else { return false }
        if DictionaryAudit.isRealRussian(w),
           !DictionaryAudit.looksLikeProperNameFix(wrong: w, right: r) { return false }
        // Замена должна быть созвучной: иначе это смысловая правка.
        let wl = w.lowercased().replacingOccurrences(of: "ё", with: "е")
        let rl = r.lowercased().replacingOccurrences(of: "ё", with: "е")
        let cyrW = wl.contains { $0.isCyrillicLetter }, cyrR = rl.contains { $0.isCyrillicLetter }
        if cyrW != cyrR { return true }          // кросс-скрипт: «клуд» → «Claude»
        return Double(wl.levenshteinDistance(to: rl)) / Double(max(wl.count, rl.count)) <= 0.5
    }

    /// Пары «было → стало» между двумя версиями текста (по словам, LCS-выравнивание).
    static func replacements(from before: String, to after: String) -> [(String, String)] {
        let a = before.split(separator: " ").map(String.init)
        let b = after.split(separator: " ").map(String.init)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let ka = a.map(core), kb = b.map(core)
        let n = ka.count, m = kb.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = ka[i] == kb[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [(String, String)] = []
        var ca: [String] = [], cb: [String] = []
        var i = 0, j = 0
        func flush() {
            if !ca.isEmpty, !cb.isEmpty {
                out.append((ca.joined(separator: " "), cb.joined(separator: " ")))
            }
            ca = []; cb = []
        }
        while i < n && j < m {
            if ka[i] == kb[j] { flush(); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { ca.append(a[i]); i += 1 }
            else { cb.append(b[j]); j += 1 }
        }
        ca.append(contentsOf: a[i...]); cb.append(contentsOf: b[j...])
        flush()
        // Слова очищаем от обрамляющей пунктуации: «ботов,» и «ботов» — одно и то же.
        return out.map { (trimPunct($0.0), trimPunct($0.1)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
    }

    private static func core(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func trimPunct(_ s: String) -> String {
        var t = s
        while let f = t.first, !f.isLetter, !f.isNumber { t.removeFirst() }
        while let l = t.last, !l.isLetter, !l.isNumber { t.removeLast() }
        return t
    }
}

private extension Character {
    var isCyrillicLetter: Bool {
        unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
}
