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
    @ObservedObject private var settings = AppSettings.shared

    /// State of whichever engine is currently selected.
    private var engineState: Transcriber.ModelState {
        settings.sttEngine == .parakeet ? parakeet.state : transcriber.state
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

        // Touch the database singleton early so migrations run.
        _ = Database.shared

        AppController.shared.bootstrap()

        if AppController.shared.onboardingNeeded {
            WindowOpener.openOnboarding()
        }
    }
}
