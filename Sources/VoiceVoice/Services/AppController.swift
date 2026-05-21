import Foundation
import AppKit
import Combine

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    enum State: Equatable {
        case idle
        case recording(level: Float)
        case transcribing
        case complete
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastResult: TranscriptionRecord?
    @Published private(set) var lastSubstitutions: [AppliedSubstitution] = []
    @Published private(set) var lastPasteOutcome: PasteOutcome = .pending
    @Published var onboardingNeeded: Bool = false

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber.shared
    private let applier = CorrectionApplier.shared
    private let inserter = TextInserter.shared
    private let history = HistoryStore.shared
    private let corrections = CorrectionStore.shared
    private let settings = AppSettings.shared
    private let hotkeys = HotkeyMonitor.shared

    private var transcriberObserver: AnyCancellable?

    private init() {
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if case .recording = self.state {
                self.state = .recording(level: level)
            }
        }
        hotkeys.onPress = { [weak self] in self?.handlePress() }
        hotkeys.onRelease = { [weak self] in self?.handleRelease() }

        // Show / hide the loading indicator automatically as the transcriber's state changes.
        transcriberObserver = transcriber.$state
            .receive(on: DispatchQueue.main)
            .sink { state in
                switch state {
                case .ready:
                    HUDManager.shared.hideLoadingIndicator()
                case .notLoaded, .loading, .downloading, .error:
                    HUDManager.shared.showLoadingIndicator()
                }
            }
    }

    // MARK: - Public bootstrap

    func bootstrap() {
        let tapOk = hotkeys.canCreateEventTap()
        let micStatus = AVAuthStatus.audio
        DebugLog.log("App: bootstrap tapOk=\(tapOk) mic=\(micStatus.rawValue) onboardingDone=\(settings.onboardingDone) eagerLoad=\(settings.eagerLoad)")

        if !settings.onboardingDone || !tapOk || micStatus != .authorized {
            onboardingNeeded = true
        }

        if tapOk {
            hotkeys.start(with: settings.hotkey)
        }

        // Lazy by default: model load is deferred until first user interaction
        // (Fn press, menu open, window open). Opt in to eager load via Settings if
        // you want first Fn press to be instant at the cost of slower startup.
        if settings.eagerLoad {
            transcriber.ensureLoaded()
        }
    }

    func dismissOnboarding() {
        DebugLog.log("App: dismissOnboarding called, will start hotkey monitor")
        settings.onboardingDone = true
        onboardingNeeded = false
        hotkeys.start(with: settings.hotkey)
        if settings.eagerLoad {
            transcriber.ensureLoaded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            HUDManager.shared.showReady()
        }
    }

    /// Triggered by any UI affordance the user touches (menu icon, settings, recording start).
    /// Acts as a no-op if the model is already loaded or loading.
    func warmUpIfNeeded() {
        transcriber.ensureLoaded()
    }

    func reconfigureHotkey(_ kind: HotkeyKind) {
        settings.hotkeyRaw = kind.rawValue
        hotkeys.reconfigure(hotkey: kind)
    }

    // MARK: - Recording flow

    private func handlePress() {
        DebugLog.log("App: handlePress entered, state=\(state)")
        guard case .idle = state else { return }
        guard AVAuthStatus.audio == .authorized else {
            recorder.requestPermissionIfNeeded { _ in }
            return
        }
        // Lazy load: ensure the model starts loading in the background while we record.
        // If the user holds Fn for several seconds, the model is usually ready by release.
        transcriber.ensureLoaded()
        do {
            try recorder.start()
            state = .recording(level: 0)
            HUDManager.shared.showRecording()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func handleRelease() {
        guard case .recording = state else {
            DebugLog.log("App: handleRelease bailing, state was \(state)")
            return
        }
        let samples = recorder.stop()
        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        // RMS / peak of the captured buffer — confirms the mic actually picked up sound.
        var peak: Float = 0
        var sumSq: Double = 0
        var nonZero = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSq += Double(s) * Double(s)
            if a > 0.0005 { nonZero += 1 }
        }
        let rms = samples.isEmpty ? 0 : sqrt(sumSq / Double(samples.count))
        DebugLog.log("App: handleRelease, samples=\(samples.count) duration=\(String(format: "%.2f", duration))s peak=\(String(format: "%.4f", peak)) rms=\(String(format: "%.4f", rms)) nonZeroPct=\(samples.isEmpty ? 0 : nonZero * 100 / samples.count)")
        state = .transcribing
        HUDManager.shared.showTranscribing()

        Task { [weak self] in
            guard let self else { return }
            let rawText = await self.transcriber.transcribe(audio: samples)
            await MainActor.run {
                DebugLog.log("App: transcribe finished, rawLen=\(rawText.count) text=\(rawText.prefix(80))")
                self.finalize(rawText: rawText, duration: duration)
            }
        }
    }

    private func finalize(rawText: String, duration: Double) {
        let applyResult = applier.apply(to: rawText)
        let dictText = applyResult.text
        var appliedText = settings.normalizeNumbers ? NumberNormalizer.normalize(dictText) : dictText
        if settings.autoEmoji {
            appliedText = EmojiEnhancer.enhance(appliedText)
        }
        lastSubstitutions = applyResult.substitutions

        // Bump persistent counters for the Dashboard.
        if !applyResult.substitutions.isEmpty {
            let fuzzy = applyResult.substitutions.filter { $0.fuzzy }.count
            settings.totalSubstitutions += applyResult.substitutions.count
            settings.fuzzySubstitutions += fuzzy
        }

        var record = TranscriptionRecord(
            rawText: rawText,
            appliedText: appliedText,
            finalText: appliedText,
            durationSeconds: duration,
            processingMs: transcriber.lastProcessingMs,
            createdAt: Date()
        )
        if let id = history.add(record) {
            record.id = id
        }
        lastResult = record
        DebugLog.log("App: finalize appliedLen=\(appliedText.count) autoPaste=\(settings.autoPaste)")

        // Transition to .complete and always hide the recording mic.
        lastPasteOutcome = .pending
        state = .complete
        HUDManager.shared.hideRecording()

        if !appliedText.isEmpty {
            if settings.autoPaste {
                let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                Task { [weak self] in
                    guard let self else { return }
                    let outcome = await self.inserter.paste(appliedText)
                    await MainActor.run {
                        self.lastPasteOutcome = outcome
                        // Verified paste (`.pasted`) needs no HUD — the user sees the text in the field
                        // and the auto-learn watcher will pick up edits automatically. All other outcomes
                        // surface the HUD so the user gets feedback and access to Edit & Learn:
                        //   • clipboardOnly / failed → text in clipboard, manual ⌘V needed
                        //   • pastedNoAutoLearn → paste worked but watcher can't track edits in this app
                        //     (Max / Bitrix24 / Termius / Slack…); Edit & Learn is the only way to teach
                        //     corrections to the dictionary.
                        if outcome != .pasted {
                            HUDManager.shared.showResult(record: record)
                        }
                        if outcome == .pasted {
                            TextChangeWatcher.shared.startWatching(pastedText: appliedText, frontBundleID: frontBundle)
                        }
                    }
                }
            } else {
                inserter.copyOnly(appliedText)
                lastPasteOutcome = .clipboardOnly
                HUDManager.shared.showResult(record: record)
            }
        } else {
            DebugLog.log("App: appliedText is EMPTY — nothing to paste")
            lastPasteOutcome = .skipped
        }

        // Auto-return to idle after a beat so the next press works.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if case .complete = self?.state { self?.state = .idle }
        }
    }

    // MARK: - Edit & Learn

    /// Persist user edits: update history and update correction dictionary scores.
    func commitEdit(recordId: Int64, raw: String, applied: String, final: String,
                    autoApplied: [AppliedSubstitution]) {
        history.updateFinal(id: recordId, finalText: final)

        let appliedRollup: [(wrong: String, right: String, context: String?)] =
            autoApplied.map { ($0.wrong, $0.right, $0.context) }

        let signals = CorrectionLearner.extract(
            raw: raw,
            applied: applied,
            final: final,
            autoApplied: appliedRollup
        )

        // If the user accepted an auto-substitution (kept it in final), reinforce it.
        let appliedRights = Set(autoApplied.map { $0.right.lowercased() })
        let finalLowered = final.lowercased()
        for sub in autoApplied where appliedRights.contains(sub.right.lowercased())
                                && finalLowered.contains(sub.right.lowercased()) {
            corrections.recordConfirmation(wrong: sub.wrong, right: sub.right, contextBefore: sub.context)
        }

        for c in signals.confirmations {
            corrections.recordConfirmation(wrong: c.wrong, right: c.right, contextBefore: c.context)
        }
        for r in signals.rejections {
            corrections.recordRejection(wrong: r.wrong, right: r.right, contextBefore: r.context)
        }
    }
}

import AVFoundation

enum AVAuthStatus {
    static var audio: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}
