import AppKit
import SwiftUI

/// Быстрая правка прямо в поле: выделил неправильно распознанное слово → одиночное
/// нажатие клавиши (по умолчанию правый ⌘) → окошко «как правильно» → Enter: слово
/// заменяется в поле, а пара уходит в словарь правок.
///
/// Нужна там, где автообучение прочитать поле не может (MAX, Termius, ChatGPT,
/// Bitrix24, браузеры): выделенное берётся через ⌘C, замена — обычной вставкой.
///
/// «Одиночное нажатие» — модификатор нажат и отпущен быстрее 0,4 с, и между этим не
/// было ни клавиш, ни кликов: сочетания вроде ⌘C не срабатывают. Если ничего не
/// выделено, нажатие ничего не делает — случайные нажатия безвредны.
@MainActor
final class QuickFixService {
    static let shared = QuickFixService()
    private init() {}

    private var monitors: [Any] = []
    private var downAt: Date?
    private var interrupted = false
    private var busy = false
    private var panel: NSPanel?

    func start() {
        stop()
        guard AppSettings.shared.quickFixKey != .off else { return }
        let flagsHandler: (NSEvent) -> Void = { [weak self] e in self?.handleFlags(e) }
        let interrupt: (NSEvent) -> Void = { [weak self] _ in self?.interrupted = true }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel], handler: interrupt) { monitors.append(m) }
        DebugLog.log("QuickFix: слежу за одиночным нажатием — \(AppSettings.shared.quickFixKey.displayName)")
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func handleFlags(_ event: NSEvent) {
        let key = AppSettings.shared.quickFixKey
        guard let code = key.keyCode else { return }
        guard Int(event.keyCode) == code else {
            // Другой модификатор, пока наш зажат, — это сочетание, а не одиночное нажатие.
            if downAt != nil { interrupted = true }
            return
        }
        if event.modifierFlags.contains(key.flag) {
            downAt = Date()
            interrupted = false
        } else if let t0 = downAt {
            downAt = nil
            if !interrupted, Date().timeIntervalSince(t0) < 0.4 { trigger() }
        }
    }

    private func trigger() {
        guard !busy, panel == nil else { return }
        // Во время диктовки клавиша не наша.
        if case .recording = AppController.shared.state { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            guard let sel = await TextInserter.shared.selection() else {
                DebugLog.log("QuickFix: нажатие, но ничего не выделено")
                return
            }
            let selected = sel.text
            let wrong = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wrong.isEmpty, wrong.count <= 60, !wrong.contains("\n"),
                  wrong.split(separator: " ").count <= 5 else {
                DebugLog.log("QuickFix: выделено слишком много (\(selected.count) симв.) — не похоже на ослышку")
                return
            }
            DebugLog.log("QuickFix: выделено «\(wrong)» (\(sel.field != nil ? "поле видно" : "через ⌘C")) — окошко правки")
            showPanel(selection: sel, wrong: wrong)
        }
    }

    // MARK: - Окошко

    private func showPanel(selection: TextInserter.Selection, wrong: String) {
        let view = QuickFixView(wrong: wrong,
                                onSubmit: { [weak self] right in self?.apply(selection: selection, wrong: wrong, right: right) },
                                onCancel: { [weak self] in self?.closePanel() })
        let host = NSHostingController(rootView: view)
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.contentView = host.view
        // Рядом с курсором мыши — обычно там, где выделение.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - 210, y: mouse.y - 170)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - 428)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - 158)
        }
        p.setFrameOrigin(origin)
        // Окно без активации приложения: выделение в исходном поле остаётся на месте,
        // и замена после Enter ляжет прямо на него.
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func apply(selection: TextInserter.Selection, wrong: String, right rawRight: String) {
        closePanel()
        let right = rawRight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !right.isEmpty, right != wrong else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            // Выделение могло сброситься, пока окошко держало клавиатуру (Chromium/
            // Electron) — возвращаем его; не вышло — не вставляем рядом, а в буфер.
            let replaced = await TextInserter.shared.restoreSelection(selection)
            if replaced {
                // Пробелы вокруг выделенного слова сохраняем: заменяем только его ядро.
                let lead = String(selection.text.prefix(while: { $0.isWhitespace }))
                let trail = String(selection.text.reversed().prefix(while: { $0.isWhitespace }).reversed())
                _ = await TextInserter.shared.paste(lead + right + trail)
            } else {
                DebugLog.log("QuickFix: выделение не восстановилось — правильное слово в буфер")
                TextInserter.shared.copyOnly(right)
            }
            // В словарь — только если правило не испортит другие фразы: левая часть не
            // обычное русское слово (или замена — название/аббревиатура). Та же проверка,
            // что у ревизии словаря.
            let learned = !DictionaryAudit.isRealRussian(wrong) || DictionaryAudit.looksLikeProperNameFix(wrong: wrong, right: right)
            if learned { CorrectionStore.shared.addManual(wrong: wrong, right: right, contextBefore: nil) }
            DebugLog.log("QuickFix: «\(wrong)» → «\(right)» — заменено: \(replaced), в словаре: \(learned)")
            HUDManager.shared.showQuickFixResult(wrong: wrong, right: right, learned: learned, replaced: replaced)
        }
    }
}

/// Borderless-панель по умолчанию не принимает клавиатуру — окошку правки нужен ввод.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct QuickFixView: View {
    let wrong: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(wrong: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.wrong = wrong
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: wrong)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "character.cursor.ibeam").foregroundStyle(.cyan)
                Text("Как правильно?").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text("«\(wrong)»").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { onSubmit(text) }
                .onExitCommand { onCancel() }
            Text("Enter — заменить в тексте и запомнить  ·  Esc — отмена")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.88)))
        .padding(4)
        .onAppear { focused = true }
    }
}
