import Foundation

enum TokenKind {
    case word
    case other
}

struct Token: Hashable {
    let kind: TokenKind
    let text: String

    var isWord: Bool { kind == .word }
}

enum Tokenizer {
    private static let wordChars: CharacterSet = {
        var cs = CharacterSet.letters
        cs.insert(charactersIn: "0123456789-_’'")
        return cs
    }()

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var buf = ""
        var bufKind: TokenKind? = nil

        for scalar in s.unicodeScalars {
            let isWord = wordChars.contains(scalar)
            let kind: TokenKind = isWord ? .word : .other
            if bufKind == nil {
                bufKind = kind
                buf.unicodeScalars.append(scalar)
            } else if bufKind == kind {
                buf.unicodeScalars.append(scalar)
            } else {
                tokens.append(Token(kind: bufKind!, text: buf))
                buf = String(scalar)
                bufKind = kind
            }
        }
        if !buf.isEmpty, let k = bufKind {
            tokens.append(Token(kind: k, text: buf))
        }
        return tokens
    }

    static func join(_ tokens: [Token]) -> String {
        tokens.map { $0.text }.joined()
    }

    static func previousWord(in tokens: [Token], beforeIndex i: Int) -> String? {
        var j = i - 1
        while j >= 0 {
            if tokens[j].isWord { return tokens[j].text.lowercased() }
            j -= 1
        }
        return nil
    }
}
