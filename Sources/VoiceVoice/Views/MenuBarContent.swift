import SwiftUI

struct MenuBarContent: View {
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var transcriber = Transcriber.shared
    @ObservedObject private var parakeet = ParakeetTranscriber.shared
    @ObservedObject private var settings = AppSettings.shared

    private var engineState: Transcriber.ModelState {
        settings.sttEngine == .parakeet ? parakeet.state : transcriber.state
    }

    var body: some View {
        // Opening the menu is a strong signal the user will record soon → warm the model.
        let _ = controller.warmUpIfNeeded()
        // Status header (disabled item shows current state).
        Text(statusText)

        Divider()

        Button("Открыть последнюю запись…") {
            if let r = controller.lastResult {
                EditAndLearnController.shared.open(record: r)
            }
        }
        .disabled(controller.lastResult == nil)

        Button("Дашборд…") { WindowOpener.openDashboard() }
        Button("История…") { WindowOpener.openHistory() }
        Button("Словарь правок…") { WindowOpener.openDictionary() }
        Button("Настройки…") { WindowOpener.openSettings() }

        Divider()

        Button("Выход") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch (controller.state, engineState) {
        case (.recording, _): return "● Идёт запись"
        case (.transcribing, _): return "○ Распознавание…"
        case (_, .downloading(let p)): return "Загрузка модели \(Int(p * 100))%"
        case (_, .loading): return "Загрузка модели…"
        case (_, .error(let m)): return "Ошибка: \(m)"
        case (.error(let m), _): return "Ошибка: \(m)"
        default: return "VoiceVoice готов"
        }
    }
}
