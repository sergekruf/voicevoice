import AppKit
import ApplicationServices

/// Watches the user's edits to the freshly-pasted transcription and learns corrections.
///
/// Strategy: after a paste we read the focused AX field's full value, locate where our
/// pasted text landed inside it (prefix = doc-before-paste, suffix = doc-after-paste),
/// then on every poll tick we re-read the field, strip the same prefix and suffix off
/// the new value, and diff what's left (the "paste region") against the original paste.
/// Everything outside the paste region is ignored — so the user can edit anywhere else
/// in the document and we won't mistake it for a correction.
///
/// Stops on: focus change, empty value, paste region becoming unrecoverable
/// (user edited the prefix/suffix), or 5-minute inactivity.
@MainActor
final class TextChangeWatcher {
    static let shared = TextChangeWatcher()
    private init() {}

    private struct PasteBoundary {
        let prefix: String   // doc contents before our pasted text
        let suffix: String   // doc contents after our pasted text
    }

    private var watchedElement: AXUIElement?
    private var watchedAppPid: pid_t = 0
    private var originalPasted: String = ""
    private var boundary: PasteBoundary?
    private var boundaryRetries: Int = 0
    private let maxBoundaryRetries = 5
    /// Last "edited paste region" we processed — for change detection.
    private var lastEdited: String = ""
    /// Pairs we've already recorded this session — avoids duplicate toasts.
    private var learnedKeys: Set<String> = []
    /// Substitutions the dictionary applied to THIS dictation — needed to recognise
    /// a revert (user changed our substitution back) and penalise the entry instead
    /// of learning a reverse pair («code → код»).
    private var appliedSubs: [AppliedSubstitution] = []
    /// Rejections already recorded this session — the cumulative diff re-commits the
    /// same block after every stability window, without this the entry would be
    /// penalised once per commit.
    private var rejectedKeys: Set<String> = []
    /// Set to true on every observed value change. We hold off on learning until the value
    /// has been stable for `stableThresholdPolls` consecutive polls — that way we don't
    /// capture mid-typing intermediate junk like "кодоm" while the user is still editing.
    private var pendingChanges: Bool = false
    private var stablePollCount: Int = 0
    /// Number of consecutive unchanged polls before committing. With pollInterval = 1.0 this
    /// means ~2 seconds of inactivity before the diff is captured — enough for the user to
    /// type a multi-letter correction, but not so long it feels sluggish.
    private let stableThresholdPolls: Int = 2
    private var pollTimer: Timer?
    private var inactivityDeadline: Date = .distantPast
    private var workspaceObserver: NSObjectProtocol?

    /// Apps where AX text reads are unreliable — skip watching.
    private let electronDenylist: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.hnc.Discord",
        "notion.id",
        "com.figma.Desktop",
        "com.linear",
        "com.github.Electron",
    ]

    private let pollInterval: TimeInterval = 1.0
    private let totalTimeout: TimeInterval = 300

    func startWatching(pastedText: String, frontBundleID: String?,
                       appliedSubstitutions: [AppliedSubstitution] = []) {
        stopWatching()

        if !AppSettings.shared.autoLearnCorrections {
            DebugLog.log("Watcher: auto-learn disabled in settings — skipping")
            return
        }

        if let bundle = frontBundleID, electronDenylist.contains(where: { bundle.hasPrefix($0) }) {
            DebugLog.log("Watcher: skipping \(bundle) (Electron / no AX text values)")
            return
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedRef = focused else {
            DebugLog.log("Watcher: cannot fetch focused element — app doesn't expose AX")
            return
        }
        var element = focusedRef as! AXUIElement

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else { return }

        // The systemwide focused element is sometimes a container (AXWindow in Qt apps
        // like Max — ru.oneme.desktop) whose own kAXValueAttribute isn't readable, but
        // a descendant text input does expose it. Walk the AX subtree looking for the
        // first node whose `kAXValueAttribute` is a non-empty string AND ideally has a
        // text-y role. Bail after a small depth/breadth cap so we don't stall on big trees.
        if Self.readValue(from: element) == nil {
            if let descendant = Self.findEditableDescendant(element) {
                DebugLog.log("Watcher: focused element has no value — using descendant with role=\(Self.role(of: descendant) ?? "?")")
                element = descendant
            } else {
                DebugLog.log("Watcher: focused element has no readable kAXValueAttribute and no editable descendant (pid=\(pid))")
                return
            }
        }

        self.watchedElement = element
        self.watchedAppPid = pid
        self.originalPasted = pastedText
        self.boundary = nil
        self.boundaryRetries = 0
        self.lastEdited = pastedText
        self.learnedKeys = []
        self.appliedSubs = appliedSubstitutions
        self.rejectedKeys = []
        self.inactivityDeadline = Date().addingTimeInterval(totalTimeout)

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let newPid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            if newPid != self.watchedAppPid {
                DebugLog.log("Watcher: focus moved (pid \(newPid ?? -1) ≠ \(self.watchedAppPid)) — stopping")
                Task { @MainActor in self.stopWatching() }
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        DebugLog.log("Watcher: started polling pid=\(pid), pasted=\"\(pastedText.prefix(60))\"")
    }

    func stopWatching() {
        // Flush any pending edit before we tear the session down — but ONLY if the
        // value survived at least one stable poll (~1 s idle). Otherwise the user hit
        // Enter / switched apps MID-TYPING, and we'd learn a truncated word
        // («кодом → кодо») — the stability window exists precisely against that.
        if pendingChanges, stablePollCount >= 1, !lastEdited.isEmpty, !originalPasted.isEmpty {
            DebugLog.log("Watcher: flushing pending diff before stopping")
            learnFromDiff(pasted: originalPasted, edited: lastEdited)
        } else if pendingChanges {
            DebugLog.log("Watcher: dropping mid-typing pending diff (no stable poll)")
        }
        pendingChanges = false

        pollTimer?.invalidate(); pollTimer = nil
        if let token = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObserver = nil
        watchedElement = nil
        watchedAppPid = 0
        originalPasted = ""
        boundary = nil
        boundaryRetries = 0
        lastEdited = ""
        learnedKeys.removeAll()
        appliedSubs = []
        rejectedKeys.removeAll()
        pendingChanges = false
        stablePollCount = 0
    }

    // MARK: - Tick

    private func tick() {
        if Date() > inactivityDeadline {
            DebugLog.log("Watcher: 5-min timeout, stopping")
            stopWatching()
            return
        }
        guard let el = watchedElement else { return }
        guard let newText = Self.readValue(from: el) else {
            DebugLog.log("Watcher: AX read returned nil mid-watch — stopping")
            stopWatching()
            return
        }
        if newText.isEmpty {
            DebugLog.log("Watcher: field empty (message sent?), stopping")
            stopWatching()
            return
        }

        // Establish the paste boundary on the first tick where our paste is visible.
        if boundary == nil {
            if let b = Self.computeBoundary(fullText: newText, pasted: originalPasted) {
                boundary = b
                DebugLog.log("Watcher: boundary set — prefix=\(b.prefix.count) chars, suffix=\(b.suffix.count) chars")
            } else {
                boundaryRetries += 1
                if boundaryRetries >= maxBoundaryRetries {
                    DebugLog.log("Watcher: pasted text never visible in AX field — giving up")
                    stopWatching()
                }
                return
            }
        }

        guard let boundary else { return }
        guard let edited = Self.extractEditedRegion(from: newText, boundary: boundary) else {
            DebugLog.log("Watcher: paste region lost (user edited prefix/suffix), stopping")
            stopWatching()
            return
        }
        if edited.isEmpty {
            DebugLog.log("Watcher: paste region erased, stopping")
            stopWatching()
            return
        }
        if edited == lastEdited {
            // No change since last poll. If we're holding a pending edit, count down the
            // stability window — once it's reached, commit the diff.
            if pendingChanges {
                stablePollCount += 1
                if stablePollCount >= stableThresholdPolls {
                    DebugLog.log("Watcher: stable for \(stablePollCount) polls, committing")
                    learnFromDiff(pasted: originalPasted, edited: edited)
                    pendingChanges = false
                    stablePollCount = 0
                }
            }
            return
        }

        // Value just changed — restart the stability window.
        DebugLog.log("Watcher: paste region changed (waiting for stability): \"\(edited.prefix(80))\"")
        lastEdited = edited
        pendingChanges = true
        stablePollCount = 0
        inactivityDeadline = Date().addingTimeInterval(totalTimeout)
    }

    // MARK: - Diff learning

    private func learnFromDiff(pasted: String, edited: String) {
        let oldTokens = Tokenizer.tokenize(pasted)
        let newTokens = Tokenizer.tokenize(edited)
        let ops = DiffEngine.diff(oldTokens, newTokens)

        var learned: [(wrong: String, right: String)] = []
        var i = 0
        while i < ops.count {
            // Skip equal runs.
            while i < ops.count {
                if case .equal = ops[i] { i += 1 } else { break }
            }
            if i >= ops.count { break }

            // Collect a non-equal block, but FOLD non-word equal tokens (spaces, punctuation)
            // between non-equal ops into the same block. Otherwise diff(клод кодом → Claude Code)
            // produces replace(клод,Claude) · equal(" ") · replace(кодом,Code) — and the inner
            // equal-space splits what is really a single edit into two single-word entries.
            var deletedWords: [String] = []
            var insertedTokens: [Token] = []
            collect: while i < ops.count {
                switch ops[i] {
                case .equal(let t):
                    if t.isWord { break collect }
                    // Non-word equal: look ahead — if more non-equal ops follow before any
                    // equal-word op, swallow this filler. Otherwise stop the block.
                    var j = i
                    var filler: [Token] = []
                    while j < ops.count {
                        if case .equal(let tj) = ops[j] {
                            if tj.isWord { break }
                            filler.append(tj)
                            j += 1
                        } else { break }
                    }
                    // What's at j? End of ops, equal-word, or non-equal?
                    if j >= ops.count { break collect }
                    if case .equal = ops[j] { break collect } // hit equal-word — block ends
                    // Non-equal op follows → swallow filler into inserted side and continue.
                    for f in filler { insertedTokens.append(f) }
                    i = j
                case .delete(let t):
                    if t.isWord { deletedWords.append(t.text) }
                    i += 1
                case .insert(let t):
                    insertedTokens.append(t)
                    i += 1
                case .replace(let oldT, let newT):
                    if oldT.isWord { deletedWords.append(oldT.text) }
                    insertedTokens.append(newT)
                    i += 1
                }
            }

            if deletedWords.isEmpty || insertedTokens.isEmpty { continue }

            let insertedString = collapseSpaces(insertedTokens.map { $0.text }.joined())
            if insertedString.isEmpty { continue }

            // Always store the whole edited block as a single phrase entry. Splitting
            // ["клод", "кодом"] → ["Claude", "Code"] into two single-word entries means
            // "кодом" alone (in an unrelated sentence) would later get rewritten to "Code",
            // which is wrong. The phrase "клод кодом" → "Claude Code" only applies when both
            // words appear together.
            let deletedPhrase = deletedWords.joined(separator: " ")
            record(wrong: deletedPhrase, right: insertedString, into: &learned)
        }

        if !learned.isEmpty {
            DebugLog.log("Watcher: learned \(learned.count) — \(learned.map { "\($0.wrong)→\($0.right)" }.joined(separator: ", "))")
            HUDManager.shared.showLearned(corrections: learned)
        }
    }

    private func record(wrong: String, right: String, into learned: inout [(wrong: String, right: String)]) {
        // Пользователь стёр/заменил то, что подставил СЛОВАРЬ (wrong == right одной из
        // применённых замен) → это откат автозамены. Штрафуем исходную запись; обратную
        // пару («code → код») НЕ учим — иначе в словаре заводятся противоборствующие
        // записи, а плохая исходная продолжает жить.
        if let sub = appliedSubs.first(where: { $0.right.lowercased() == wrong.lowercased() }) {
            let rejKey = sub.wrong.lowercased() + "→" + sub.right.lowercased()
            if !rejectedKeys.contains(rejKey) {
                CorrectionStore.shared.recordRejection(wrong: sub.wrong, right: sub.right, contextBefore: sub.context)
                rejectedKeys.insert(rejKey)
                DebugLog.log("Watcher: auto-substitution reverted — penalised \(sub.wrong)→\(sub.right)")
            }
            // Чистый откат к исходному слову — новой пары нет.
            if right.normalizedForFuzzy() == sub.wrong.normalizedForFuzzy() { return }
            // Заменил на ТРЕТИЙ вариант — правильная пара: сырое слово → новый текст
            // (wrong-стороной должно быть то, что реально приходит от движка).
            recordPlain(wrong: sub.wrong, right: right, into: &learned)
            return
        }
        recordPlain(wrong: wrong, right: right, into: &learned)
    }

    private func recordPlain(wrong: String, right: String, into learned: inout [(wrong: String, right: String)]) {
        guard isLearnable(wrong: wrong, right: right) else { return }
        let key = wrong.lowercased()
        if learnedKeys.contains(key) { return }
        CorrectionStore.shared.recordConfirmation(wrong: key, right: right, contextBefore: nil)
        learned.append((wrong: wrong, right: right))
        learnedKeys.insert(key)
    }

    /// Частые служебные слова. Одиночную замену такого слова («в»→«на», «и»→«а»)
    /// почти никогда не стоит учить — это либо смысловая правка, либо случайность.
    private static let stopWords: Set<String> = [
        "и", "в", "во", "не", "что", "он", "на", "я", "с", "со", "как", "а", "то", "все",
        "она", "так", "его", "но", "да", "ты", "к", "у", "же", "вы", "за", "бы", "по",
        "только", "ее", "мне", "было", "вот", "от", "меня", "о", "из", "ему", "теперь",
        "или", "ни", "об", "до", "вас", "нас", "это", "это", "для", "ли",
        "the", "a", "an", "of", "to", "in", "is", "it", "and", "or", "for",
    ]

    /// D — «умный фильтр захвата»: учим пару только если она похожа на ошибку
    /// РАСПОЗНАВАНИЯ, а не на смысловую правку пользователя.
    private func isLearnable(wrong: String, right: String) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if w.isEmpty || r.isEmpty { return false }
        if w.count < 2 || r.count < 2 { return false }
        if w.lowercased() == r.lowercased() { return false }

        // Длинные куски — почти всегда смысловой правок/перефраз, а не misrecognition.
        let wWords = w.split(whereSeparator: { $0.isWhitespace }).count
        let rWords = r.split(whereSeparator: { $0.isWhitespace }).count
        if wWords > 4 || rWords > 4 { return false }
        if w.count > 40 || r.count > 40 { return false }
        // Сильно разное число слов = вставка/удаление контента, а не замена.
        if abs(wWords - rWords) > 1 { return false }
        // Одиночное стоп-слово как «было» — отсекаем («в»→«на»).
        if wWords == 1, Self.stopWords.contains(w.lowercased().replacingOccurrences(of: "ё", with: "е")) {
            return false
        }
        // Главный фильтр: похоже ли это на ошибку распознавания.
        return looksLikeRecognitionFix(w, r)
    }

    /// Эвристика «это ошибка распознавания, а не перефраз»:
    ///  • кросс-скрипт (рус слышим как англоязычный термин) — классический реальный
    ///    кейс «клод код»→«Claude Code», для него Левенштейн неинформативен → разрешаем;
    ///  • один скрипт — требуем близость по написанию (опечатка/оговорка), отсекаем
    ///    далёкие замены вроде «хорошо»→«отлично».
    private func looksLikeRecognitionFix(_ w: String, _ r: String) -> Bool {
        let wl = w.lowercased().replacingOccurrences(of: "ё", with: "е")
        let rl = r.lowercased().replacingOccurrences(of: "ё", with: "е")
        let wCyr = Self.hasCyrillic(wl), rCyr = Self.hasCyrillic(rl)
        let wLat = Self.hasLatin(wl), rLat = Self.hasLatin(rl)
        if (wCyr && rLat && !rCyr) || (wLat && rCyr && !wCyr) { return true }
        let dist = wl.levenshteinDistance(to: rl)
        let maxLen = max(wl.count, rl.count)
        guard maxLen > 0 else { return false }
        return Double(dist) / Double(maxLen) <= 0.5
    }

    private static func hasCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
    }
    private static func hasLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) }
    }

    private func collapseSpaces(_ s: String) -> String {
        var out = s
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    private static func readValue(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    private static func role(of element: AXUIElement) -> String? {
        var role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard err == .success else { return nil }
        return role as? String
    }

    /// BFS over `kAXChildrenAttribute`, capped at depth=6 and ~200 nodes, looking for an
    /// element that's actually editable text. Returns the first node with a text-y role
    /// (TextField / TextArea / ComboBox / SearchField); failing that, the first node
    /// whose `kAXValueAttribute` is **settable**, a string, AND whose role is not on
    /// an explicit non-text deny-list (scroll bars, sliders, progress indicators —
    /// Qt apps like Max expose these with settable string-like values that aren't the
    /// actual text input).
    private static func findEditableDescendant(_ root: AXUIElement) -> AXUIElement? {
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        // Roles that may report a settable string value but are definitely not text inputs.
        let nonTextRoles: Set<String> = [
            kAXScrollBarRole as String,
            kAXSliderRole as String,
            kAXButtonRole as String,
            kAXImageRole as String,
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXMenuButtonRole as String,
            kAXPopUpButtonRole as String,
            kAXIncrementorRole as String,
            kAXProgressIndicatorRole as String,
            kAXValueIndicatorRole as String,
            kAXStaticTextRole as String,
            kAXDisclosureTriangleRole as String,
            kAXTabGroupRole as String,
            kAXToolbarRole as String,
            kAXMenuRole as String,
            kAXMenuItemRole as String,
            kAXMenuBarRole as String,
            kAXMenuBarItemRole as String,
            "AXLink",
        ]
        let maxDepth = 6
        let maxNodes = 200
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var fallback: AXUIElement? = nil

        while !queue.isEmpty, visited < maxNodes {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if depth > maxDepth { continue }

            if el != root, readValue(from: el) != nil {
                let r = role(of: el)
                if let r, editableRoles.contains(r) {
                    return el
                }
                // Fallback accepts only containers where the value is settable AND the
                // role is not a known non-text control.
                if fallback == nil,
                   isValueSettable(el),
                   r.map({ !nonTextRoles.contains($0) }) ?? true {
                    fallback = el
                }
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
               let arr = children as? [AXUIElement] {
                for child in arr {
                    queue.append((child, depth + 1))
                }
            }
        }
        return fallback
    }

    private static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    private static func computeBoundary(fullText: String, pasted: String) -> PasteBoundary? {
        guard !pasted.isEmpty else { return nil }
        // ПОСЛЕДНЕЕ вхождение: вставка происходит у курсора (обычно в конце документа).
        // Поиск первого вхождения путал регионы, когда та же фраза уже встречалась
        // выше по тексту (повторная диктовка одинаковой фразы).
        guard let range = fullText.range(of: pasted, options: .backwards) else { return nil }
        return PasteBoundary(
            prefix: String(fullText[..<range.lowerBound]),
            suffix: String(fullText[range.upperBound...])
        )
    }

    private static func extractEditedRegion(from fullText: String, boundary: PasteBoundary) -> String? {
        guard fullText.hasPrefix(boundary.prefix) else { return nil }
        let afterPrefix = String(fullText.dropFirst(boundary.prefix.count))
        guard afterPrefix.hasSuffix(boundary.suffix) else { return nil }
        return String(afterPrefix.dropLast(boundary.suffix.count))
    }
}
