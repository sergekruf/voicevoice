import Foundation

/// Post-processes recognized text to make numbers paste-friendly into spreadsheets.
/// Habits we fix (Russian):
///   • Spelled-out numerals → digits: `«две тысячи пятьсот тридцать два»` → `2532`.
///     Critical for the Parakeet engine, which spells numbers out as words (Whisper
///     more often emitted digits directly).
///   • `1 миллион 475632`  (mixed digit + word multiplier) → `1475632`.
///   • `1 425 689`  (thousand-separator spaces) → `1425689`.
///   • `6532.`  at end of an utterance → strip the trailing period.
///   • Ordinals: `«с двадцать четвёртого по сороковой»` → `с 24-го по 40-й`
///     (наращение по норме; перед месяцем — без него: `«первое сентября»` →
///     `1 сентября`). Одиночные мелкие («первый раз») не трогаем.
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

    // MARK: - Ordinals («двадцать четвёртого» → «24-го»)

    /// Основы порядковых числительных (ё уже приведена к е). Слово распознаётся
    /// как порядковое, только если оно ЦЕЛИКОМ равно основа+окончание из
    /// `ordinalEndings` — по префиксу не матчим («переводом», «шестерня» не влезут).
    /// Сотые/тысячные намеренно отсутствуют: одиночные «сотый раз», «сотые доли» —
    /// почти всегда обычная речь, а в составных («сто двадцать пятый») сотни
    /// приходят количественным словом и финал всё равно за единицами/десятками.
    private static let ordinalStems: [(stem: String, value: Int)] = [
        ("одиннадцат", 11), ("двенадцат", 12), ("тринадцат", 13), ("четырнадцат", 14),
        ("пятнадцат", 15), ("шестнадцат", 16), ("семнадцат", 17), ("восемнадцат", 18),
        ("девятнадцат", 19), ("двадцат", 20), ("тридцат", 30), ("сороков", 40),
        ("пятидесят", 50), ("шестидесят", 60), ("семидесят", 70), ("восьмидесят", 80),
        ("девяност", 90),
        ("перв", 1), ("втор", 2), ("четверт", 4), ("пят", 5), ("шест", 6),
        ("седьм", 7), ("восьм", 8), ("девят", 9), ("десят", 10),
    ]

    /// Твёрдые адъективные окончания порядковых. Мягких («-им», «-ей»…) тут
    /// сознательно нет: у твёрдых основ их не бывает, а их наличие ловило бы
    /// глаголы вроде «вторим». «Третий» (единственная мягкая основа) — отдельно.
    private static let ordinalEndings: Set<String> = [
        "ый", "ой", "ая", "ое", "ую", "ого", "ому", "ым", "ом", "ые", "ых", "ыми",
    ]

    /// Все формы «третий» (мягкая основа — под общие окончания не подходит).
    private static let thirdForms: Set<String> = [
        "третий", "третья", "третье", "третьего", "третьей", "третьему",
        "третьим", "третью", "третьи", "третьих", "третьими", "третьем",
    ]

    /// Перед названием месяца наращение не пишется: «девятнадцатое августа» →
    /// «19 августа» (типографская норма дат).
    private static let monthNames: Set<String> = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]

    /// Слово — порядковое числительное? Возвращает значение и наращение
    /// («четвёртого» → (4, "го"), «сороковой» → (40, "й")).
    private static func ordinalWord(_ word: String) -> (value: Int, suffix: String)? {
        if thirdForms.contains(word) { return (3, ordinalSuffix(of: word)) }
        for (stem, value) in ordinalStems where word.hasPrefix(stem) {
            if ordinalEndings.contains(String(word.dropFirst(stem.count))) {
                return (value, ordinalSuffix(of: word))
            }
        }
        return nil
    }

    /// Наращение по норме Мильчина: одна буква, если предпоследняя буква слова —
    /// гласная («сороковой» → «-й»), две — если согласная («четвёртого» → «-го»).
    /// «ь» считаем за гласную ради форм «третья» → «-я».
    private static func ordinalSuffix(of word: String) -> String {
        let chars = Array(word)
        guard chars.count >= 2 else { return "" }
        let vowels: Set<Character> = ["а", "е", "и", "о", "у", "ы", "э", "ю", "я"]
        let prev = chars[chars.count - 2]
        if vowels.contains(prev) || prev == "ь" {
            return String(chars[chars.count - 1])
        }
        return String(chars.suffix(2))
    }

    private static func followedByMonth(tokens: [Token], from idx: Int) -> Bool {
        var j = idx
        while j < tokens.count, !tokens[j].isWord {
            guard tokens[j].text.allSatisfy({ $0.isWhitespace }) else { return false }
            j += 1
        }
        guard j < tokens.count else { return false }
        return monthNames.contains(tokens[j].text.lowercased().replacingOccurrences(of: "ё", with: "е"))
    }

    /// Scale forms that MAY stand for «1×scale» with no numeral before them:
    /// «миллион рублей» = 1 000 000. Plural/genitive forms («тысячи людей»,
    /// «миллионов») without a numeral are plain prose, never a quantity.
    private static let implicitOneScaleForms: Set<String> = [
        "тысяча", "тысячу", "миллион", "миллиард", "триллион",
    ]

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
    ///
    /// Adjacent numbers are merged ONLY in valid Russian cardinal order (hundreds →
    /// tens → units): «сто двадцать один» → 121, but «один два три» stays three
    /// separate numbers and «1 425 689» is left for `collapseThousandsSpaces` —
    /// blind summing turned those into 6 and 1115.
    private static func parseNumberRun(tokens: [Token], startIdx: Int) -> (value: String, endIdx: Int)? {
        var i = startIdx
        var total = 0          // accumulated value of completed scales (… тысяч, миллионов)
        var current = 0        // value being built below the next scale
        var count = 0          // number-tokens consumed
        var digitTokens = 0    // из них — готовых цифровых групп («680», «000»)
        var lastConsumedIdx = startIdx - 1
        var firstWord: String? = nil
        // Наращение порядкового финала («-го», «-й»); non-nil = ряд завершился
        // порядковым числительным.
        var ordinalSuffix: String? = nil
        // Value of the last cardinal WORD merged into `current`; nil after a digit
        // token or a scale word. Gates composition order.
        var lastCardinal: Int? = nil
        // A digit token («425») is already a complete number — only a scale word
        // may follow it («1 миллион»), never another digit/cardinal to sum with.
        var lastWasDigits = false

        while i < tokens.count {
            let token = tokens[i]
            let lower = token.text.lowercased().replacingOccurrences(of: "ё", with: "е")

            if token.isWord, let digits = Int(token.text) {
                if current != 0 || lastWasDigits { break }   // «1 425» / «двадцать 5» — separate numbers
                current = digits
                lastWasDigits = true
                lastCardinal = nil
                count += 1; digitTokens += 1; lastConsumedIdx = i; i += 1
                if firstWord == nil { firstWord = lower }
            } else if token.isWord, let v = numberWords[lower] {
                if lastWasDigits { break }                    // «25 пять» — separate numbers
                if let prev = lastCardinal {
                    // Valid composition only: hundreds (100…900) may be followed by
                    // anything below a hundred; tens (20…90) — by units (1…9).
                    let composes = (prev >= 100 && v < 100) || (prev >= 20 && prev <= 90 && 1...9 ~= v)
                    if !composes { break }                    // «один два три» — separate numbers
                }
                current += v
                lastCardinal = v
                count += 1; lastConsumedIdx = i; i += 1
                if firstWord == nil { firstWord = lower }
            } else if token.isWord, let ord = ordinalWord(lower) {
                // Порядковое всегда ЗАВЕРШАЕТ число: «двадцать четвёртого» → 24-го,
                // «две тысячи двадцать пятый» → 2025-й.
                if count == 0 {
                    // Одиночное порядковое — цифрой только 10..99 («по сороковой» →
                    // «по 40-й») или дата перед месяцем («первое сентября» →
                    // «1 сентября»). «Первый раз», «сотый» — обычная речь.
                    guard 10...99 ~= ord.value || followedByMonth(tokens: tokens, from: i + 1) else {
                        return nil
                    }
                } else if let prev = lastCardinal {
                    let composes = (prev >= 100 && ord.value < 100)
                        || (prev >= 20 && prev <= 90 && 1...9 ~= ord.value)
                    if !composes { break }
                } else if lastWasDigits {
                    // «20 четвёртого» (движок сам смешал цифры со словом) — чиним
                    // только валидную композицию круглых десятков с единицами.
                    let composes = 20...90 ~= current && current % 10 == 0 && 1...9 ~= ord.value
                    if !composes { break }
                } else if current != 0 {
                    break
                }
                current += ord.value
                ordinalSuffix = ord.suffix
                count += 1; lastConsumedIdx = i; i += 1
                if firstWord == nil { firstWord = lower }
                break
            } else if token.isWord, let scale = scaleWords[lower] {
                // Without a numeral before it, only «тысяча/миллион/…» (sing. nom./acc.)
                // means a quantity; «тысячи людей», «миллионов» — plain prose.
                if current == 0 && !implicitOneScaleForms.contains(lower) { break }
                if current == 0 { current = 1 }   // «миллион» alone = 1_000_000
                total += current * scale
                current = 0
                lastCardinal = nil
                lastWasDigits = false
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
        // Одиночная ЦИФРОВАЯ группа без слов и множителей — уже готовое число,
        // НЕ перерендериваем: String(Int) уничтожал ведущие нули («680 000» —
        // группа «000» превращалась в «0», выходило «680 0»). Пробельные группы
        // разрядов склеивает collapseThousandsSpaces, как и задумано.
        if count == 1 && digitTokens == 1 { return nil }
        var rendered = String(total + current)
        if let suffix = ordinalSuffix, !suffix.isEmpty,
           !followedByMonth(tokens: tokens, from: lastConsumedIdx + 1) {
            rendered += "-" + suffix
        }
        return (rendered, lastConsumedIdx + 1)
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
