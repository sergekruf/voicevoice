import Foundation

/// Appends a single, context-appropriate emoji to the recognized text when a known
/// trigger phrase is present. Conservative by design — at most one emoji per
/// recognition, deduped against any emoji already in the text. Opt-in via
/// `AppSettings.autoEmoji` (default off).
///
/// Triggers favor unambiguous emotional / social phrases (greetings, thanks, laughter,
/// celebrations). Very common words like "да" / "нет" / "хорошо" are deliberately NOT
/// triggers — they appear in nearly every sentence and would spam emojis.
enum EmojiEnhancer {
    private struct Rule {
        let pattern: NSRegularExpression
        let emoji: String
    }

    /// Each pattern uses `(^|\W)<phrase>(\W|$)` to anchor on word boundaries that also
    /// work with Cyrillic (Swift's `\b` is unreliable across scripts on macOS NSRegex).
    private static let rules: [Rule] = {
        let entries: [(String, String)] = [
            // Laughter
            ("(^|\\W)(ха-?ха|хах|хихи)(\\W|$)", "😄"),
            ("(^|\\W)(лол|lol|ржу)(\\W|$)", "😂"),
            // Celebration
            ("(^|\\W)(поздравляю|с\\s+днем\\s+рождения|с\\s+днём\\s+рождения|с\\s+праздником|ура)(\\W|$)", "🎉"),
            // Thanks
            ("(^|\\W)(спасибо|благодарю)(\\W|$)", "🙏"),
            // Greeting
            ("(^|\\W)(привет|здравствуй|здравствуйте|доброе\\s+утро|добрый\\s+день|добрый\\s+вечер)(\\W|$)", "👋"),
            // Farewell
            ("(^|\\W)(пока|до\\s+свидания|до\\s+встречи)(\\W|$)", "👋"),
            // Love
            ("(^|\\W)(люблю|обожаю)(\\W|$)", "❤️"),
            // Approval
            ("(^|\\W)(круто|супер|класс|классно|отлично|здорово)(\\W|$)", "👍"),
            // Apology
            ("(^|\\W)(извини|извините|прости|простите|sorry)(\\W|$)", "🙏"),
            // Sadness
            ("(^|\\W)(грустно|печально)(\\W|$)", "😢"),
            // Fire / hype
            ("(^|\\W)(огонь|пожар)(\\W|$)", "🔥"),
            // Good luck / wishes
            ("(^|\\W)(удачи|удачно)(\\W|$)", "🍀"),
        ]
        return entries.compactMap { entry in
            guard let re = try? NSRegularExpression(pattern: entry.0, options: [.caseInsensitive]) else { return nil }
            return Rule(pattern: re, emoji: entry.1)
        }
    }()

    /// Returns `text` unchanged if no trigger matched OR the picked emoji is already
    /// present. Otherwise returns `text` with a single emoji appended, preserving any
    /// trailing whitespace / newlines so it doesn't disrupt formatting downstream.
    static func enhance(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        // Pick the LAST matching trigger in the text — feels more natural (emoji attaches
        // to the closing thought, not the opening word).
        var bestLocation = -1
        var bestEmoji: String? = nil
        for rule in rules {
            guard let match = rule.pattern.firstMatch(in: text, options: [], range: range) else { continue }
            if match.range.location > bestLocation {
                bestLocation = match.range.location
                bestEmoji = rule.emoji
            }
        }
        guard let emoji = bestEmoji else { return text }
        if text.contains(emoji) { return text }

        // Split off any trailing whitespace/newlines so we insert " <emoji>" between
        // the content and the suffix (`"Спасибо!\n"` → `"Спасибо! 🙏\n"`).
        var contentEnd = text.endIndex
        while contentEnd > text.startIndex {
            let prev = text.index(before: contentEnd)
            let ch = text[prev]
            if ch.isWhitespace || ch.isNewline {
                contentEnd = prev
            } else {
                break
            }
        }
        let content = String(text[..<contentEnd])
        let trailing = String(text[contentEnd...])
        return content + " " + emoji + trailing
    }
}
