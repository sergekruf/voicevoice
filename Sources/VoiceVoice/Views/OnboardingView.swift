import SwiftUI
import AVFoundation

struct OnboardingView: View {
    let onClose: () -> Void
    @ObservedObject private var controller = AppController.shared
    @State private var micGranted: Bool = false
    @State private var axApi: Bool = false
    @State private var axTap: Bool = false
    @State private var automationGranted: Bool = false

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    var accessGranted: Bool { axTap }
    var staleHint: Bool { axApi && !axTap }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добро пожаловать в VoiceVoice")
                .font(.title2.bold())
            Text("Локальная диктовка для macOS. Голос → текст с пунктуацией, без облака, с обучаемым словарём правок.")
                .foregroundStyle(.secondary)

            Step(
                number: 1,
                title: "Микрофон",
                description: "Нужен для записи голоса.",
                done: micGranted
            ) {
                Button(micGranted ? "Разрешено" : "Запросить доступ") { requestMic() }
                    .disabled(micGranted)
            }

            Step(
                number: 2,
                title: "Accessibility",
                description: "Нужен и для глобального слежения за Fn, и для авто-вставки текста в активное приложение.",
                done: accessGranted
            ) {
                Button(accessGranted ? "Разрешено" : "Запросить доступ") { requestAccess() }
                    .disabled(accessGranted)
                Button("Открыть System Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(url)
                }
            }

            if staleHint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠︎ В System Settings галочка VoiceVoice стоит, но событие не приходит.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Это случается после пересборки приложения. Открой Privacy & Security → Accessibility, выключи и снова включи переключатель VoiceVoice, затем нажми «Проверить заново».")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                .padding(.leading, 38)
            }

            Step(
                number: 3,
                title: "Automation → System Events",
                description: "Нужно для надёжной авто-вставки текста через ⌘V в любое приложение (запасной путь, когда CGEvent блокируется TCC).",
                done: automationGranted
            ) {
                Button(automationGranted ? "Разрешено" : "Запросить доступ") { requestAutomation() }
                    .disabled(automationGranted)
                Button("Открыть System Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                    NSWorkspace.shared.open(url)
                }
            }

            Step(
                number: 4,
                title: "Скачивание модели",
                description: "При первом запуске WhisperKit скачает large-v3-turbo (~626 МБ) в ~/Documents/huggingface/models/.",
                done: false
            ) {
                EmptyView()
            }

            HStack {
                Button("Проверить заново") { refresh(force: true) }
                Spacer()
                Button("Готово") {
                    controller.dismissOnboarding()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!micGranted)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 540)
        .onAppear { refresh(force: true) }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh(force: Bool = false) {
        let newMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let newApi = HotkeyMonitor.shared.ensureAccessibility(prompt: false)
        let newTap = HotkeyMonitor.shared.canCreateEventTap()
        let newAutomation = TextInserter.ensureAutomationPermission(askUser: false)

        if newMic != micGranted { micGranted = newMic }
        if newApi != axApi { axApi = newApi }
        if newTap != axTap { axTap = newTap }
        if newAutomation != automationGranted { automationGranted = newAutomation }

        if force && newTap {
            HotkeyMonitor.shared.start(with: AppSettings.shared.hotkey)
        }
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { refresh(force: true) }
        }
    }

    private func requestAccess() {
        _ = HotkeyMonitor.shared.ensureAccessibility(prompt: true)
        refresh()
    }

    private func requestAutomation() {
        _ = TextInserter.ensureAutomationPermission(askUser: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let description: String
    let done: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").foregroundStyle(.white).font(.system(size: 12, weight: .bold))
                } else {
                    Text("\(number)").foregroundStyle(.primary).font(.system(size: 12, weight: .bold))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description).foregroundStyle(.secondary).font(.system(size: 12))
                HStack { content() }.padding(.top, 4)
            }
            Spacer()
        }
    }
}
