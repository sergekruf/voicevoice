import Foundation

/// Post-processes recognized text to make numbers paste-friendly into spreadsheets.
/// Whisper has several annoying habits in Russian:
///   • `1 425 689`  (thousand-separator spaces) — collapse to `1425689`.
///   • `1 миллион 475632`  (mixed digit + word multiplier) — resolve to `1475632`.
///   • `6532.`  at end of an utterance — strip the trailing period.
///
/// We fix all three. Transformations are conservative — plain prose ("Москва, 1500 лет.")
/// stays intact because the parser only fires inside a contiguous run of digits and
/// number-multiplier words, with at least one multiplier present.
enum NumberNormalizer {
    static func normalize(_ text: String) -> String {
        var s = text
        s = resolveCompoundNumbers(s)
        s = collapseThousandsSpaces(s)
        s = stripTrailingPeriodAfterDigits(s)
        return s
    }

    // MARK: - Compound number resolution
    // "1 миллион 475632" → "1475632"
    // "5 миллионов 200 тысяч 300" → "5200300"
    // "2024 года" → "2024 года"  (no multiplier → not touched)

    /// Russian grammatical forms of thousand / million / billion / trillion → numeric magnitude.
    private static let multipliers: [String: Int] = [
        "тысяча": 1_000, "тысячи": 1_000, "тысяч": 1_000, "тысячу": 1_000,
        "миллион": 1_000_000, "миллиона": 1_000_000, "миллионов": 1_000_000,
        "миллиард": 1_000_000_000, "миллиарда": 1_000_000_000, "миллиардов": 1_000_000_000,
        "триллион": 1_000_000_000_000, "триллиона": 1_000_000_000_000, "триллионов": 1_000_000_000_000,
    ]

    private static func resolveCompoundNumbers(_ text: String) -> String {
        let tokens = Tokenizer.tokenize(text)
        var output = ""
        var i = 0
        while i < tokens.count {
            if let parsed = parseNumberExpression(tokens: tokens, startIdx: i) {
                output += parsed.value
                i = parsed.endIdx
            } else {
                output += tokens[i].text
                i += 1
            }
        }
        return output
    }

    /// Walk forward from `startIdx` as long as we see digit-tokens, multiplier-tokens, or
    /// whitespace between them. Returns the resolved integer + the index AFTER the last
    /// consumed token, ONLY if the run contained at least one multiplier (otherwise we
    /// don't transform — plain digits are already fine).
    private static func parseNumberExpression(tokens: [Token], startIdx: Int) -> (value: String, endIdx: Int)? {
        var i = startIdx
        var total = 0
        var current = 0
        var hasMultiplier = false
        var lastConsumedIdx = startIdx - 1

        while i < tokens.count {
            let token = tokens[i]
            let lower = token.text.lowercased()

            if token.isWord, let digit = Int(token.text) {
                current = digit
                lastConsumedIdx = i
                i += 1
            } else if token.isWord, let mult = multipliers[lower] {
                if current == 0 { current = 1 }   // "миллион" alone means 1_000_000
                total += current * mult
                current = 0
                hasMultiplier = true
                lastConsumedIdx = i
                i += 1
            } else if !token.isWord && token.text.allSatisfy({ $0.isWhitespace }) {
                // Whitespace between number-related tokens — pass through but don't claim it
                // as part of the consumed range yet.
                i += 1
            } else {
                break
            }
        }

        guard hasMultiplier, lastConsumedIdx >= startIdx else { return nil }
        let finalValue = total + current
        return (String(finalValue), lastConsumedIdx + 1)
    }

    // MARK: - Thousand-separator space collapse
    // "1 425 689" → "1425689", but "2024 года" stays.

    private static func collapseThousandsSpaces(_ s: String) -> String {
        let pattern = #"(\d)[ \t ]+(\d{3})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = s
        var previous: String
        repeat {
            previous = result
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1$2")
        } while result != previous
        return result
    }

    // MARK: - Trailing period strip
    // "6532." → "6532".  "12.5" stays.

    private static func stripTrailingPeriodAfterDigits(_ s: String) -> String {
        let pattern = #"(\d+)\.\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
    }
}
