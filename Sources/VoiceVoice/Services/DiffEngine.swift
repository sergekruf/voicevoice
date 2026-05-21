import Foundation

enum DiffOp: Equatable {
    case equal(Token)
    case insert(Token)
    case delete(Token)
    case replace(Token, Token)
}

enum DiffEngine {
    static func diff(_ a: [Token], _ b: [Token]) -> [DiffOp] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { .insert($0) } }
        if m == 0 { return a.map { .delete($0) } }

        // LCS DP comparing tokens case-insensitively for words.
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                if eq(a[i], b[j]) {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var ops: [DiffOp] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            if eq(a[i - 1], b[j - 1]) {
                ops.append(.equal(b[j - 1]))
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                ops.append(.delete(a[i - 1]))
                i -= 1
            } else {
                ops.append(.insert(b[j - 1]))
                j -= 1
            }
        }
        while i > 0 { ops.append(.delete(a[i - 1])); i -= 1 }
        while j > 0 { ops.append(.insert(b[j - 1])); j -= 1 }

        ops.reverse()
        return collapseToReplace(ops)
    }

    private static func eq(_ a: Token, _ b: Token) -> Bool {
        if a.kind != b.kind { return false }
        if a.kind == .word { return a.text.lowercased() == b.text.lowercased() }
        return a.text == b.text
    }

    /// Convert adjacent delete+insert (on word tokens) into a single replace.
    private static func collapseToReplace(_ ops: [DiffOp]) -> [DiffOp] {
        var result: [DiffOp] = []
        var i = 0
        while i < ops.count {
            let cur = ops[i]
            let next = i + 1 < ops.count ? ops[i + 1] : nil
            switch (cur, next) {
            case (.delete(let d), .insert(let ins)?) where d.isWord && ins.isWord:
                result.append(.replace(d, ins))
                i += 2
            case (.insert(let ins), .delete(let d)?) where d.isWord && ins.isWord:
                result.append(.replace(d, ins))
                i += 2
            default:
                result.append(cur)
                i += 1
            }
        }
        return result
    }
}

/// High-level learner: given raw Whisper output, the text shown to the user after
/// dictionary application, and the user's final edit, produce learning signals.
struct LearningSignals {
    /// Brand-new (wrong → right) confirmations to add to the dictionary.
    let confirmations: [(wrong: String, right: String, context: String?)]
    /// Auto-applied substitutions the user reverted — penalise these.
    let rejections: [(wrong: String, right: String, context: String?)]
}

enum CorrectionLearner {
    /// Extract learning signals.
    ///
    /// - Parameters:
    ///   - raw: text from the speech-to-text engine (no dictionary applied).
    ///   - applied: text as displayed/pasted (dictionary was applied to `raw`).
    ///   - final: text after user edits.
    ///   - autoApplied: the set of (wrongLowered → right) actually applied this round,
    ///     so we can detect which were reverted.
    static func extract(
        raw: String,
        applied: String,
        final: String,
        autoApplied: [(wrong: String, right: String, context: String?)]
    ) -> LearningSignals {
        let rawTokens = Tokenizer.tokenize(raw)
        let finalTokens = Tokenizer.tokenize(final)

        let ops = DiffEngine.diff(rawTokens, finalTokens)

        var confirmations: [(wrong: String, right: String, context: String?)] = []

        // Re-walk ops to recover preceding-word context.
        var idxInRaw = 0
        for op in ops {
            switch op {
            case .equal:
                idxInRaw += 1
            case .delete:
                idxInRaw += 1
            case .insert:
                break
            case .replace(let oldT, let newT):
                let oldWord = oldT.text
                let newWord = newT.text
                if !oldWord.isEmpty && !newWord.isEmpty && oldWord.lowercased() != newWord.lowercased() {
                    let ctx = Tokenizer.previousWord(in: rawTokens, beforeIndex: idxInRaw)
                    confirmations.append((wrong: oldWord.lowercased(), right: newWord, context: ctx))
                }
                idxInRaw += 1
            }
        }

        // Detect rejected auto-applications: substitution was applied but user
        // reverted (the `right` token doesn't appear at the corresponding spot
        // in `final`).
        var rejections: [(wrong: String, right: String, context: String?)] = []
        let appliedTokens = Tokenizer.tokenize(applied)
        let appliedToFinalOps = DiffEngine.diff(appliedTokens, finalTokens)
        var idxInApplied = 0
        for op in appliedToFinalOps {
            switch op {
            case .equal: idxInApplied += 1
            case .delete: idxInApplied += 1
            case .insert: break
            case .replace(let oldT, _):
                let oldLower = oldT.text.lowercased()
                if let match = autoApplied.first(where: { $0.right.lowercased() == oldLower }) {
                    rejections.append(match)
                }
                idxInApplied += 1
            }
        }

        return LearningSignals(confirmations: confirmations, rejections: rejections)
    }
}
