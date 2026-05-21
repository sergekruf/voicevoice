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

    func startWatching(pastedText: String, frontBundleID: String?) {
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
        // Flush any pending edit before we tear the session down. Without this, edits made
        // less than 6s before the user moves focus / sends the message are lost.
        if pendingChanges, !lastEdited.isEmpty, !originalPasted.isEmpty {
            DebugLog.log("Watcher: flushing pending diff before stopping")
            learnFromDiff(pasted: originalPasted, edited: lastEdited)
            pendingChanges = false
        }

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
        guard isLearnable(wrong: wrong, right: right) else { return }
        let key = wrong.lowercased()
        if learnedKeys.contains(key) { return }
        CorrectionStore.shared.recordConfirmation(wrong: key, right: right, contextBefore: nil)
        learned.append((wrong: wrong, right: right))
        learnedKeys.insert(key)
    }

    private func isLearnable(wrong: String, right: String) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if w.isEmpty || r.isEmpty { return false }
        if w.count < 2 || r.count < 2 { return false }
        if w.lowercased() == r.lowercased() { return false }
        return true
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
        guard let range = fullText.range(of: pasted) else { return nil }
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
