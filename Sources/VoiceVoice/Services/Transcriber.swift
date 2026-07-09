import Foundation
import WhisperKit
import Combine

@MainActor
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    enum ModelState: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case error(String)
    }

    @Published private(set) var state: ModelState = .notLoaded
    @Published private(set) var lastProcessingMs: Int = 0
    /// Draft text of the current dictation, updated as eager-streaming chunks commit
    /// (~every 12 s of speech). Shown live in the recording HUD; cleared by
    /// AppController when the dictation finishes or is cancelled.
    @Published private(set) var livePreviewText: String = ""

    private var pipeline: WhisperKit?
    private var loadingTask: Task<Void, Never>?

    // ── Eager streaming state ────────────────────────────────────────────────
    // While recording, we transcribe completed VAD chunks in the background so
    // that on key-release only the trailing (uncommitted) audio remains to decode.
    // See startStreaming / finishStreaming.
    private var streamTask: Task<Void, Never>?
    private var streamPieces: [(text: String, realPauseAfter: Bool)] = []
    private var streamCommittedOffset: Int = 0
    private var streamingActive = false
    /// Session generation. Bumped by startStreaming/cancelStreaming so an in-flight
    /// chunk decode from a CANCELLED session can't commit its text/offset into the
    /// next session after its `await` resumes. finishStreaming intentionally does
    /// NOT bump it — there the in-flight chunk must still commit.
    private var streamGeneration = 0
    /// Accumulated decode wall-time across all eager chunks of the current session,
    /// so `lastProcessingMs` reflects total compute (not just the tail) for the
    /// Dashboard's RTF stat.
    private var streamDecodeMs: Int = 0

    private let settings = AppSettings.shared

    private init() {}

    func ensureLoaded() {
        if case .ready = state { return }
        if loadingTask != nil { return }
        loadingTask = Task { await load() }
    }

    private func load() async {
        state = .loading
        let modelName = settings.modelName
        let repo = "argmaxinc/whisperkit-coreml"
        DebugLog.log("Transcriber: load() begin for model=\(modelName)")

        do {
            let pipe = try await buildPipeline(modelName: modelName, repo: repo)
            DebugLog.log("Transcriber: WhisperKit() returned successfully")
            self.pipeline = pipe

            self.state = .ready
            settings.lastSuccessfulLoadAt = Date().timeIntervalSince1970
            settings.lastSuccessfulModelId = modelName
            DebugLog.log("Transcriber: state=ready, model=\(modelName)")
        } catch {
            DebugLog.log("Transcriber: WhisperKit init FAILED — \(error.localizedDescription)")
            self.state = .error(error.localizedDescription)
        }
        loadingTask = nil
    }

    /// Build the WhisperKit pipeline. Preferred path: explicit `WhisperKit.download`
    /// (idempotent, cached after first run) so we can surface real download progress,
    /// then load from the local folder. If that throws (e.g. offline with the model
    /// already cached — `download` still hits the network for the file list), fall back
    /// to letting WhisperKit resolve download/local itself (original behavior, no
    /// progress). Guarantees we're never worse than before the progress feature.
    private func buildPipeline(modelName: String, repo: String) async throws -> WhisperKit {
        do {
            DebugLog.log("Transcriber: ensuring model downloaded…")
            let folder = try await WhisperKit.download(
                variant: modelName,
                from: repo,
                progressCallback: { [weak self] progress in
                    let f = progress.fractionCompleted
                    guard f < 1.0 else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        if case .ready = self.state { return }
                        self.state = .downloading(progress: f)
                    }
                }
            )
            state = .loading
            DebugLog.log("Transcriber: building WhisperKitConfig (modelFolder=\(folder.lastPathComponent))")
            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,  // skip the warm-up inference pass; saves ~3-5s on cold load
                load: true,
                download: false
            )
            DebugLog.log("Transcriber: calling WhisperKit(config)…")
            return try await WhisperKit(config)
        } catch {
            DebugLog.log("Transcriber: download-with-progress failed (\(error.localizedDescription)); falling back to config-managed load")
            state = .loading
            let config = WhisperKitConfig(
                model: modelName,
                modelRepo: repo,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            return try await WhisperKit(config)
        }
    }

    func reloadIfModelChanged() {
        pipeline = nil
        state = .notLoaded
        loadingTask?.cancel()
        loadingTask = nil
        ensureLoaded()
    }

    /// Transcribe an array of mono 16 kHz float32 samples in [-1, 1].
    func transcribe(audio: [Float]) async -> String {
        ensureLoaded()
        // Wait until ready (or error / cancellation — Esc can abort a dictation
        // stuck waiting on a model download). Keep this off main work.
        while true {
            if Task.isCancelled { return "" }
            switch state {
            case .ready: break
            case .error(let msg):
                NSLog("VoiceVoice transcriber error: \(msg)")
                return ""
            default:
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            break
        }

        guard let pipe = pipeline else {
            DebugLog.log("Transcribe: pipeline is nil")
            return ""
        }
        guard audio.count >= Int(AudioRecorder.targetSampleRate * 0.25) else {
            DebugLog.log("Transcribe: audio too short (\(audio.count) samples, < 0.25s)")
            return ""
        }

        let start = Date()
        // Пустые куски спасает per-chunk rescue-ретрай внутри `decodeOneChunk`.
        let cleaned = await runDecode(audio: audio, pipe: pipe)
        lastProcessingMs = Int(Date().timeIntervalSince(start) * 1000)
        DebugLog.log("Transcribe: done in \(lastProcessingMs)ms, len=\(cleaned.count), cleaned=\(cleaned.prefix(80))")
        return cleaned
    }

    // MARK: - Eager streaming

    /// Begin transcribing completed VAD chunks WHILE the user is still recording.
    /// `samples` is a thread-safe snapshot provider (the recorder's current buffer).
    /// Each time ≥ one full chunk's worth of new audio has accrued past the last
    /// committed offset, we cut it on silence and decode it in the background. On
    /// key-release `finishStreaming` only has to decode the short trailing tail, so
    /// the perceived latency for long dictations drops to near-zero.
    ///
    /// Output parity with batch: the chunk boundaries use the SAME silence-cut logic
    /// as `chunkBySilence`, so the joined transcript matches what batch mode would produce.
    func startStreaming(samples: @escaping () -> [Float]) {
        cancelStreaming()
        ensureLoaded()
        streamPieces = []
        streamCommittedOffset = 0
        streamDecodeMs = 0
        streamingActive = true
        livePreviewText = ""
        let generation = streamGeneration
        DebugLog.log("Stream: started")
        streamTask = Task { [weak self] in
            await self?.streamLoop(samples: samples, generation: generation)
        }
    }

    private func streamLoop(samples: @escaping () -> [Float], generation: Int) async {
        let vad = EnergyVAD()
        while streamingActive && !Task.isCancelled && generation == streamGeneration {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !streamingActive || Task.isCancelled { break }
            guard case .ready = state, let pipe = pipeline else { continue }

            let snap = samples()
            let fresh = snap.count - streamCommittedOffset
            // Only commit a chunk once a FULL chunk's worth of fresh audio exists, so
            // the trailing edge always has room to be cut on silence rather than mid-word.
            guard fresh >= Self.maxChunkSamples else {
                // Полного чанка ещё нет — обновляем живой черновик передекодированием
                // хвоста (turbo на ANE ≈ 0.1×RT, хвост ≤12 с — доли секунды). rawDecode
                // БЕЗ rescue-ретрая: на тишине вернёт пусто, черновик просто не обновится.
                if fresh >= Int(AudioRecorder.targetSampleRate * 0.8) {
                    let tail = Array(snap[streamCommittedOffset..<snap.count])
                    let text = await rawDecode(tail, pipe: pipe, opts: makeOpts(looseThresholds: false))
                    guard generation == streamGeneration else { break }
                    if !text.isEmpty {
                        livePreviewText = stripHallucinationsUsingSettings(
                            (streamPieces.map(\.text) + [text]).joined(separator: " ")
                        )
                    }
                }
                continue
            }

            let (cut, realPause) = Self.findSilenceCut(in: snap, from: streamCommittedOffset, upTo: snap.count, vad: vad)
            guard cut > streamCommittedOffset else { continue }

            let chunk = Array(snap[streamCommittedOffset..<cut])
            let t0 = Date()
            // decodeOneChunk includes the empty-rescue retry → eager chunks no longer
            // silently lose ~12 с of speech when Whisper returns empty.
            let text = await decodeOneChunk(chunk, pipe: pipe)
            // Отпускание клавиши посреди декода: finishStreaming отменяет задачу,
            // WhisperKit бросает CancellationError, текст приходит ПУСТЫМ. Коммитить
            // смещение нельзя — иначе хвост в finishStreaming пропустит этот кусок и
            // начало диктовки потеряется (реальный кейс: из 13 с осталось 2.6 с).
            // Прерванный кусок уходит в хвост и передекодируется там.
            if text.isEmpty && Task.isCancelled {
                DebugLog.log("Stream: in-flight chunk decode was cancelled — leaving audio for the tail")
                break
            }
            // The session may have been cancelled (Esc) — and even restarted — while
            // the decode was in flight; `cut` is in the OLD buffer's coordinates.
            guard generation == streamGeneration else {
                DebugLog.log("Stream: dropping in-flight chunk of a cancelled session")
                break
            }
            streamDecodeMs += Int(Date().timeIntervalSince(t0) * 1000)
            if !text.isEmpty { streamPieces.append((text, realPause)) }
            streamCommittedOffset = cut
            livePreviewText = streamPieces.map(\.text).joined(separator: " ")
            DebugLog.log("Stream: committed chunk up to \(cut) (\(text.count) chars, realPause=\(realPause)), pieces=\(streamPieces.count)")
        }
    }

    /// Finish an eager-streaming session: stop the loop, wait for any in-flight
    /// chunk, decode the remaining tail (everything after the last committed
    /// offset), and return the full joined transcript. Falls back to a plain
    /// `transcribe(audio:)` if streaming was never actually started.
    func finishStreaming(finalSamples: [Float]) async -> String {
        guard streamTask != nil else {
            // Streaming wasn't running (model wasn't ready, or eager disabled) —
            // just do a normal full transcription.
            return await transcribe(audio: finalSamples)
        }
        let start = Date()
        streamingActive = false
        streamTask?.cancel()
        _ = await streamTask?.value   // wait for the in-flight chunk to commit
        streamTask = nil

        // Model never became ready during the session (lazy load still downloading /
        // compiling): nothing was committed and the tail can't be decoded here. Fall
        // back to the plain path, which WAITS for the model — otherwise the whole
        // dictation would be silently lost.
        guard pipeline != nil else {
            DebugLog.log("Stream: model not ready at finish — falling back to full transcribe")
            streamPieces = []
            streamCommittedOffset = 0
            streamDecodeMs = 0
            return await transcribe(audio: finalSamples)
        }

        var items = streamPieces
        let totalDecodeMs = streamDecodeMs
        let tailStart = min(streamCommittedOffset, finalSamples.count)
        let tail = tailStart < finalSamples.count ? Array(finalSamples[tailStart...]) : []
        DebugLog.log("Stream: finishing — committed=\(tailStart), tail=\(tail.count) samples, pieces=\(items.count)")
        var tailMs = 0
        // Tail может быть длиннее одного куска → чанкуем его так же (с флагами пауз +
        // empty-rescue на каждый кусок), чтобы и внутри хвоста была умная склейка.
        if tail.count >= Int(AudioRecorder.targetSampleRate * 0.25), let pipe = pipeline {
            let t0 = Date()
            for ch in Self.chunkBySilence(tail) {
                if Task.isCancelled { break }
                let t = await decodeOneChunk(ch.samples, pipe: pipe)
                if !t.isEmpty { items.append((t, ch.realPauseAfter)) }
            }
            tailMs = Int(Date().timeIntervalSince(t0) * 1000)
        }

        streamPieces = []
        streamCommittedOffset = 0
        streamDecodeMs = 0
        streamingActive = false

        let cleaned = Self.cleanup(stripHallucinationsUsingSettings(Self.joinChunkTexts(items)))
        // Total compute across eager chunks + tail, so the Dashboard RTF stays honest
        // (wall-time would understate it since eager work overlapped recording).
        lastProcessingMs = totalDecodeMs + tailMs
        DebugLog.log("Stream: done — wall=\(Int(Date().timeIntervalSince(start) * 1000))ms compute=\(lastProcessingMs)ms, len=\(cleaned.count), cleaned=\(cleaned.prefix(80))")
        return cleaned
    }

    /// Tear down any active streaming session without producing output (e.g. a new
    /// recording started before the previous finished).
    func cancelStreaming() {
        streamGeneration += 1   // invalidate any in-flight chunk commit
        streamingActive = false
        streamTask?.cancel()
        streamTask = nil
        streamPieces = []
        streamCommittedOffset = 0
        livePreviewText = ""
    }

    /// Clear the live-preview draft (dictation finished or aborted).
    func clearLivePreview() { livePreviewText = "" }

    /// One decode pass over the whole audio. Pre-chunks (see `chunkBySilence`), decodes
    /// each chunk with empty-rescue retry, then smart-joins (false sentence breaks at
    /// forced cuts removed). Returns the cleaned, joined transcript.
    private func runDecode(audio: [Float], pipe: WhisperKit) async -> String {
        let chunks = Self.chunkBySilence(audio)
        DebugLog.log("Transcribe: decode pass samples=\(audio.count), chunks=\(chunks.count)")
        var items: [(text: String, realPauseAfter: Bool)] = []
        for (i, ch) in chunks.enumerated() {
            if Task.isCancelled { break }
            let t = await decodeOneChunk(ch.samples, pipe: pipe)
            DebugLog.log("Transcribe: chunk \(i + 1)/\(chunks.count) samples=\(ch.samples.count) → \(t.count) chars, realPauseAfter=\(ch.realPauseAfter)")
            if !t.isEmpty { items.append((t, ch.realPauseAfter)) }
        }
        return Self.cleanup(stripHallucinationsUsingSettings(Self.joinChunkTexts(items)))
    }

    /// Decode a single ≤14 с chunk. Если обычный проход вернул ПУСТО (Whisper иногда
    /// целиком отбрасывает кусок по no-speech/logProb-порогам), делаем один ретрай
    /// со снятыми порогами — спасает настоящую речь, которая иначе терялась бы.
    private func decodeOneChunk(_ chunk: [Float], pipe: WhisperKit) async -> String {
        var text = await rawDecode(chunk, pipe: pipe, opts: makeOpts(looseThresholds: false))
        if text.isEmpty {
            DebugLog.log("Transcribe: chunk empty → rescue retry (thresholds off)")
            text = await rawDecode(chunk, pipe: pipe, opts: makeOpts(looseThresholds: true))
        }
        return text
    }

    private func rawDecode(_ chunk: [Float], pipe: WhisperKit, opts: DecodingOptions) async -> String {
        do {
            let results = try await pipe.transcribe(audioArray: chunk, decodeOptions: opts)
            return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            DebugLog.log("Transcribe: rawDecode FAILED — \(error.localizedDescription)")
            return ""
        }
    }

    /// Build decode options. `looseThresholds` — выключить пороги отсева (rescue-ретрай).
    ///
    /// `sampleLength: 224` — НЕ задирать выше: WhisperKit передаёт его как `maxTokenContext`
    /// в MLMultiArray фикс. размера `Constants.maxTokenContext = 224`; выше → out-of-bounds
    /// → SIGABRT. Пороги (compressionRatio/logProb/firstTokenLogProb/noSpeech) при
    /// `looseThresholds` снимаем: сложный кусок иначе ложно уходит в fallback и
    /// возвращает пустоту.
    private func makeOpts(looseThresholds: Bool) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            // «auto» из настроек — это НЕ код языка: WhisperKit ожидает валидный код
            // или nil (автоопределение). Строка "auto" ломала префилл языкового токена.
            language: settings.language == "auto" ? nil : settings.language,
            temperature: 0,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: false,
            compressionRatioThreshold: looseThresholds ? nil : 2.4,
            logProbThreshold: looseThresholds ? nil : -1.0,
            firstTokenLogProbThreshold: looseThresholds ? nil : -1.5,
            noSpeechThreshold: looseThresholds ? nil : 0.95
        )
    }

    // MARK: - Pre-chunking

    /// Hard cap per chunk. 12 секунд ≈ 180-200 токенов на плотной русской речи —
    /// безопасный запас от потолка декодера 223 (см. комментарий выше).
    private static let maxChunkSamples: Int = 12 * Int(AudioRecorder.targetSampleRate)
    /// Не режем, если аудио помещается в один чанк (плюс небольшой допуск, чтобы
    /// 12.5-секундную запись не дробить на 12 + 0.5).
    private static let chunkCutoffSamples: Int = 13 * Int(AudioRecorder.targetSampleRate)
    /// Окно поиска тишины вокруг целевой границы (±2 секунды).
    private static let silenceSearchWindowSamples: Int = 2 * Int(AudioRecorder.targetSampleRate)
    /// Минимальная длина тишины (во VAD-фреймах по 0.1 с), чтобы принять её как точку
    /// реза. EnergyVAD ловит и одиночные 100-мс провалы энергии — это часто пауза
    /// ВНУТРИ слова (взрывные согласные, придыхание), рез по ней обрезает звук. Требуем
    /// ≥ 3 фреймов (~300 мс) — настоящая граница между словами/фразами. Если такой
    /// тишины в окне нет, режем по `maxChunkSamples` (как раньше). Ноль новых
    /// зависимостей; нейро-VAD (Silero) при необходимости — отдельный шаг.
    private static let minSilenceFrames = 3
    /// Порог «настоящей границы предложения»: пауза ≥0.5 с. Более короткая тишина
    /// (0.3–0.5 с) — годная точка реза, но слишком часто оказывается заминкой
    /// ВНУТРИ фразы или растянутым словом («скину…ть») — на таком стыке ложная
    /// точка/заглавная должны убираться склейкой, а не сохраняться.
    private static let realPauseMinFrames = 5

    /// Делит аудио на куски ≤ `maxChunkSamples`, стараясь резать по самой длинной
    /// тишине в окне `[target ± silenceSearchWindow]`. Если тишины нет — режет
    /// тупо по `maxChunkSamples` (хуже, но всё равно лучше потерянного хвоста).
    ///
    /// Internal — переиспользуется ParakeetTranscriber: у Parakeet своя причина резать
    /// (FluidAudio даёт пунктуацию/заглавные только на одном окне ≤ 15 с = 240_000
    /// сэмплов; длиннее → скользящее окно без пунктуации). Наш максимум реза =
    /// `maxChunkSamples`(12 с) + `silenceSearchWindow`(2 с) = 14 с < 15 с — безопасно
    /// держит каждый кусок в «однооконном» пунктуационном пути обоих движков.
    /// Один кусок аудио + признак того, что рез ПОСЛЕ него пришёлся на настоящую паузу
    /// (≥ minSilenceFrames). На таком стыке движок ставит границу предложения корректно;
    /// на вынужденном резе (`realPauseAfter == false`) точка/заглавная ложные — склейка
    /// их уберёт (см. `joinChunkTexts`). Последний кусок всегда `realPauseAfter == true`.
    struct AudioChunk { let samples: [Float]; let realPauseAfter: Bool }

    static func chunkBySilence(_ audio: [Float]) -> [AudioChunk] {
        if audio.count <= chunkCutoffSamples { return [AudioChunk(samples: audio, realPauseAfter: true)] }
        let vad = EnergyVAD()  // sampleRate=16000, frameLengthSamples=1600 (0.1 с)
        var result: [AudioChunk] = []
        var cursor = 0
        while cursor < audio.count {
            let remaining = audio.count - cursor
            if remaining <= chunkCutoffSamples {
                result.append(AudioChunk(samples: Array(audio[cursor..<audio.count]), realPauseAfter: true))
                break
            }
            let (cutAt, realPause) = findSilenceCut(in: audio, from: cursor, upTo: audio.count, vad: vad)
            result.append(AudioChunk(samples: Array(audio[cursor..<cutAt]), realPauseAfter: realPause))
            cursor = cutAt
        }
        return result
    }

    /// Находит точку реза для чанка, начинающегося на `from`: целится в
    /// `from + maxChunkSamples` и сдвигает рез в окне `±silenceSearchWindow`:
    ///   1) если есть настоящая пауза (≥ minSilenceFrames) — режем по её середине,
    ///      возвращаем `realPause = true` (граница предложения корректна);
    ///   2) иначе — режем в САМОЙ ТИХОЙ точке окна (микропауза между словами), а не
    ///      по слепому индексу `target`, и возвращаем `realPause = false` (рез внутри
    ///      предложения — склейка потом уберёт ложную точку/заглавную).
    /// Гарантирует `from < cut <= limit`.
    static func findSilenceCut(in audio: [Float], from cursor: Int, upTo limit: Int, vad: EnergyVAD) -> (cut: Int, realPause: Bool) {
        let target = cursor + maxChunkSamples
        let searchStart = max(cursor + maxChunkSamples - silenceSearchWindowSamples, cursor + 1)
        let searchEnd = min(cursor + maxChunkSamples + silenceSearchWindowSamples, limit)
        var cutAt = target
        var realPause = false
        if searchEnd > searchStart {
            let window = Array(audio[searchStart..<searchEnd])
            let vadResult = vad.voiceActivity(in: window)
            if let silence = vad.findLongestSilence(in: vadResult),
               silence.endIndex - silence.startIndex >= minSilenceFrames {
                // Тишина ≥0.3 с → режем по её середине (макс. отступ от речи), но
                // границей ПРЕДЛОЖЕНИЯ считаем только паузу ≥0.5 с — короткие
                // заминки внутри фразы иначе оставляли ложную точку на стыке.
                let frames = silence.endIndex - silence.startIndex
                let silenceMid = silence.startIndex + frames / 2
                cutAt = searchStart + vad.voiceActivityIndexToAudioSampleIndex(silenceMid)
                realPause = frames >= realPauseMinFrames
            } else {
                // Сплошная речь без паузы → режем в самой тихой точке (стык слов/слогов),
                // а не вслепую посреди слова.
                cutAt = searchStart + lowestEnergyOffset(in: window)
            }
        }
        return (min(max(cutAt, cursor + 1), limit), realPause)
    }

    /// Возвращает offset (в сэмплах от начала `window`) центра кадра 0.1 с с
    /// наименьшей энергией — самая тихая точка окна, лучший кандидат на рез, когда
    /// явной паузы нет.
    private static func lowestEnergyOffset(in window: [Float]) -> Int {
        let frame = 1600                       // 0.1 с при 16 кГц
        guard window.count > frame else { return window.count / 2 }
        var minEnergy = Float.greatestFiniteMagnitude
        var bestCenter = window.count / 2
        var i = 0
        while i < window.count {
            let end = Swift.min(i + frame, window.count)
            var sum: Float = 0
            var j = i
            while j < end { sum += window[j] * window[j]; j += 1 }
            let energy = sum / Float(end - i)
            if energy < minEnergy {
                minEnergy = energy
                bestCenter = i + (end - i) / 2
            }
            i += frame
        }
        return bestCenter
    }

    // MARK: - Smart join across chunk boundaries

    /// Слова, которые обычно стоят со строчной буквы внутри предложения. Если кусок
    /// после ВЫНУЖДЕННОГО реза начинается с такого слова с заглавной — это ложная
    /// заглавная (движок принял стык за начало предложения), приводим к строчной.
    /// Имена собственные сюда НЕ входят — их регистр не трогаем.
    private static let lowercaseLeadWords: Set<String> = [
        "и", "а", "но", "что", "чтобы", "потому", "поэтому", "для", "в", "во", "на", "с",
        "со", "по", "к", "о", "об", "из", "от", "до", "при", "за", "под", "над", "это",
        "как", "когда", "если", "то", "же", "бы", "ли", "или", "да", "тоже", "также",
        "хотя", "пока", "раз", "ведь", "чем", "где", "куда", "откуда", "зато", "причем",
        "который", "которая", "которое", "которые", "которых", "которым", "которой",
        "которую", "которого", "котором", "которыми", "которому",
        "его", "ее", "их", "там", "тут", "здесь", "потом", "затем", "значит", "поэтому",
        "чтоб", "ну", "вот", "так",
    ]

    /// Склеивает куски с учётом флага `realPauseAfter`:
    ///   • после НАСТОЯЩЕЙ паузы — оставляем как отдельные предложения (точка + заглавная);
    ///   • после ВЫНУЖДЕННОГО реза (середина предложения) — убираем ложную точку у
    ///     предыдущего куска и ложную заглавную у следующего (если это служебное слово),
    ///     склеивая в одно предложение.
    static func joinChunkTexts(_ items: [(text: String, realPauseAfter: Bool)]) -> String {
        var out = ""
        for (i, item) in items.enumerated() {
            var t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Кусок, начавшийся с обрезанного резом слова, движки помечают мусорной
            // пунктуацией в начале («..ть», «, слово») — вычищаем ведущие знаки.
            while let f = t.first, ".,;:…".contains(f) { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if out.isEmpty { out = t; continue }
            if items[i - 1].realPauseAfter {
                // Настоящая пауза. Два симметричных артефакта стыка:
                //  • терминатор есть, а следующий кусок со строчной («…текст. повторные…»)
                //    → поднимаем регистр;
                //  • терминатора НЕТ (движок понял, что предложение продолжается:
                //    «…связь от | У других…»), а следующий кусок начат с заглавной —
                //    это «начало высказывания» декодера, а не граница → понижаем
                //    служебное слово (список консервативный, имена не трогаем).
                if let last = out.last, ".!?…".contains(last) {
                    out += " " + uppercasedLead(t)
                } else {
                    out += " " + lowercasedLeadIfFunction(t)
                }
            } else {
                out = stripTrailingSentenceTerminator(out)
                out += " " + lowercasedLeadIfFunction(t)
            }
        }
        return out
    }

    private static func stripTrailingSentenceTerminator(_ s: String) -> String {
        var t = s
        while let last = t.last, last == "." || last == "…" { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func uppercasedLead(_ s: String) -> String {
        guard let first = s.first, first.isLowercase else { return s }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private static func lowercasedLeadIfFunction(_ s: String) -> String {
        guard let first = s.first, first.isUppercase else { return s }
        let word = String(s.prefix(while: { $0.isLetter }))
            .lowercased().replacingOccurrences(of: "ё", with: "е")
        guard lowercaseLeadWords.contains(word) else { return s }
        return s.prefix(1).lowercased() + s.dropFirst()
    }

    static func cleanup(_ s: String) -> String {
        // Trim and collapse leading/trailing whitespace; Whisper sometimes adds a leading space.
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse multiple spaces.
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }

    // MARK: - Hallucination blocklist

    /// Whisper заучил титры с YouTube из несанированных обучающих данных и на
    /// тишине/шуме/паузах уверенно выдаёт самую вероятную конфабуляцию. В русском
    /// это узнаваемые фразы-«титры». VAD-обрезка тишины убирает большинство
    /// триггеров, но детерминированный блоклист — это 100%-надёжный добивающий
    /// слой. Сравнение пословное по ЦЕЛОМУ предложению (а не подстроке), чтобы не
    /// съесть настоящую речь. Новые артефакты можно добавлять сюда из логов.
    ///
    /// Встроенный список фраз-«титров» (одна на строку). Редактор в настройках убран
    /// как невостребованный — новые артефакты добавляются сюда из логов. Технические
    /// kill-токены (DimaTorzok и т.п.) живут отдельно в `hallucinationSubstrings`.
    nonisolated static let defaultHallucinationBlocklistText = """
    Продолжение следует
    Спасибо за просмотр
    Подписывайтесь на канал
    Подписывайтесь на наш канал
    Ставьте лайки и подписывайтесь
    """

    /// Распаршенный дефолтный блоклист (единожды).
    nonisolated static let defaultBlocklist: Set<String> = parseBlocklist(defaultHallucinationBlocklistText)

    /// Парсит многострочный список в нормализованное множество для сравнения.
    nonisolated static func parseBlocklist(_ raw: String) -> Set<String> {
        var set = Set<String>()
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let norm = normalizeForBlocklist(String(line))
            if !norm.isEmpty { set.insert(norm) }
        }
        return set
    }

    /// Токены, которые НИКОГДА не встречаются в осмысленной русской диктовке —
    /// если предложение их содержит, оно целиком артефакт. В отличие от
    /// `hallucinationSentences`, матчатся как подстрока.
    private static let hallucinationSubstrings: [String] = [
        "dimatorzok",
        "amara.org",
        "subtitles by",
        "редактор субтитров",
        "корректор а.",
    ]

    /// Удаляет из текста предложения, целиком совпадающие с известными
    /// галлюцинациями Whisper. Безопасно для настоящей речи: дропается только
    /// предложение, нормализованная форма которого равна записи блоклиста или
    /// содержит «kill-token» вроде `dimatorzok`. `sentenceBlocklist` — нормализованное
    /// множество фраз (из настроек пользователя).
    static func stripHallucinations(_ text: String, sentenceBlocklist: Set<String>) -> String {
        guard !text.isEmpty else { return text }
        let sentences = splitSentencesKeepingTrailing(text)
        var kept: [String] = []
        for sent in sentences {
            let norm = normalizeForBlocklist(sent)
            if norm.isEmpty {
                kept.append(sent)
                continue
            }
            if sentenceBlocklist.contains(norm) {
                DebugLog.log("Blocklist: dropped sentence \"\(norm.prefix(60))\"")
                continue
            }
            if hallucinationSubstrings.contains(where: { norm.contains($0) }) {
                DebugLog.log("Blocklist: dropped (substring) \"\(norm.prefix(60))\"")
                continue
            }
            kept.append(sent)
        }
        return kept.joined()
    }

    /// Instance wrapper: pulls the user-editable phrase list from settings and strips.
    private func stripHallucinationsUsingSettings(_ text: String) -> String {
        Self.stripHallucinations(text, sentenceBlocklist: Self.defaultBlocklist)
    }

    nonisolated private static func normalizeForBlocklist(_ s: String) -> String {
        var n = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r.,!?…—–-«»\"'()"))
        while n.contains("  ") { n = n.replacingOccurrences(of: "  ", with: " ") }
        return n
    }

    /// Делит текст на предложения, сохраняя хвостовой разделитель на каждом куске,
    /// так что `.joined()` воспроизводит исходный текст (минус выкинутые).
    private static func splitSentencesKeepingTrailing(_ s: String) -> [String] {
        let ns = s as NSString
        let regex = try! NSRegularExpression(pattern: #"(?<=[\.\!\?…])\s+"#, options: [])
        let matches = regex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return [s] }
        var result: [String] = []
        var cursor = 0
        for m in matches {
            let len = m.range.location - cursor
            let sent = ns.substring(with: NSRange(location: cursor, length: len))
            let sep = ns.substring(with: m.range)
            result.append(sent + sep)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { result.append(ns.substring(from: cursor)) }
        return result
    }
}
