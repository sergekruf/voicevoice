import AppKit
import Carbon.HIToolbox
import ApplicationServices

enum PasteOutcome: Equatable {
    case pending             // paste task just started, no result yet
    case pasted              // text landed in an AX-verifiable editable field; auto-learn watcher will track edits
    case pastedNoAutoLearn   // tier 1 was trusted in an AX-unreadable app; auto-learn watcher CAN'T run → surface HUD with manual Edit & Learn
    case pastedKeptInClipboard // AX-unreadable app, but during dictation the user clicked / switched apps — the caret may have left the field: ⌘V sent AND text left in clipboard
    case clipboardOnly       // no editable field — text dropped into clipboard, hint shown
    case failed              // editable field, but all paste tiers couldn't deliver — text in clipboard
    case skipped             // empty text — nothing to paste
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
    /// clipboard managers to capture the entry — вставить некуда (нет поля) или все
    /// тиры провалились и пользователю нужен ручной ⌘V.
    private func writePlainText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Common post-paste step on any successful tier: rewind to the previous clipboard.
    private func finalizeAfterPaste(savedClipboard: ClipboardSnapshot) async {
        await restoreClipboard(savedClipboard)
    }

    /// Asynchronous paste. Returns the outcome so the caller can update its UI state
    /// (typically `AppController.lastPasteOutcome` → reflected in the unified ResultHUD).
    /// - focusMayHaveMoved: во время диктовки был клик мышью или смена приложения —
    ///   курсор мог уйти из поля. Для приложений, где поле не проверить, текст тогда
    ///   остаётся в буфере (иначе он терялся бы молча).
    func paste(_ text: String, focusMayHaveMoved: Bool = false) async -> PasteOutcome {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontName = frontApp?.localizedName ?? "?"
        let frontBundle = frontApp?.bundleIdentifier ?? "?"
        DebugLog.log("Paste: length=\(text.count), front=\(frontName) [\(frontBundle)], focusMayHaveMoved=\(focusMayHaveMoved)")
        Self.prepareAccessibility(for: frontApp)
        return await runPasteChain(text: text, bundleID: frontBundle, focusMayHaveMoved: focusMayHaveMoved)
    }

    // MARK: - Где курсор: поле ввода есть или нет

    /// Приложения на Electron (Claude, Slack, VS Code…) прячут дерево доступности, пока
    /// их не попросят флагом `AXManualAccessibility` — так делают Grammarly и менеджеры
    /// окон. После флага видно поле ввода и его текст: вставку можно проверить, а
    /// отсутствие поля — отличить от «не видно». Флаг ставится один раз на процесс;
    /// приложения, которые его не знают (Qt, Chromium-браузеры), отвечают ошибкой — ок.
    private static var accessibilityRequestedPIDs = Set<pid_t>()

    static func prepareAccessibility(for app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !accessibilityRequestedPIDs.contains(app.processIdentifier) else { return }
        accessibilityRequestedPIDs.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let r = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        DebugLog.log("Paste: AXManualAccessibility для \(app.bundleIdentifier ?? "?") → \(r == .success ? "включено" : "не поддерживается")")
        // Safari строит дерево страницы лениво, по первому обращению: обходим окно уже
        // сейчас (начало диктовки), чтобы к вставке поле было видно.
        _ = findFocusedTextElement(pid: app.processIdentifier)
    }

    /// Прямой запрос «где фокус» у Electron-приложений пуст даже с деревом доступности,
    /// но само поле помечено `AXFocused`. Ищем его обходом активного окна (окно Claude —
    /// ~450 узлов, ~30 мс) с ограничением по числу узлов и времени.
    /// `windowHasFields` — в окне видны текстовые поля (дерево доступности открыто), но
    /// ни одно не в фокусе: курсор точно не в поле, даже без статистики по приложению.
    /// `webContentHidden` — в окне есть веб-страница, но полей в ней не видно: Safari
    /// (WebKit) строит дерево страницы лениво, после первого обращения, — поля окна вне
    /// страницы (адресная строка) тогда ничего не говорят о курсоре.
    private static func findFocusedTextElement(pid: pid_t) -> (field: AXUIElement?, windowHasFields: Bool, webContentHidden: Bool) {
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return (nil, false, false) }
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String,
                                      kAXComboBoxRole as String, "AXSearchField"]
        let deadline = Date().addingTimeInterval(0.15)
        var visited = 0
        var sawField = false
        var sawWebArea = false
        var sawFieldInWebArea = false
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        func search(_ e: AXUIElement, depth: Int, inWebArea: Bool) -> AXUIElement? {
            visited += 1
            if visited > 3000 || depth > 80 || Date() > deadline { return nil }
            let role = attr(e, kAXRoleAttribute as String) as? String
            if let role, textRoles.contains(role) {
                sawField = true
                if inWebArea { sawFieldInWebArea = true }
                if (attr(e, kAXFocusedAttribute as String) as? Bool) == true { return e }
            }
            let isWebArea = role == "AXWebArea"
            if isWebArea { sawWebArea = true }
            for child in (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] {
                if let found = search(child, depth: depth + 1, inWebArea: inWebArea || isWebArea) { return found }
            }
            return nil
        }
        let found = search(win as! AXUIElement, depth: 0, inWebArea: false)
        let webContentHidden = found == nil && sawWebArea && !sawFieldInWebArea
        DebugLog.log("Paste: обход окна — \(visited) узлов, поле в фокусе: \(found != nil), поля в окне: \(sawField)\(webContentHidden ? ", страница закрыта" : "")")
        return (found, sawField, webContentHidden)
    }

    /// Надёжно ли приложение показывает своё поле ввода. Считаем по истории: если почти
    /// всегда (≥90%, минимум 5 раз) поле было видно, то «фокуса нет» в нём означает, что
    /// курсор действительно не в поле. У Qt/браузеров (MAX, Яндекс) поле видно редко —
    /// там «не видно» ничего не значит, и мы по-прежнему вставляем вслепую.
    private static let focusStatsKey = "axFocusStats"

    /// Приложения на Electron, Chromium (Chrome, Яндекс, ChatGPT, Bitrix24) и Qt (MAX)
    /// прячут поле ввода от служб доступности — «фокуса нет» в них ничего не значит.
    /// Обычные приложения macOS показывают поле всегда. Узнаём по составу пакета.
    private static var hidesFieldsCache: [String: Bool] = [:]

    private static func hidesFields(_ app: NSRunningApplication?) -> Bool {
        guard let app, let url = app.bundleURL else { return true }
        let key = app.bundleIdentifier ?? url.path
        if let cached = hidesFieldsCache[key] { return cached }
        let frameworks = (try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        let hides = frameworks.contains { name in
            name == "QtCore.framework" || name.hasSuffix(" Framework.framework")   // Electron, Chromium, CEF
                || name == "Chromium Embedded Framework.framework"
        }
        hidesFieldsCache[key] = hides
        DebugLog.log("Paste: \(key) — \(hides ? "Electron/Chromium/Qt, поле может быть скрыто" : "обычное приложение macOS")")
        return hides
    }

    private static func recordFocus(bundleID: String, visible: Bool) {
        var stats = UserDefaults.standard.dictionary(forKey: focusStatsKey) as? [String: [Int]] ?? [:]
        var s = stats[bundleID] ?? [0, 0]
        if visible { s[0] += 1 } else { s[1] += 1 }
        stats[bundleID] = s
        UserDefaults.standard.set(stats, forKey: focusStatsKey)
    }

    private static func showsFieldsReliably(bundleID: String) -> Bool {
        let stats = UserDefaults.standard.dictionary(forKey: focusStatsKey) as? [String: [Int]] ?? [:]
        guard let s = stats[bundleID] else { return false }
        return s[0] >= 5 && Double(s[0]) >= 0.9 * Double(s[0] + s[1])
    }

    func copyOnly(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Выделенный текст (быстрая правка)

    /// Выделение в активном поле: текст и, если поле видно службам доступности, само
    /// поле с позицией выделения — чтобы вернуть его перед заменой. Chromium/Electron
    /// (Claude) сбрасывают выделение, пока окошко быстрой правки держит клавиатуру.
    struct Selection {
        let text: String
        let field: AXUIElement?
        let range: CFRange?
    }

    /// Выделенный текст в активном поле. Сначала через службы доступности (без побочных
    /// эффектов); если приложение их не даёт (MAX, Termius, браузеры) — через ⌘C с
    /// возвратом прежнего буфера. nil — ничего не выделено.
    func selection() async -> Selection? {
        let front = NSWorkspace.shared.frontmostApplication
        Self.prepareAccessibility(for: front)
        var element = Self.copyFocusedElement()
        if element == nil || Self.readValue(from: element!) == nil, let pid = front?.processIdentifier {
            element = Self.findFocusedTextElement(pid: pid).field ?? element
        }
        // Для проверки пути «поле не видно» (MAX, браузеры) на любом приложении.
        if ProcessInfo.processInfo.environment["VOICEVOICE_QUICKFIX_CMDC"] != nil { element = nil }
        if let element {
            var sel: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &sel) == .success,
               let s = sel as? String, !s.isEmpty {
                return Selection(text: s, field: element, range: Self.selectedRange(of: element))
            }
        }
        return await copiedSelection().map { Selection(text: $0, field: nil, range: nil) }
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Вернуть выделение перед заменой и убедиться, что выделено именно `expected`.
    /// - Поле видно: ставим сохранённую позицию обратно через службы доступности.
    /// - Не видно: проверяем ⌘C; если выделение сброшено (курсор остался в конце
    ///   слова — так ведёт себя Chromium), выделяем заново shift+← по числу символов.
    func restoreSelection(_ sel: Selection) async -> Bool {
        if let field = sel.field, let saved = sel.range {
            var range = saved
            if let axRange = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, axRange)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
            var now: CFTypeRef?
            if AXUIElementCopyAttributeValue(field, kAXSelectedTextAttribute as CFString, &now) == .success,
               (now as? String) == sel.text {
                return true
            }
            DebugLog.log("QuickFix: выделение через службы доступности не вернулось — пробую клавиатурой")
        }
        if await copiedSelection() == sel.text { return true }
        let n = sel.text.count
        guard n <= 60 else { return false }
        postKey(CGKeyCode(kVK_LeftArrow), flags: .maskShift, times: n)
        try? await Task.sleep(nanoseconds: 80_000_000)
        return await copiedSelection() == sel.text
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags, times: Int) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        for _ in 0..<times {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    /// Выделенный текст через ⌘C с возвратом прежнего буфера; nil — выделения нет
    /// (буфер не изменился).
    private func copiedSelection() async -> String? {
        let snapshot = ClipboardSnapshot.capture()
        let before = NSPasteboard.general.changeCount
        guard synthesizeCmdCViaCGEvent() else { return nil }
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if NSPasteboard.general.changeCount != before { break }
        }
        guard NSPasteboard.general.changeCount != before else { return nil }
        let copied = NSPasteboard.general.string(forType: .string)
        snapshot.restore()
        return (copied?.isEmpty ?? true) ? nil : copied
    }

    private func synthesizeCmdCViaCGEvent() -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let cmdKey = CGKeyCode(kVK_Command), cKey = CGKeyCode(kVK_ANSI_C)
        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: true),
              let cDown = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true),
              let cUp = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: false)
        else { return false }
        cDown.flags = .maskCommand
        cUp.flags = .maskCommand
        let loc: CGEventTapLocation = .cghidEventTap
        cmdDown.post(tap: loc); usleep(15_000)
        cDown.post(tap: loc); usleep(15_000)
        cUp.post(tap: loc); usleep(15_000)
        cmdUp.post(tap: loc)
        return true
    }

    /// Поле, куда вставка подтверждена последней (`.pasted`) — отдаётся слежению за
    /// правками (TextChangeWatcher), которое само его найти не может у Electron.
    private(set) var lastVerifiedField: AXUIElement?

    private func runPasteChain(text: String, bundleID: String, focusMayHaveMoved: Bool) async -> PasteOutcome {
        lastVerifiedField = nil
        var focusedElement = Self.copyFocusedElement()
        let noFocusAtAll = focusedElement == nil
        var editability = Self.classifyFocus(focusedElement)
        let hidesFields = Self.hidesFields(NSWorkspace.shared.frontmostApplication)
        var windowHasFields = false
        var webContentHidden = false
        if editability == .axUnreadable, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            var found = Self.findFocusedTextElement(pid: pid)
            if found.webContentHidden, !hidesFields {
                // Первое обращение запустило построение дерева страницы — даём ему время.
                // (Chromium-браузеры страницу часто не открывают вовсе — там не ждём.)
                try? await Task.sleep(nanoseconds: 150_000_000)
                found = Self.findFocusedTextElement(pid: pid)
            }
            windowHasFields = found.windowHasFields
            webContentHidden = found.webContentHidden
            if let field = found.field {
                focusedElement = field
                editability = .editable
            }
        }
        if editability != .notEditable {
            Self.recordFocus(bundleID: bundleID, visible: editability == .editable)
        }
        // Поля точно нет: обычное приложение без фокуса вовсе; окно Electron, где поля
        // видны, но ни одно не в фокусе; приложение, которое обычно показывает поле.
        // Кроме окна, где страница ещё закрыта от служб доступности (Safari): там
        // «не видно» ничего не значит.
        if editability == .axUnreadable, !webContentHidden,
           (!hidesFields && noFocusAtAll) || windowHasFields || Self.showsFieldsReliably(bundleID: bundleID) {
            DebugLog.log("Paste: поля ввода нет (\(bundleID)) → только буфер")
            editability = .notEditable
        }
        // Обычное приложение, но фокус на чём-то непонятном (окно, веб-область, группа):
        // ⌘V пробуем, но текст оставляем и в буфере.
        let uncertain = editability == .axUnreadable && (!hidesFields || focusMayHaveMoved || webContentHidden)
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
                await finalizeAfterPaste(savedClipboard: savedClipboard)
                lastVerifiedField = focusedElement
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
            // Clipboard: восстанавливаем прежнее содержимое сразу, как и для
            // проверяемых полей — иначе привычный ⌘V после диктовки вставлял
            // текст ВТОРОЙ раз (жалоба пользователя). Если вставка вдруг не
            // долетела (редкий случай в этом классе приложений) — в HUD есть
            // кнопка «Копировать».
            if uncertain {
                // Курсор мог уйти из поля (клик или смена приложения во время диктовки)
                // или фокус в обычном приложении на непонятном элементе — проверить
                // нечем. Текст оставляем в буфере обычной записью.
                DebugLog.log("Paste: AX unverifiable + uncertain focus (moved=\(focusMayHaveMoved)) — ⌘V sent, text KEPT in clipboard")
                writePlainText(text)
                return .pastedKeptInClipboard
            }
            DebugLog.log("Paste: AX unverifiable — trusting tier1; restoring clipboard (HUD with Edit & Learn)")
            await finalizeAfterPaste(savedClipboard: savedClipboard)
            return .pastedNoAutoLearn
        }

        // Tier 2: AppleScript via NSAppleScript.
        let aplOk = await runAppleScriptKeystrokeV()
        DebugLog.log("Paste tier2 (NSAppleScript): ok=\(aplOk)")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Self.pasteLanded(element: focusedElement, pastedText: text, preValue: preValue) {
            DebugLog.log("Paste: tier2 verified via AX — restoring clipboard")
            await finalizeAfterPaste(savedClipboard: savedClipboard)
            lastVerifiedField = focusedElement
            return .pasted
        }

        // Tier 2b: osascript subprocess.
        let osa2Ok = await runOsascriptSubprocess()
        DebugLog.log("Paste tier2b (osascript): ok=\(osa2Ok)")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Self.pasteLanded(element: focusedElement, pastedText: text, preValue: preValue) {
            DebugLog.log("Paste: tier2b verified via AX — restoring clipboard")
            await finalizeAfterPaste(savedClipboard: savedClipboard)
            lastVerifiedField = focusedElement
            return .pasted
        }

        // Tier 3: AXUIElement direct text insertion. Native Cocoa text views only.
        if !isElectronApp(bundleID) {
            let axOk = await insertViaAXUI(text: text)
            DebugLog.log("Paste tier3 (AXUIElement): ok=\(axOk)")
            if axOk {
                await finalizeAfterPaste(savedClipboard: savedClipboard)
                lastVerifiedField = focusedElement
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
        // skip Electron explicitly, native Cocoa text views can be slow with huge
        // strings. Insert in chunks (each set replaces the collapsed selection, so
        // consecutive writes append) — a single prefix(2000) silently dropped the tail.
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(2000))
            let setErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, chunk as CFString)
            if setErr != .success {
                DebugLog.log("Paste tier3: AXUIElementSetAttributeValue err=\(setErr.rawValue) after \(text.count - remaining.count)/\(text.count) chars")
                return false
            }
            remaining = remaining.dropFirst(chunk.count)
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
