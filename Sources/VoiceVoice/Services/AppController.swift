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
    private var parakeetObserver: AnyCancellable?

    // Transient Esc-to-cancel monitors, installed only while recording.
    private var escMonitorGlobal: Any?
    private var escMonitorLocal: Any?
    private static let escKeyCode = 53

    private init() {
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if case .recording = self.state {
                self.state = .recording(level: level)
            }
        }
        hotkeys.onPress = { [weak self] in self?.handlePress() }
        hotkeys.onRelease = { [weak self] in self?.handleRelease() }

        // Show / hide the loading indicator automatically as the ACTIVE engine's state
        // changes. Each observer ignores changes when its engine isn't the active one,
        // otherwise the idle engine (always .notLoaded) would falsely show "loading".
        let apply: (Transcriber.ModelState) -> Void = { state in
            switch state {
            case .ready:
                HUDManager.shared.hideLoadingIndicator()
            case .notLoaded, .loading, .downloading, .error:
                HUDManager.shared.showLoadingIndicator()
            }
        }
        transcriberObserver = transcriber.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard self?.settings.sttEngine == .whisperKit else { return }
                apply(state)
            }
        parakeetObserver = ParakeetTranscriber.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard self?.settings.sttEngine == .parakeet else { return }
                apply(state)
            }
    }

    // MARK: - Public bootstrap

    func bootstrap() {
        let tapOk = hotkeys.canCreateEventTap()
        let micStatus = AVAuthStatus.audio
        DebugLog.log("App: bootstrap tapOk=\(tapOk) mic=\(micStatus.rawValue) onboardingDone=\(settings.onboardingDone) eagerLoad=\(settings.eagerLoad)")

        migrateLifetimeStatsIfNeeded()

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
            ensureActiveEngineLoaded()
        }
    }

    /// One-time backfill: lifetime counters were added after the app already had a
    /// history table capped at 200 rows. To give the Dashboard meaningful baseline
    /// numbers on first launch after upgrade, seed lifetime counters from whatever
    /// is currently in the DB (up to 200 records). Subsequent dictations correctly
    /// increment from this baseline.
    private func migrateLifetimeStatsIfNeeded() {
        guard !settings.lifetimeStatsMigrated else { return }
        let s = history.stats()
        if s.totalRecords > 0 {
            settings.lifetimeRecordsCount    = s.totalRecords
            settings.lifetimeCharactersCount = s.totalCharacters
            settings.lifetimeAudioSeconds    = s.totalSeconds
            settings.lifetimeProcessingMs    = s.totalProcessingMs
            if let first = s.firstAt {
                settings.firstRecordAt = first.timeIntervalSince1970
            }
            DebugLog.log("App: lifetime stats backfilled from DB — records=\(s.totalRecords), chars=\(s.totalCharacters)")
        }
        settings.lifetimeStatsMigrated = true
    }

    func dismissOnboarding() {
        DebugLog.log("App: dismissOnboarding called, will start hotkey monitor")
        settings.onboardingDone = true
        onboardingNeeded = false
        hotkeys.start(with: settings.hotkey)
        if settings.eagerLoad {
            ensureActiveEngineLoaded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            HUDManager.shared.showReady()
        }
    }

    /// Triggered by any UI affordance the user touches (menu icon, settings, recording start).
    /// Acts as a no-op if the model is already loaded or loading.
    func warmUpIfNeeded() {
        ensureActiveEngineLoaded()
    }

    /// Load whichever engine is currently selected (WhisperKit or Parakeet).
    private func ensureActiveEngineLoaded() {
        switch settings.sttEngine {
        case .whisperKit: transcriber.ensureLoaded()
        case .parakeet: ParakeetTranscriber.shared.ensureLoaded()
        }
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
        ensureActiveEngineLoaded()
        do {
            try recorder.start()
            state = .recording(level: 0)
            HUDManager.shared.showRecording()
            installEscMonitor()
            // Eager streaming: decode completed VAD chunks in the background while the
            // user keeps speaking, so on release only the trailing tail remains.
            // WhisperKit-only — Parakeet is fast enough and has no 223-token cap, so
            // it just transcribes the whole buffer on release.
            if settings.eagerTranscription && settings.sttEngine == .whisperKit {
                transcriber.startStreaming(samples: { [weak self] in
                    self?.recorder.currentSamples() ?? []
                })
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Cancel (Esc)

    /// Install a transient Esc watcher for the duration of recording. Passive monitors
    /// (can't consume the event), so Esc also reaches the frontmost app — acceptable,
    /// since during dictation the user isn't typing into it. Both global (other apps
    /// focused) and local (our own window focused) are needed to catch Esc anywhere.
    private func installEscMonitor() {
        removeEscMonitor()
        escMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == AppController.escKeyCode {
                Task { @MainActor in self?.cancelDictation() }
            }
        }
        escMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == AppController.escKeyCode {
                self?.cancelDictation()
                return nil   // consume so our own UI doesn't also react
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let m = escMonitorGlobal { NSEvent.removeMonitor(m) }
        if let m = escMonitorLocal { NSEvent.removeMonitor(m) }
        escMonitorGlobal = nil
        escMonitorLocal = nil
    }

    /// Abort the current dictation without transcribing or pasting. Triggered by Esc
    /// while recording — protects the focused field from accidental/garbled input.
    func cancelDictation() {
        guard case .recording = state else { return }
        DebugLog.log("App: dictation cancelled via Esc")
        removeEscMonitor()
        recorder.cancel()
        transcriber.cancelStreaming()
        state = .idle
        HUDManager.shared.hideRecording()
    }

    private func handleRelease() {
        guard case .recording = state else {
            DebugLog.log("App: handleRelease bailing, state was \(state)")
            return
        }
        removeEscMonitor()
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
            // Route to the active engine. WhisperKit: finishStreaming finishes an
            // in-flight eager session (decodes only the trailing tail + joins committed
            // chunks), or falls back to a full transcription if streaming never started.
            // Parakeet: one shot on the whole buffer (no eager, no 223-token cap).
            let rawText: String
            switch self.settings.sttEngine {
            case .parakeet:
                rawText = await ParakeetTranscriber.shared.transcribe(audio: samples)
            case .whisperKit:
                rawText = await self.transcriber.finishStreaming(finalSamples: samples)
            }
            await MainActor.run {
                let procMs = self.settings.sttEngine == .parakeet
                    ? ParakeetTranscriber.shared.lastProcessingMs
                    : self.transcriber.lastProcessingMs
                DebugLog.log("App: transcribe finished, rawLen=\(rawText.count) text=\(rawText.prefix(80))")
                self.finalize(rawText: rawText, duration: duration, processingMs: procMs)
            }
        }
    }

    private func finalize(rawText: String, duration: Double, processingMs: Int) {
        let applyResult = applier.apply(to: rawText)
        let dictText = applyResult.text
        var appliedText = settings.normalizeNumbers ? NumberNormalizer.normalize(dictText) : dictText
        if settings.fixPunctuation {
            appliedText = PunctuationFixer.fix(appliedText)
        }
        if settings.autoFormat {
            appliedText = TextFormatter.format(appliedText)
        }
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
            processingMs: processingMs,
            createdAt: Date()
        )
        if let id = history.add(record) {
            record.id = id
        }
        lastResult = record

        // Lifetime counters — the history table is trimmed to 200 rows, so we
        // can't compute these from the DB after the fact. Increment on every
        // transcription so the Dashboard shows true lifetime numbers.
        settings.lifetimeRecordsCount    += 1
        settings.lifetimeCharactersCount += appliedText.count
        settings.lifetimeAudioSeconds    += duration
        settings.lifetimeProcessingMs    += processingMs
        if settings.firstRecordAt == 0 {
            settings.firstRecordAt = record.createdAt.timeIntervalSince1970
        }

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
