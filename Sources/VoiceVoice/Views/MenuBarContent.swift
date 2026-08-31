import SwiftUI

struct MenuBarContent: View {
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var transcriber = Transcriber.shared
    @ObservedObject private var parakeet = ParakeetTranscriber.shared
    @ObservedObject private var gigaam = GigaAMTranscriber.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = AppUpdater.shared

    private var engineState: Transcriber.ModelState {
        switch settings.sttEngine {
        case .whisperKit: return transcriber.state
        case .parakeet: return parakeet.state
        case .gigaAM: return gigaam.state
        }
    }

    var body: some View {
        // НЕ вызывать warmUpIfNeeded() здесь: MenuBarExtra(.menu) материализует body
        // уже на старте приложения (проверено по логу) — это не сигнал «пользователь
        // открыл меню». Модель и так грузится в bootstrap().
        // Status header (disabled item shows current state).
        Text(statusText)

        Divider()

        Button("Открыть последнюю запись…") {
            if let r = controller.lastResult {
                EditAndLearnController.shared.open(record: r)
            }
        }
        .disabled(controller.lastResult == nil)

        Button("Транскрибировать файл…") {
            WindowOpener.openFileTranscribe()
            FileTranscribeController.shared.promptAndStart()
        }

        Divider()

        Button("Дашборд…") { WindowOpener.openDashboard() }
        Button("История…") { WindowOpener.openHistory() }
        Button("Словарь правок…") { WindowOpener.openDictionary() }
        Button("Настройки…") { WindowOpener.openSettings() }

        Divider()

        // Заголовок меняется по ходу обновления (проверка → скачивание N% →
        // установка); свежее состояние видно при каждом открытии меню.
        Button(updater.menuTitle) { updater.checkForUpdates() }
            .disabled(updater.isBusy)

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
