import Foundation

struct AppliedSubstitution: Hashable {
    let wrong: String         // lowercased original phrase
    let right: String         // dictionary's stored "right" string
    let context: String?
    let positionInOutput: Int
    let fuzzy: Bool           // true if this match wasn't exact, only fuzzy
}

struct ApplyResult {
    let text: String
    let substitutions: [AppliedSubstitution]
}

final class CorrectionApplier {
    static let shared = CorrectionApplier()
    private let store = CorrectionStore.shared
    private let settings = AppSettings.shared

    private struct PreparedEntry {
        let entry: CorrectionEntry
        let wrongWords: [String]      // lowercased word tokens of `wrong`
        let normalizedWrong: String   // normalized full phrase, for fuzzy compare
    }

    /// Apply learned corrections. For each input position we try the longest matching dictionary
    /// entry first; if no entry matches exactly AND fuzzy matching is on, we also try fuzzy
    /// matches (Levenshtein on normalized form, within threshold).
    func apply(to raw: String) -> ApplyResult {
        let tokens = Tokenizer.tokenize(raw)
        let entries = store.allOrdered()
        guard !entries.isEmpty else {
            return ApplyResult(text: raw, substitutions: [])
        }

        let minConfirmed = settings.minConfirmedToApply
        let fuzzyOn = settings.fuzzyMatching
        let fuzzyThreshold = settings.fuzzyThreshold

        let prepared: [PreparedEntry] = entries.compactMap { entry in
            guard shouldApply(entry, minConfirmed: minConfirmed) else { return nil }
            let words = Tokenizer.tokenize(entry.wrong)
                .filter { $0.isWord }
                .map { $0.text.lowercased() }
            guard !words.isEmpty else { return nil }
            let normalized = words.joined(separator: " ").normalizedForFuzzy()
            return PreparedEntry(entry: entry, wrongWords: words, normalizedWrong: normalized)
        }
        .sorted { (a, b) -> Bool in
            if a.wrongWords.count != b.wrongWords.count {
                return a.wrongWords.count > b.wrongWords.count
            }
            return a.entry.netScore > b.entry.netScore
        }

        var outTokens: [Token] = []
        var subs: [AppliedSubstitution] = []
        var i = 0

        outer: while i < tokens.count {
            let tok = tokens[i]

            if !tok.isWord {
                outTokens.append(tok)
                i += 1
                continue
            }

            // First pass: exact phrase match.
            for prep in prepared {
                if let endIdx = matchExact(prep.wrongWords, startingAt: i, in: tokens) {
                    appendSub(prep: prep, fuzzy: false, into: &outTokens, subs: &subs)
                    i = endIdx
                    continue outer
                }
            }

            // Second pass: fuzzy phrase match (Levenshtein on normalized input vs entry).
            if fuzzyOn {
                for prep in prepared {
                    if let endIdx = matchFuzzy(prep, startingAt: i, in: tokens, threshold: fuzzyThreshold) {
                        appendSub(prep: prep, fuzzy: true, into: &outTokens, subs: &subs)
                        i = endIdx
                        continue outer
                    }
                }
            }

            outTokens.append(tok)
            i += 1
        }

        return ApplyResult(text: Tokenizer.join(outTokens), substitutions: subs)
    }

    private func appendSub(prep: PreparedEntry, fuzzy: Bool, into outTokens: inout [Token], subs: inout [AppliedSubstitution]) {
        outTokens.append(Token(kind: .word, text: prep.entry.right))
        subs.append(AppliedSubstitution(
            wrong: prep.entry.wrong.lowercased(),
            right: prep.entry.right,
            context: prep.entry.contextBefore,
            positionInOutput: outTokens.count - 1,
            fuzzy: fuzzy
        ))
    }

    // MARK: - Match strategies

    /// Exact case-insensitive token-by-token match.
    private func matchExact(_ pattern: [String], startingAt start: Int, in tokens: [Token]) -> Int? {
        var ti = start
        var pi = 0
        while pi < pattern.count {
            while ti < tokens.count && !tokens[ti].isWord { ti += 1 }
            if ti >= tokens.count { return nil }
            if tokens[ti].text.lowercased() != pattern[pi] { return nil }
            ti += 1
            pi += 1
        }
        return ti
    }

    /// Fuzzy match: collect next N word tokens (where N = entry.wrongWords.count) from input,
    /// normalize, Levenshtein-compare to entry's normalized form. Match if ratio ≤ threshold.
    private func matchFuzzy(_ prep: PreparedEntry, startingAt start: Int, in tokens: [Token], threshold: Double) -> Int? {
        var collected: [String] = []
        var ti = start
        while collected.count < prep.wrongWords.count && ti < tokens.count {
            if tokens[ti].isWord {
                collected.append(tokens[ti].text)
            }
            ti += 1
        }
        if collected.count < prep.wrongWords.count { return nil }

        let inputPhrase = collected.joined(separator: " ").normalizedForFuzzy()
        let dictPhrase = prep.normalizedWrong

        // Short phrases under 4 chars are too dangerous for fuzzy (one char = huge ratio).
        if inputPhrase.count < 4 || dictPhrase.count < 4 { return nil }

        // Quick reject: if lengths differ by more than threshold × longest, can't match.
        let maxLen = max(inputPhrase.count, dictPhrase.count)
        let maxAllowed = Int((Double(maxLen) * threshold).rounded())
        if abs(inputPhrase.count - dictPhrase.count) > maxAllowed { return nil }

        let dist = inputPhrase.levenshteinDistance(to: dictPhrase)
        if dist > maxAllowed { return nil }

        return ti
    }

    private func shouldApply(_ entry: CorrectionEntry, minConfirmed: Int) -> Bool {
        entry.confirmedCount >= minConfirmed && entry.confirmedCount > entry.rejectedCount * 2
    }
}
