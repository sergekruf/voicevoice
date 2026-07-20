import SwiftUI
import AppKit

@main
struct VoiceVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var transcriber = Transcriber.shared
    @ObservedObject private var parakeet = ParakeetTranscriber.shared
    @ObservedObject private var gigaam = GigaAMTranscriber.shared
    @ObservedObject private var settings = AppSettings.shared

    /// State of whichever engine is currently selected.
    private var engineState: Transcriber.ModelState {
        switch settings.sttEngine {
        case .whisperKit: return transcriber.state
        case .parakeet: return parakeet.state
        case .gigaAM: return gigaam.state
        }
    }

    var body: some View {
        switch controller.state {
        case .recording: Image(systemName: "mic.fill").foregroundStyle(.red)
        case .transcribing: Image(systemName: "waveform")
        case .complete: Image(systemName: "mic")
        case .error: Image(systemName: "mic.slash")
        case .idle:
            switch engineState {
            case .downloading, .loading, .notLoaded: Image(systemName: "mic.badge.plus")
            case .error: Image(systemName: "mic.slash")
            case .ready: Image(systemName: "mic")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we're a UIElement (no Dock icon) regardless of bundle Info.plist quirks.
        NSApp.setActivationPolicy(.accessory)

        // Скрытый отладочный режим: `VoiceVoice --sage-test "текст"` — прогоняет текст
        // через SageCorrectorService (полный Swift-путь: токенизатор → bias → greedy →
        // диф-гард) и завершается, минуя bootstrap. Для сверки с Python-эталоном
        // (.mltools/eval_sage.py) без записи с микрофона.
        if let idx = CommandLine.arguments.firstIndex(of: "--sage-test"),
           idx + 1 < CommandLine.arguments.count {
            let text = CommandLine.arguments[idx + 1]
            Task { @MainActor in
                // 3 прогона: №1 показывает холодный старт (компиляция GPU-пайплайнов),
                // №2–3 — устоявшуюся скорость резидентного процесса (как в жизни).
                var out = ""
                for run in 1...3 {
                    let t0 = Date()
                    out = await SageCorrectorService.shared.correct(text)
                    print("SAGE-TEST run \(run): \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                }
                print("SAGE-TEST IN : \(text)")
                print("SAGE-TEST OUT: \(out)")
                exit(0)
            }
            return
        }

        // Touch the database singleton early so migrations run.
        _ = Database.shared

        AppController.shared.bootstrap()

        if AppController.shared.onboardingNeeded {
            WindowOpener.openOnboarding()
        }
    }
}
