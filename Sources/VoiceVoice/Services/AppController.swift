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
    private let applier = CorrectionApplier.shared
    private let inserter = TextInserter.shared
    private let history = HistoryStore.shared
    private let corrections = CorrectionStore.shared
    private let settings = AppSettings.shared
    private let hotkeys = HotkeyMonitor.shared

    private var parakeetObserver: AnyCancellable?
    private var gigaAMObserver: AnyCancellable?

    // Transient Esc-to-cancel monitors, installed from recording start until the
    // transcription finishes (Esc aborts either phase).
    private var escMonitorGlobal: Any?
    private var escMonitorLocal: Any?
    private static let escKeyCode = 53

    /// In-flight decode of the released dictation — cancellable by Esc while the
    /// model is still transcribing (or even still downloading/loading).
    private var transcribeTask: Task<Void, Never>?
    /// Аудио текущей диктовки для архива проверки качества (только при включённом
    /// «Сохранять аудио диктовок»); пишется после появления id записи в истории.
    private var pendingArchiveAudio: [Float]?
    /// Мог ли курсор уйти из поля за время диктовки: клик мышью или смена приложения.
    /// Нужно для приложений, где поле ввода не проверить (см. TextInserter.paste).
    private var pressFrontPID: pid_t?
    private var clickedDuringRecording = false
    private var clickMonitor: Any?

    // ── Свободная запись: двойное нажатие клавиши — запись без удержания ─────────
    // Первое короткое нажатие уже пишет звук; если за `doubleTapWindow` пришло второе —
    // запись продолжается без удержания, пока клавиша не будет нажата ещё раз. Одиночное
    // короткое нажатие (случайное) тихо отменяется. Удержание работает как раньше.
    private enum TapPhase { case none, awaitingSecondTap, handsFree }
    private var tapPhase: TapPhase = .none
    private var forceClipboardOnly = false
    private var pressStartedAt: Date?
    private var ignoreNextRelease = false
    private var secondTapWork: DispatchWorkItem?
    private var handsFreeLimitWork: DispatchWorkItem?
    private var lastEscAt: Date?
    /// Когда началась свободная запись (nil — обычный режим). Для индикатора.
    @Published private(set) var handsFreeStartedAt: Date?
    private static let tapMaxHold: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.4
    /// Защита от забытой записи: дальше — стоп, текст в буфер.
    static let handsFreeLimit: TimeInterval = 30 * 60
    private var warmIdleTimer: Timer?

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
        parakeetObserver = ParakeetTranscriber.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard self?.settings.sttEngine == .parakeet else { return }
                apply(state)
            }
        gigaAMObserver = GigaAMTranscriber.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard self?.settings.sttEngine == .gigaAM else { return }
                apply(state)
            }
    }

    // MARK: - Public bootstrap

    func bootstrap() {
        let tapOk = hotkeys.canCreateEventTap()
        let micStatus = AVAuthStatus.audio
        DebugLog.log("App: bootstrap tapOk=\(tapOk) mic=\(micStatus.rawValue) onboardingDone=\(settings.onboardingDone)")

        migrateLifetimeStatsIfNeeded()

        if !settings.onboardingDone || !tapOk || micStatus != .authorized {
            onboardingNeeded = true
        }

        if tapOk {
            hotkeys.start(with: settings.hotkey)
        }

        // Модель грузится сразу при запуске (в фоне, UI не блокирует): первая
        // диктовка не должна ждать. Тоггл «Грузить при запуске» убран как лишний.
        ensureActiveEngineLoaded()
        // Тёплый аудио-движок для мгновенного старта записи (no-op без разрешения
        // на микрофон или при выключенной настройке) + вахта простоя, отпускающая
        // микрофон, когда пользователь отошёл.
        recorder.startWarmListening()
        startWarmIdleWatch()
        // Возврат системного входа, если его захватила BT-гарнитура (по настройке).
        SystemInputGuard.shared.applySetting()
        startDictionaryCheckWatch()
        QuickFixService.shared.start()
        Self.trashRemovedFeatureModels()
    }

    /// Модели удалённых функций (LLM «Глубокая чистка», Sage, нейро-пунктуация RUPunct)
    /// больше не нужны — в Корзину, а не насовсем: ~1,5 ГБ, и пользователь может вернуть.
    /// Модели WhisperKit лежат в общей папке `~/Documents/huggingface` — её не трогаем.
    private static func trashRemovedFeatureModels() {
        DispatchQueue.global(qos: .utility).async {
            let base = AppPaths.appSupportDir
            for rel in ["models/LLM", "models/Sage", "RUPunct_small.mlmodelc"] {
                let url = base.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    DebugLog.log("App: модель удалённой функции перенесена в Корзину — \(rel)")
                } catch {
                    DebugLog.log("App: не удалось перенести в Корзину \(rel) — \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Автопроверка словаря

    /// Ревизия словаря + разбор диктовок по расписанию из настроек. Сама ничего не
    /// меняет: находки показываются тостом, решение — за пользователем (авто-
    /// пополнение словаря однажды уже намусорило, см. DictionaryAudit).
    private var dictionaryCheckTimer: Timer?

    private func startDictionaryCheckWatch() {
        dictionaryCheckTimer?.invalidate()
        // Раз в полчаса сверяемся с расписанием: на минутные интервалы точность не нужна.
        dictionaryCheckTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickDictionaryCheck() }
        }
        // Первый прогон — через минуту после старта, чтобы не мешать запуску.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.tickDictionaryCheck()
        }
    }

    private func tickDictionaryCheck() {
        guard let interval = settings.dictionaryCheckSchedule.interval else { return }
        let last = settings.lastDictionaryCheckAt
        // Первый запуск после включения настройки не должен срабатывать мгновенно.
        if last == 0 {
            settings.lastDictionaryCheckAt = Date().timeIntervalSince1970
            return
        }
        guard Date().timeIntervalSince1970 - last >= interval else { return }
        if case .recording = state { return }
        runDictionaryCheck()
    }

    /// Прогон проверки (используется расписанием и кнопкой «Проверить сейчас»).
    @discardableResult
    func runDictionaryCheck() -> Int {
        settings.lastDictionaryCheckAt = Date().timeIntervalSince1970
        let audit = DictionaryAudit.audit(corrections.allOrdered())
        DebugLog.log("DictCheck: замечаний \(audit.count)")
        HUDManager.shared.showDictionaryCheck(auditCount: audit.count)
        return audit.count
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
        // Слежение за клавишей быстрой правки, поставленное при запуске до выдачи
        // Универсального доступа, мёртвое — ставим заново, как и Fn.
        QuickFixService.shared.start()
        ensureActiveEngineLoaded()
        recorder.startWarmListening()   // разрешение на микрофон только что выдано
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            HUDManager.shared.showReady()
        }
    }

    /// Triggered by any UI affordance the user touches (menu icon, settings, recording start).
    /// Acts as a no-op if the model is already loaded or loading.
    func warmUpIfNeeded() {
        ensureActiveEngineLoaded()
    }

    /// Load whichever engine is currently selected (GigaAM or Parakeet).
    private func ensureActiveEngineLoaded() {
        switch settings.sttEngine {
        case .parakeet: ParakeetTranscriber.shared.ensureLoaded()
        case .gigaAM: GigaAMTranscriber.shared.ensureLoaded()
        }
    }

    /// Применить смену настройки «Мгновенный старт» или устройства ввода:
    /// перезапустить (или погасить) тёплый аудио-движок.
    func restartWarmListening() {
        recorder.stopWarmListening()
        recorder.startWarmListening()
    }

    // MARK: - Warm-idle watch

    /// Открытый микрофон держит PreventUserIdleSystemSleep — Мак с тёплым движком
    /// не уснул бы сам и разряжался. Если пользователь не трогает ввод ≥3 минут,
    /// диктовка невозможна физически → отпускаем микрофон (система может спать);
    /// при возвращении активности прогреваем обратно.
    private static let warmIdleSuspendSeconds: TimeInterval = 180

    private func startWarmIdleWatch() {
        warmIdleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickWarmIdle() }
        }
    }

    private func tickWarmIdle() {
        guard settings.instantRecordStart else { return }
        if case .recording = state { return }   // активную запись не трогаем
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= Self.warmIdleSuspendSeconds {
            if recorder.isWarmListening {
                DebugLog.log("Audio: user idle \(Int(idle))s — suspending warm listening (allow sleep)")
                recorder.stopWarmListening()
            }
        } else if !recorder.isWarmListening {
            recorder.startWarmListening()
        }
    }

    func reconfigureHotkey(_ kind: HotkeyKind) {
        settings.hotkeyRaw = kind.rawValue
        hotkeys.reconfigure(hotkey: kind)
    }

    // MARK: - Recording flow

    private func handlePress() {
        DebugLog.log("App: handlePress entered, state=\(state), tapPhase=\(tapPhase)")
        switch tapPhase {
        case .awaitingSecondTap:
            startHandsFree()
            return
        case .handsFree:
            // Нажатие в свободной записи — стоп и вставка туда, где сейчас курсор.
            // Клики до этого момента — осознанный переход в нужное поле, не «уход».
            ignoreNextRelease = true
            clickedDuringRecording = false
            pressFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            endHandsFreeState()
            DebugLog.log("App: свободная запись — стоп по нажатию")
            finishRecording()
            return
        case .none:
            break
        }
        // .error must not be a dead end: the next press simply retries (the cause —
        // e.g. an unplugged mic — may be gone by now). .complete is a purely
        // cosmetic 0.5s tail — a press during it used to swallow the entire next
        // dictation in fast back-to-back use.
        switch state {
        case .idle, .error, .complete: break
        default: return
        }
        guard AVAuthStatus.audio == .authorized else {
            recorder.requestPermissionIfNeeded { _ in }
            return
        }
        // Lazy load: ensure the model starts loading in the background while we record.
        // If the user holds Fn for several seconds, the model is usually ready by release.
        ensureActiveEngineLoaded()
        // Мьют — ДО старта движка: смена состояния BT-вывода дёргает у запущенного
        // AVAudioEngine конфигурацию (наблюдалось: мьют → configuration change через
        // 1–5 мс) и вызывает лишний перезапуск захвата с потерей начала фразы.
        if settings.muteSystemAudioOnRecord {
            SystemAudioMuter.shared.mute()
        }
        do {
            try recorder.start()
            pressStartedAt = Date()
            state = .recording(level: 0)
            HUDManager.shared.showRecording()
            installEscMonitor()
            startFocusTracking()
            // Живой черновик в HUD — лёгкий превью-цикл движка (распознаёт весь
            // буфер на отпускании, превью — только для показа).
            // Живой черновик включён всегда (тоггл убран как лишний).
            if settings.sttEngine == .parakeet {
                ParakeetTranscriber.shared.startPreview(samples: { [weak self] in
                    self?.recorder.currentSamples() ?? []
                })
            }
            if settings.sttEngine == .gigaAM {
                GigaAMTranscriber.shared.startPreview(samples: { [weak self] in
                    self?.recorder.currentSamples() ?? []
                })
            }
        } catch {
            SystemAudioMuter.shared.restore()   // звук глушили до старта — вернуть
            state = .error(error.localizedDescription)
            hotkeys.resetPressState()   // keep the Caps Lock toggle in sync
            // Auto-recover: without this the state machine had no way out of .error
            // and the hotkey stayed dead until app restart.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if case .error = self?.state { self?.state = .idle }
            }
        }
    }

    // MARK: - Cancel (Esc)

    /// Install a transient Esc watcher for the duration of recording. Passive monitors
    /// (can't consume the event), so Esc also reaches the frontmost app — acceptable,
    /// since during dictation the user isn't typing into it. Both global (other apps
    /// focused) and local (our own window focused) are needed to catch Esc anywhere.
    /// Запоминаем приложение на старте записи и ловим клики мышью до отпускания клавиши.
    /// Заодно просим Electron-приложение открыть дерево доступности — к моменту вставки
    /// поле ввода будет видно.
    private func startFocusTracking() {
        let front = NSWorkspace.shared.frontmostApplication
        pressFrontPID = front?.processIdentifier
        clickedDuringRecording = false
        TextInserter.prepareAccessibility(for: front)
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.clickedDuringRecording = true
        }
    }

    private func stopFocusTracking() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    private var focusMayHaveMoved: Bool {
        clickedDuringRecording
            || (pressFrontPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier != pressFrontPID)
    }

    /// В свободной записи вы работаете за компьютером, и одиночный Esc (закрыть окно,
    /// отменить действие) не должен уничтожать длинную запись — нужен двойной Esc.
    private func handleEsc() {
        if tapPhase == .handsFree {
            if let last = lastEscAt, Date().timeIntervalSince(last) < 0.8 {
                lastEscAt = nil
                cancelDictation(reason: "двойной Esc")
            } else {
                lastEscAt = Date()
            }
            return
        }
        cancelDictation()
    }

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == AppController.escKeyCode {
                Task { @MainActor in self?.handleEsc() }
            }
        }
        escMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == AppController.escKeyCode {
                self?.handleEsc()
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

    /// Abort the current dictation without pasting. Triggered by Esc while recording
    /// (drops the audio) or while transcribing (drops the in-flight decode — matters
    /// when the model is still downloading and the app would otherwise hang in
    /// .transcribing with no way out).
    func cancelDictation(reason: String = "Esc") {
        secondTapWork?.cancel()
        secondTapWork = nil
        endHandsFreeState()
        ignoreNextRelease = false
        switch state {
        case .recording:
            DebugLog.log("App: dictation cancelled (\(reason))")
            SystemAudioMuter.shared.restore()
            stopFocusTracking()
            recorder.cancel()
        case .transcribing:
            DebugLog.log("App: transcription cancelled via Esc")
            transcribeTask?.cancel()
            transcribeTask = nil
        default:
            return
        }
        removeEscMonitor()
        state = .idle
        HUDManager.shared.hideRecording()
        hotkeys.resetPressState()   // keep the Caps Lock toggle in sync
        Task { await ParakeetTranscriber.shared.stopPreview() }
        Task { await GigaAMTranscriber.shared.stopPreview() }
        ParakeetTranscriber.shared.clearLivePreview()
        GigaAMTranscriber.shared.clearLivePreview()
    }

    private func handleRelease() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard case .recording = state else {
            DebugLog.log("App: handleRelease bailing, state was \(state)")
            return
        }
        if tapPhase == .handsFree { return }
        // Короткое нажатие (не удержание) — возможно, первое из двойного. Запись идёт
        // дальше; если второе нажатие не придёт, это случайный тап — тихо отменяем.
        // У Caps Lock нажатия и так переключатель — там двойного нажатия нет.
        if settings.hotkey != .capsLock, let t0 = pressStartedAt,
           Date().timeIntervalSince(t0) < Self.tapMaxHold {
            tapPhase = .awaitingSecondTap
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.tapPhase == .awaitingSecondTap else { return }
                self.tapPhase = .none
                DebugLog.log("App: одиночное короткое нажатие — запись отменена")
                self.cancelDictation(reason: "короткое нажатие")
            }
            secondTapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: work)
            return
        }
        finishRecording()
    }

    // MARK: - Свободная запись

    private func startHandsFree() {
        secondTapWork?.cancel()
        secondTapWork = nil
        tapPhase = .handsFree
        ignoreNextRelease = true
        handsFreeStartedAt = Date()
        DebugLog.log("App: свободная запись — старт (двойное нажатие)")
        // Готовые куски распознаются точным режимом прямо во время записи — после
        // остановки остаётся только хвост.
        if settings.sttEngine == .gigaAM { GigaAMTranscriber.shared.setPreciseCommits(true) }
        let limit = DispatchWorkItem { [weak self] in
            guard let self, self.tapPhase == .handsFree else { return }
            DebugLog.log("App: свободная запись — лимит \(Int(Self.handsFreeLimit / 60)) мин, стоп, текст в буфер")
            self.endHandsFreeState()
            self.finishRecording(clipboardOnly: true)
        }
        handsFreeLimitWork = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handsFreeLimit, execute: limit)
    }

    private func endHandsFreeState() {
        tapPhase = .none
        handsFreeStartedAt = nil
        handsFreeLimitWork?.cancel()
        handsFreeLimitWork = nil
    }

    /// Остановить запись и отдать звук на распознавание (бывшее тело handleRelease).
    /// `clipboardOnly` — не вставлять, а положить текст в буфер (стоп по лимиту: где
    /// сейчас курсор, неизвестно).
    private func finishRecording(clipboardOnly: Bool = false) {
        guard case .recording = state else { return }
        forceClipboardOnly = clipboardOnly
        // Esc monitors intentionally stay installed: Esc can also cancel the
        // transcription phase (see cancelDictation). Removed when finalize runs.
        SystemAudioMuter.shared.restore()   // звук возвращаем сразу, не дожидаясь распознавания
        stopFocusTracking()
        let samples = recorder.stop()
        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        pendingArchiveAudio = settings.keepDictationAudio ? samples : nil
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

        transcribeTask = Task { [weak self] in
            guard let self else { return }
            // Активный движок распознаёт весь буфер целиком (длинную запись режет сам).
            let rawText: String
            switch self.settings.sttEngine {
            case .parakeet:
                rawText = await ParakeetTranscriber.shared.transcribe(audio: samples)
            case .gigaAM:
                rawText = await GigaAMTranscriber.shared.transcribe(audio: samples)
            }
            // Сырой выход движка запоминаем до всей пост-обработки: по нему потом
            // видно, что изменила пост-обработка, и на нём сравниваются настройки
            // распознавания.
            let engineText = rawText
            // Esc during transcription cancels this task — drop the result instead
            // of pasting into whatever field happens to be focused by now.
            if Task.isCancelled {
                DebugLog.log("App: transcription was cancelled — dropping result")
                return
            }
            await MainActor.run {
                self.removeEscMonitor()
                self.transcribeTask = nil
                let procMs = self.settings.sttEngine == .parakeet
                    ? ParakeetTranscriber.shared.lastProcessingMs
                    : GigaAMTranscriber.shared.lastProcessingMs
                DebugLog.log("App: transcribe finished, rawLen=\(rawText.count) text=\(rawText.prefix(80))")
                self.finalize(rawText: rawText, engineText: engineText,
                              duration: duration, processingMs: procMs)
            }
        }
    }

    private func finalize(rawText: String, engineText: String = "",
                          duration: Double, processingMs: Int) {
        let applyResult = applier.apply(to: rawText)
        let dictText = applyResult.text
        var appliedText = settings.normalizeNumbers ? NumberNormalizer.normalize(dictText) : dictText
        // Не зависят от движка: рубленые фразы перед
        // «а / но / хотя / потому что…» склеиваются запятой, потерянный «?» ставится
        // там, где вопрос однозначен по грамматике.
        let merged = PunctuationFixer.mergeContinuationClauses(appliedText)
        if merged != appliedText { DebugLog.log("App: склейка союзов — «\(appliedText.suffix(60))» → «\(merged.suffix(60))»") }
        appliedText = PunctuationFixer.restoreQuestionMarks(merged)
        lastSubstitutions = applyResult.substitutions

        // Bump persistent counters for the Dashboard.
        if !applyResult.substitutions.isEmpty {
            let fuzzy = applyResult.substitutions.filter { $0.fuzzy }.count
            settings.totalSubstitutions += applyResult.substitutions.count
            settings.fuzzySubstitutions += fuzzy
        }

        var record = TranscriptionRecord(
            engineText: engineText,
            rawText: rawText,
            appliedText: appliedText,
            finalText: appliedText,
            durationSeconds: duration,
            processingMs: processingMs,
            createdAt: Date()
        )
        if let id = history.add(record) {
            record.id = id
            if let audio = pendingArchiveAudio {
                AudioArchive.save(audio, historyId: id, engineText: engineText, finalText: appliedText)
            }
        }
        pendingArchiveAudio = nil
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

        DebugLog.log("App: finalize appliedLen=\(appliedText.count)")

        // Transition to .complete and always hide the recording mic.
        lastPasteOutcome = .pending
        state = .complete
        HUDManager.shared.hideRecording()
        ParakeetTranscriber.shared.clearLivePreview()
        GigaAMTranscriber.shared.clearLivePreview()

        if !appliedText.isEmpty {
            let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let focusMoved = focusMayHaveMoved
            if focusMoved { DebugLog.log("App: за время диктовки был клик или смена приложения") }
            let clipboardOnly = forceClipboardOnly
            forceClipboardOnly = false
            Task { [weak self] in
                guard let self else { return }
                let outcome: PasteOutcome
                if clipboardOnly {
                    self.inserter.copyOnly(appliedText)
                    outcome = .clipboardOnly
                } else {
                    outcome = await self.inserter.paste(appliedText, focusMayHaveMoved: focusMoved)
                }
                await MainActor.run {
                    self.lastPasteOutcome = outcome
                    // Verified paste (`.pasted`) needs no HUD — the user sees the text in the field
                    // and the auto-learn watcher will pick up edits automatically. All other outcomes
                    // surface the HUD so the user gets feedback and access to Edit & Learn:
                    //   • clipboardOnly / failed → text in clipboard, manual ⌘V needed
                    //   • pastedNoAutoLearn → paste worked but watcher can't track edits in this app
                    //     (Max / Bitrix24 / Termius / Slack…); Edit & Learn is the only way to teach
                    //     corrections to the dictionary.
                    switch outcome {
                    case .pasted: break
                    case .clipboardOnly, .failed, .pastedKeptInClipboard:
                        // Текст в буфере — об этом нужно сказать даже в тихом режиме,
                        // иначе он выглядит пропавшим.
                        HUDManager.shared.showClipboardNotice(record: record, outcome: outcome)
                    default:
                        HUDManager.shared.showResult(record: record)
                    }
                    if outcome == .pasted {
                        TextChangeWatcher.shared.startWatching(
                            pastedText: appliedText,
                            frontBundleID: frontBundle,
                            appliedSubstitutions: self.lastSubstitutions,
                            field: self.inserter.lastVerifiedField
                        )
                    }
                }
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

    // MARK: - File transcription (offline)

    /// Transcribe arbitrary audio samples (decoded from a file) through the ACTIVE engine
    /// and the same text pipeline as live dictation — but WITHOUT paste / HUD / history /
    /// auto-learn. Used by the "Транскрибировать файл…" feature. Long files are chunked
    /// by the engine's own `transcribe(audio:)`.
    func transcribeAudioSamples(_ samples: [Float]) async -> String {
        let raw: String
        switch settings.sttEngine {
        case .parakeet: raw = await ParakeetTranscriber.shared.transcribe(audio: samples)
        case .gigaAM: raw = await GigaAMTranscriber.shared.transcribe(audio: samples)
        }
        return applyTextPipeline(raw)
    }

    /// Post-recognition text pipeline shared with live dictation (dictionary → numbers →
    /// punctuation), minus the stats/paste side-effects of `finalize`.
    private func applyTextPipeline(_ rawText: String) -> String {
        guard !rawText.isEmpty else { return rawText }
        let dictText = applier.apply(to: rawText).text
        let t = settings.normalizeNumbers ? NumberNormalizer.normalize(dictText) : dictText
        return PunctuationFixer.restoreQuestionMarks(PunctuationFixer.mergeContinuationClauses(t))
    }

    // MARK: - Edit & Learn

    /// Persist user edits: update history and update correction dictionary scores.
    func commitEdit(recordId: Int64, raw: String, applied: String, final: String,
                    autoApplied: [AppliedSubstitution]) {
        history.updateFinal(id: recordId, finalText: final)
        // Окна «История» и «Словарь правок» читают базу один раз при открытии, поэтому
        // после правки из отдельного окна Edit & Learn они показывали старый текст —
        // выглядело так, будто «Сохранить и обучить» ничего не сделала.
        defer { NotificationCenter.default.post(name: .voiceVoiceDataDidChange, object: nil) }

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

extension Notification.Name {
    /// История и/или словарь правок изменились — открытым окнам нужно перечитать базу.
    static let voiceVoiceDataDidChange = Notification.Name("voiceVoiceDataDidChange")
}

enum AVAuthStatus {
    static var audio: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}
