import AppKit
import Carbon.HIToolbox
import ApplicationServices

enum PasteOutcome: Equatable {
    case pending             // paste task just started, no result yet
    case pasted              // text landed in an AX-verifiable editable field; auto-learn watcher will track edits
    case pastedNoAutoLearn   // tier 1 was trusted in an AX-unreadable app; auto-learn watcher CAN'T run → surface HUD with manual Edit & Learn
    case clipboardOnly       // no editable field — text dropped into clipboard, hint shown
    case failed              // editable field, but all paste tiers couldn't deliver — text in clipboard
    case skipped             // autoPaste disabled or empty text
}

/// Three-tier paste strategy. Each tier covers a TCC failure mode of the previous one.
///
/// 1. CGEvent — 4-event Cmd+V sequence on `.cghidEventTap` with `.hidSystemState` source.
///    Mirrors what Raycast / Alfred / whisper-mac / speak2 all do. Requires Accessibility
///    actually granted to this code-signature hash.
/// 2. AppleScript — `tell System Events to keystroke "v" using command down`. Requires
///    Automation permission for System Events. NSAppleScript executeAndReturnError DOES
///    trigger the macOS prompt on first call (when Info.plist has NSAppleEventsUsageDescription).
/// 3. AXUIElement direct text injection on the focused element. Last-resort for Cocoa-native
///    text fields; skipped for Electron/Chromium apps (it crashes Slack/VS Code).
final class TextInserter {
    static let shared = TextInserter()
    private init() {}

    /// Persistent ring buffer of the last N texts we have ever written to the clipboard
    /// (across app restarts). On the next paste cycle, if the clipboard's current primary
    /// string matches any of these, the content is OUR leftover — we capture an empty
    /// snapshot so the post-paste "restore" clears the clipboard rather than putting our
    /// own previously-pasted text back into it.
    private let recentPasteTextsKey = "recentPasteTexts"
    private let recentPasteHistoryLimit = 10

    private var recentPasteTexts: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentPasteTextsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: recentPasteTextsKey) }
    }

    private func recordOurClipboardWrite(_ text: String) {
        var list = recentPasteTexts
        list.removeAll { $0 == text } // de-dupe, freshest at the end
        list.append(text)
        if list.count > recentPasteHistoryLimit {
            list.removeFirst(list.count - recentPasteHistoryLimit)
        }
        recentPasteTexts = list
    }

    private func isOursLeftover(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return recentPasteTexts.contains(s)
    }

    /// Convention from http://nspasteboard.org — clipboard managers that respect it
    /// (Maccy, Paste, Raycast, PasteNow, …) skip pasteboard items carrying this type,
    /// so our temporary write (only there to feed ⌘V) doesn't end up in history.
    private static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Write `text` to the pasteboard with the TransientType marker. Used as the staging
    /// step before synthesizing ⌘V; if the paste lands and we don't need to keep the text,
    /// `restoreClipboard` rolls back to the previous content and managers see no new entry.
    private func writeTransientText(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: Self.transientPasteboardType)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Write `text` as a normal pasteboard string (no markers). Used when we *want*
    /// clipboard managers to capture the entry — i.e., when `alwaysKeepInClipboard` is on
    /// or all paste tiers failed and the user needs to ⌘V manually later.
    private func writePlainText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Common post-paste step on any successful tier: either rewind to the previous
    /// clipboard (default) or promote our transient write to a plain entry so clipboard
    /// managers pick it up (when `alwaysKeepInClipboard` is on).
    private func finalizeAfterPaste(text: String, keepInClipboard: Bool, savedClipboard: ClipboardSnapshot) async {
        if keepInClipboard {
            writePlainText(text)
        } else {
            await restoreClipboard(savedClipboard)
        }
    }

    /// Asynchronous paste. Returns the outcome so the caller can update its UI state
    /// (typically `AppController.lastPasteOutcome` → reflected in the unified ResultHUD).
    func paste(_ text: String) async -> PasteOutcome {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontName = frontApp?.localizedName ?? "?"
        let frontBundle = frontApp?.bundleIdentifier ?? "?"
        DebugLog.log("Paste: length=\(text.count), front=\(frontName) [\(frontBundle)]")
        return await runPasteChain(text: text, bundleID: frontBundle)
    }

    func copyOnly(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func runPasteChain(text: String, bundleID: String) async -> PasteOutcome {
        let keepInClipboard = AppSettings.shared.alwaysKeepInClipboard
        let focusedElement = Self.copyFocusedElement()
        let editability = Self.classifyFocus(focusedElement)
        DebugLog.log("Paste: focus classification = \(editability)")

        if editability == .notEditable {
            writePlainText(text)
            recordOurClipboardWrite(text)
            return .clipboardOnly
        }

        // Editable (or AX-unreadable but likely text field) → attempt real paste.
        // Snapshot the previous clipboard. If the clipboard's current text matches any
        // text WE wrote earlier (even across app restarts), it's leftover from us —
        // capture an empty snapshot so the restore step clears it instead of putting
        // our own previously-pasted text back into the clipboard.
        let currentClipboard = NSPasteboard.general.string(forType: .string)
        let savedClipboard: ClipboardSnapshot
        if isOursLeftover(currentClipboard) {
            DebugLog.log("Clipboard: current content is our leftover — will clear after paste")
            savedClipboard = .empty
        } else {
            savedClipboard = ClipboardSnapshot.capture()
        }
        let preValue = focusedElement.flatMap { Self.readValue(from: $0) }
        let canVerify = editability == .editable && preValue != nil

        writeTransientText(text)
        recordOurClipboardWrite(text)

        // Tier 1: CGEvent ⌘V
        let cgOk = synthesizeCmdVViaCGEvent()
        DebugLog.log("Paste tier1 (CGEvent): dispatched=\(cgOk)")
        try? await Task.sleep(nanoseconds: 450_000_000)

        if canVerify {
            if Self.pasteLanded(element: focusedElement, pastedText: text, preValue: preValue) {
                DebugLog.log("Paste: tier1 verified via AX — restoring previous clipboard")
                await finalizeAfterPaste(text: text, keepInClipboard: keepInClipboard, savedClipboard: savedClipboard)
                return .pasted
            }
        } else {
            // AX-unreadable path: tier 1 was dispatched but we cannot verify via AXValue.
            // In practice ⌘V lands in the vast majority of these apps (Electron with AX
            // disabled like Termius, Qt apps like Max, etc.). We trust tier 1 succeeded,
            // but return `.pastedNoAutoLearn` so AppController surfaces a HUD with the
            // Edit & Learn button — auto-learn watcher physically can't track edits in
            // these apps, and this is the only way for the user to teach the dictionary.
            //
            // Clipboard finalize is symmetric with the `.editable` branch:
            //   • alwaysKeepInClipboard = true  → promote our transient write to a plain
            //     entry so clipboard managers pick it up;
            //   • alwaysKeepInClipboard = false → restore the saved snapshot, otherwise
            //     the user's next ⌘V re-pastes the dictation (TransientType marker is
            //     only respected by clipboard managers, not by the system pasteboard).
            DebugLog.log("Paste: AX unverifiable — trusting tier1, no auto-learn possible (HUD with Edit & Learn)")
            await finalizeAfterPaste(text: text, keepInClipboard: keepInClipboard, savedClipboard: savedClipboard)
            return .pastedNoAutoLearn
        }

        // Tier 2: AppleScript via NSAppleScript.
        let aplOk = await runAppleScriptKeystrokeV()
        DebugLog.log("Paste tier2 (NSAppleScript): ok=\(aplOk)")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Self.pasteLanded(element: focusedElement, pastedText: text, preValue: preValue) {
            DebugLog.log("Paste: tier2 verified via AX — restoring clipboard")
            await finalizeAfterPaste(text: text, keepInClipboard: keepInClipboard, savedClipboard: savedClipboard)
            return .pasted
        }

        // Tier 2b: osascript subprocess.
        let osa2Ok = await runOsascriptSubprocess()
        DebugLog.log("Paste tier2b (osascript): ok=\(osa2Ok)")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Self.pasteLanded(element: focusedElement, pastedText: text, preValue: preValue) {
            DebugLog.log("Paste: tier2b verified via AX — restoring clipboard")
            await finalizeAfterPaste(text: text, keepInClipboard: keepInClipboard, savedClipboard: savedClipboard)
            return .pasted
        }

        // Tier 3: AXUIElement direct text insertion. Native Cocoa text views only.
        if !isElectronApp(bundleID) {
            let axOk = await insertViaAXUI(text: text)
            DebugLog.log("Paste tier3 (AXUIElement): ok=\(axOk)")
            if axOk {
                await finalizeAfterPaste(text: text, keepInClipboard: keepInClipboard, savedClipboard: savedClipboard)
                return .pasted
            }
        } else {
            DebugLog.log("Paste tier3 skipped: \(bundleID) is Electron/Chromium")
        }

        // All tiers failed — promote the transient write to a clean clipboard entry
        // so the user can ⌘V manually and clipboard managers capture it in history.
        DebugLog.log("Paste: all tiers failed. Text kept in clipboard for manual ⌘V.")
        writePlainText(text)
        return .failed
    }

    /// Re-applies a previous clipboard snapshot after a short delay so the target app has
    /// had time to consume our paste. If the snapshot is empty (because we detected the
    /// captured content was our own leftover), restore() just clearContents().
    private func restoreClipboard(_ snapshot: ClipboardSnapshot) async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        snapshot.restore()
    }

    enum Editability: CustomStringConvertible {
        case editable          // AX exposes a text-y role on the focused element
        case axUnreadable      // we can't read the role (Electron) — best-guess editable
        case notEditable       // role is clearly non-editable (button, static text, image, etc.)

        var description: String {
            switch self {
            case .editable: return "editable"
            case .axUnreadable: return "axUnreadable"
            case .notEditable: return "notEditable"
            }
        }
    }

    /// Decide whether the focused AX element is a text-input the user can type into.
    /// • `editable` — role is one of the known text roles. Paste will go in.
    /// • `axUnreadable` — focused element exists but role is unreadable (Electron, etc.).
    ///   We attempt paste anyway, but cannot verify it landed.
    /// • `notEditable` — no focus at all, or role is clearly non-text (button, image, …).
    ///   We skip paste entirely and just put text in the clipboard.
    private static func classifyFocus(_ element: AXUIElement?) -> Editability {
        guard let element else {
            // No focused element exposed by AX (e.g., some Chromium/CEF apps like Bitrix24
            // don't surface their focus through the systemwide query). Attempt paste
            // anyway — if there's truly no field, ⌘V is a harmless no-op and we fall
            // through to .failed → text stays in clipboard.
            DebugLog.log("Paste: no focused AX element → assuming editable (axUnreadable)")
            return .axUnreadable
        }

        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleStr = role as? String
        else {
            // Element exists but role isn't readable → likely Electron/non-AX → try anyway.
            return .axUnreadable
        }

        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        if editableRoles.contains(roleStr) { return .editable }

        // Some apps use AXGroup or AXScrollArea around a real text view. Probe for a
        // settable value attribute as a secondary signal.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable
        }

        // Explicit deny-list of obviously non-text controls. Anything else (AXGroup,
        // AXScrollArea, AXWebArea, AXStaticText, AXUnknown, Qt/Chromium/custom widgets, …)
        // falls through to `.axUnreadable` so we still attempt paste — Qt apps like Max
        // (ru.oneme.desktop) and Chromium apps like Bitrix24 expose non-standard or
        // misleading roles on text inputs (e.g. AXStaticText for the editable text
        // content), but a synthesized ⌘V actually works.
        let nonEditableRoles: Set<String> = [
            kAXButtonRole as String,
            kAXImageRole as String,
            "AXLink",
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXMenuButtonRole as String,
            kAXMenuItemRole as String,
            kAXMenuRole as String,
            kAXMenuBarRole as String,
            kAXMenuBarItemRole as String,
            kAXSliderRole as String,
            kAXScrollBarRole as String,
            kAXPopUpButtonRole as String,
        ]
        if nonEditableRoles.contains(roleStr) {
            DebugLog.log("Paste: focus role '\(roleStr)' is in non-editable deny-list → notEditable")
            return .notEditable
        }

        DebugLog.log("Paste: focus role '\(roleStr)' not in editable list → assuming editable (axUnreadable)")
        return .axUnreadable
    }

    /// Capture the currently-focused AX element. Tries the systemwide query first; if
    /// that returns nothing (Chromium/CEF apps like Bitrix24 sometimes don't surface
    /// focus that way), falls back to querying the frontmost application directly.
    /// Returns nil only if both queries fail or AX permission was denied.
    private static func copyFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focusedRef = focused {
            return (focusedRef as! AXUIElement)
        }

        // Per-process fallback.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var appFocused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocused) == .success,
           let appFocusedRef = appFocused {
            DebugLog.log("Paste: focused element resolved via per-app AX query (pid=\(pid))")
            return (appFocusedRef as! AXUIElement)
        }
        return nil
    }

    private static func readValue(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Verification: re-read the SAME element we captured at paste-start and decide
    /// whether the paste actually landed. Handles three cases:
    ///   • simple append: post != pre AND post.contains(pastedText)
    ///   • paste-over-selection: post may be SHORTER than pre, but still contains pastedText
    ///   • duplicate paste: pastedText was already in pre — require the occurrence count to grow
    private static func pasteLanded(element: AXUIElement?, pastedText: String, preValue: String?) -> Bool {
        guard let element, let post = readValue(from: element) else { return false }
        let preCount = preValue?.count ?? 0
        let postContains = post.contains(pastedText)

        let landed: Bool
        if let pre = preValue, pre.contains(pastedText) {
            // Edge case: the document already contained our text. Verify by occurrence count.
            let before = countOccurrences(of: pastedText, in: pre)
            let after = countOccurrences(of: pastedText, in: post)
            landed = postContains && after > before
        } else {
            // Default case: paste landed iff the document changed AND now contains our text.
            landed = postContains && post != preValue
        }

        DebugLog.log("Paste verify: preCount=\(preCount) postCount=\(post.count) contains=\(postContains) → landed=\(landed)")
        return landed
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0
        var idx = haystack.startIndex
        while let found = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            n += 1
            idx = found.upperBound
        }
        return n
    }

    // MARK: - Tier 1: CGEvent

    private func synthesizeCmdVViaCGEvent() -> Bool {
        // `.hidSystemState` mirrors what a physical keyboard would do — no modifier state
        // is inherited from our process. Don't use `.combinedSessionState` for synthetic paste.
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let cmdKey: CGKeyCode = CGKeyCode(kVK_Command)
        let vKey: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: false)
        else { return false }

        // V events must explicitly carry the command flag for apps that look at the V event
        // alone (sandboxed Cocoa text views sometimes do this).
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // Delay so the Fn-release flagsChanged from the hotkey has fully propagated.
        let loc: CGEventTapLocation = .cghidEventTap
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) {
            cmdDown.post(tap: loc)
            usleep(15_000)
            vDown.post(tap: loc)
            usleep(15_000)
            vUp.post(tap: loc)
            usleep(15_000)
            cmdUp.post(tap: loc)
            DebugLog.log("Paste tier1: 4 events posted to cghidEventTap")
        }
        return true
    }

    // MARK: - Tier 2: AppleScript

    @MainActor
    private func runAppleScriptKeystrokeV() async -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        guard let scriptObj = NSAppleScript(source: script) else { return false }
        var err: NSDictionary?
        let result = scriptObj.executeAndReturnError(&err)
        if let err {
            DebugLog.log("Paste tier2: NSAppleScript error \(err)")
            return false
        }
        _ = result
        return true
    }

    // MARK: - Tier 2b: osascript subprocess

    private func runOsascriptSubprocess() async -> Bool {
        return await withCheckedContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
            let pipe = Pipe()
            task.standardError = pipe
            task.terminationHandler = { p in
                let errData = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if !errStr.isEmpty {
                    DebugLog.log("Paste tier2b stderr: \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                cont.resume(returning: p.terminationStatus == 0)
            }
            do {
                try task.run()
            } catch {
                DebugLog.log("Paste tier2b launch failed: \(error)")
                cont.resume(returning: false)
            }
        }
    }

    // MARK: - Tier 3: AXUIElement

    @MainActor
    private func insertViaAXUI(text: String) async -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focusedRef = focused else {
            DebugLog.log("Paste tier3: cannot get focused element err=\(err.rawValue)")
            return false
        }
        let element = focusedRef as! AXUIElement

        // Cap chunk size — Electron has a known crash at >2040 chars. Even though we
        // skip Electron explicitly, native Cocoa text views can be slow with huge strings.
        let chunk = String(text.prefix(2000))

        let setErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, chunk as CFString)
        if setErr != .success {
            DebugLog.log("Paste tier3: AXUIElementSetAttributeValue err=\(setErr.rawValue)")
            return false
        }
        return true
    }

    /// Trigger the macOS Automation prompt for System Events by actually trying to run a
    /// no-op AppleScript. `AEDeterminePermissionToAutomateTarget` doesn't reliably prompt
    /// on Tahoe — only an actual NSAppleScript invocation does.
    @discardableResult
    static func ensureAutomationPermission(askUser: Bool) -> Bool {
        let probe = """
        tell application "System Events" to return name of first process
        """
        guard let scriptObj = NSAppleScript(source: probe) else { return false }
        var err: NSDictionary?
        let result = scriptObj.executeAndReturnError(&err)
        if let err {
            let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            DebugLog.log("Paste: Automation probe error code=\(code)")
            // -1743 = denied. Other errors usually mean the prompt was shown but not yet
            // answered, in which case askUser=true will have surfaced the dialog.
            return false
        }
        _ = result
        return true
    }

    private func isElectronApp(_ bundleID: String) -> Bool {
        let denylist = [
            "com.tinyspeck.slackmacgap",      // Slack
            "com.microsoft.VSCode",            // VS Code
            "com.todesktop.230313mzl4w4u92",   // Cursor
            "com.hnc.Discord",                 // Discord
            "notion.id",                       // Notion
            "com.figma.Desktop",               // Figma
            "com.linear",                      // Linear desktop
            "com.electron.",                   // catches generic Electron builds
            "com.github.Electron",
        ]
        return denylist.contains { bundleID.hasPrefix($0) }
    }
}
