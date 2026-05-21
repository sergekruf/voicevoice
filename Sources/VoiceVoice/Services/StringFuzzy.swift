import Foundation

extension String {
    /// Lowercase, fold "ё" → "е" (the user almost certainly didn't actually say "ё"),
    /// collapse whitespace runs and trim. Used as the canonical form for fuzzy matching.
    func normalizedForFuzzy() -> String {
        var s = self.lowercased()
        s = s.replacingOccurrences(of: "ё", with: "е")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Classic Levenshtein edit distance. Uses two rolling rows so memory is O(min(n, m)).
    func levenshteinDistance(to other: String) -> Int {
        let a = Array(self)
        let b = Array(other)
        let n = a.count, m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            (prev, curr) = (curr, prev)
        }
        return prev[m]
    }
}
