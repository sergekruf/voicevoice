import Foundation

/// Post-processes recognized text to make numbers paste-friendly into spreadsheets.
/// Habits we fix (Russian):
///   • Spelled-out numerals → digits: `«две тысячи пятьсот тридцать два»` → `2532`.
///     Critical for the Parakeet engine, which spells numbers out as words (Whisper
///     more often emitted digits directly).
///   • `1 миллион 475632`  (mixed digit + word multiplier) → `1475632`.
///   • `1 425 689`  (thousand-separator spaces) → `1425689`.
///   • `6532.`  at end of an utterance → strip the trailing period.
///
/// Transformations fire only inside a contiguous run of number-tokens (digits,
/// cardinal words, scale words), so plain prose stays intact. A lone «один/одна/одно»
/// is left as a word — it's almost always article-like («один из них»), not a quantity.
enum NumberNormalizer {
    static func normalize(_ text: String) -> String {
        var s = text
        s = convertNumbers(s)
        s = collapseThousandsSpaces(s)
        s = stripTrailingPeriodAfterDigits(s)
        return s
    }

    // MARK: - Spelled-out number → digits

    /// Cardinal number words → value. Nominative forms (как обычно диктуют).
    private static let numberWords: [String: Int] = [
        "ноль": 0, "нуль": 0,
        "один": 1, "одна": 1, "одно": 1, "одну": 1,
        "два": 2, "две": 2, "три": 3, "четыре": 4, "пять": 5,
        "шесть": 6, "семь": 7, "восемь": 8, "девять": 9, "десять": 10,
        "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13, "четырнадцать": 14,
        "пятнадцать": 15, "шестнадцать": 16, "семнадцать": 17, "восемнадцать": 18,
        "девятнадцать": 19,
        "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50,
        "шестьдесят": 60, "семьдесят": 70, "восемьдесят": 80, "девяносто": 90,
        "сто": 100, "двести": 200, "триста": 300, "четыреста": 400, "пятьсот": 500,
        "шестьсот": 600, "семьсот": 700, "восемьсот": 800, "девятьсот": 900,
    ]

    /// Scale (multiplier) words → magnitude.
    private static let scaleWords: [String: Int] = [
        "тысяча": 1_000, "тысячи": 1_000, "тысяч": 1_000, "тысячу": 1_000,
        "миллион": 1_000_000, "миллиона": 1_000_000, "миллионов": 1_000_000,
        "миллиард": 1_000_000_000, "миллиарда": 1_000_000_000, "миллиардов": 1_000_000_000,
        "триллион": 1_000_000_000_000, "триллиона": 1_000_000_000_000, "триллионов": 1_000_000_000_000,
    ]

    /// Lone forms of «1» we deliberately DON'T digitize — almost always article-like.
    private static let oneFormsToSkipAlone: Set<String> = ["один", "одна", "одно", "одну"]

    private static func convertNumbers(_ text: String) -> String {
        let tokens = Tokenizer.tokenize(text)
        var output = ""
        var i = 0
        while i < tokens.count {
            if let parsed = parseNumberRun(tokens: tokens, startIdx: i) {
                output += parsed.value
                i = parsed.endIdx
            } else {
                output += tokens[i].text
                i += 1
            }
        }
        return output
    }

    /// Walk forward consuming digit-tokens, cardinal-word tokens, scale-word tokens, and
    /// whitespace between them. Returns the resolved integer + the index AFTER the last
    /// consumed number-token, or nil if the run holds no numbers (or is a lone «один»).
    private static func parseNumberRun(tokens: [Token], startIdx: Int) -> (value: String, endIdx: Int)? {
        var i = startIdx
        var total = 0          // accumulated value of completed scales (… тысяч, миллионов)
        var current = 0        // value being built below the next scale
        var count = 0          // number-tokens consumed
        var lastConsumedIdx = startIdx - 1
        var firstWord: String? = nil

        while i < tokens.count {
            let token = tokens[i]
            let lower = token.text.lowercased().replacingOccurrences(of: "ё", with: "е")

            if token.isWord, let digit = Int(token.text) {
                current += digit
                count += 1; lastConsumedIdx = i; i += 1
                if firstWord == nil { firstWord = lower }
            } else if token.isWord, let v = numberWords[lower] {
                current += v
                count += 1; lastConsumedIdx = i; i += 1
                if firstWord == nil { firstWord = lower }
            } else if token.isWord, let scale = scaleWords[lower] {
                if current == 0 { current = 1 }   // «миллион» alone = 1_000_000
                total += current * scale
                current = 0
                count += 1; lastConsumedIdx = i; i += 1
                if firstWord == nil { firstWord = lower }
            } else if count >= 1 && !token.isWord && token.text.allSatisfy({ $0.isWhitespace }) {
                // Whitespace BETWEEN number tokens — keep scanning. Only after we've
                // already consumed a number, so a run can't eat leading whitespace
                // (which would glue the number to the previous word: «номер42»).
                i += 1
            } else {
                break
            }
        }

        guard count >= 1, lastConsumedIdx >= startIdx else { return nil }
        // Lone «один/одна/одно/одну» — leave as a word (article-like, not a quantity).
        if count == 1, let fw = firstWord, oneFormsToSkipAlone.contains(fw) { return nil }
        return (String(total + current), lastConsumedIdx + 1)
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
