import AppKit
import SwiftUI

@MainActor
final class EditAndLearnController {
    static let shared = EditAndLearnController()
    private var window: NSWindow?
    private init() {}

    func open(record: TranscriptionRecord) {
        let host = NSHostingController(rootView: EditAndLearnView(record: record) { [weak self] in
            self?.window?.close()
        })
        if let w = window {
            w.contentViewController = host
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Правка распознавания"
        w.center()
        w.contentViewController = host
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct EditAndLearnView: View {
    let record: TranscriptionRecord
    let onClose: () -> Void
    @State private var editedText: String

    init(record: TranscriptionRecord, onClose: @escaping () -> Void) {
        self.record = record
        self.onClose = onClose
        self._editedText = State(initialValue: record.finalText.isEmpty ? record.appliedText : record.finalText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "pencil.and.scribble").foregroundStyle(.tint)
                Text("Поправь ошибки — словарь запомнит правки")
                    .font(.headline)
                Spacer()
                Text("\(Int(record.durationSeconds * 100) / 100)с · \(record.processingMs) мс")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            GroupBox("Исходное распознавание (Whisper)") {
                ScrollView { Text(record.rawText).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 80)
            }

            if record.rawText != record.appliedText {
                GroupBox("После применения словаря") {
                    ScrollView { Text(record.appliedText).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 60)
                }
            }

            Text("Финальный текст")
                .font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: $editedText)
                .font(.system(size: 14))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Spacer()
                Button("Отмена") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить и обучить") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)
    }

    private func save() {
        guard let id = record.id else { onClose(); return }
        AppController.shared.commitEdit(
            recordId: id,
            raw: record.rawText,
            applied: record.appliedText,
            final: editedText,
            autoApplied: AppController.shared.lastSubstitutions
        )
        onClose()
    }
}
