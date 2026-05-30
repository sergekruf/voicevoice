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

    private var pipeline: WhisperKit?
    private var loadingTask: Task<Void, Never>?
    /// Cached tokens of a punctuation-rich Russian prompt, used to bias the model
    /// toward producing punctuation. Computed once per model load.
    private var punctuationPromptTokens: [Int] = []

    // ── Eager streaming state ────────────────────────────────────────────────
    // While recording, we transcribe completed VAD chunks in the background so
    // that on key-release only the trailing (uncommitted) audio remains to decode.
    // See startStreaming / finishStreaming.
    private var streamTask: Task<Void, Never>?
    private var streamPieces: [String] = []
    private var streamCommittedOffset: Int = 0
    private var streamingActive = false
    /// Accumulated decode wall-time across all eager chunks of the current session,
    /// so `lastProcessingMs` reflects total compute (not just the tail) for the
    /// Dashboard's RTF stat.
    private var streamDecodeMs: Int = 0

    private let settings = AppSettings.shared

    /// Punctuation-rich seed. Whisper uses `promptTokens` as "previous context",
    /// which biases it to match the style — including reliably emitting commas,
    /// periods, question and exclamation marks for Russian. Particularly important
    /// for 4-bit quantized models, where punctuation is often dropped.
    ///
    /// КОРОТКИЙ намеренно: длинная "previous context" (>50 токенов) рушит
    /// first-token-log-prob и avgLogProb на коротких пользовательских фразах,
    /// декодер уходит в temperature-fallback, после 3 retry возвращается пустой
    /// результат. Здесь ~25 токенов с разнообразной пунктуацией.
    private let punctuationPromptText = """
    Привет, друзья! Как ваши дела? Всё хорошо — спасибо. \
    Получаем точную транскрипцию с пунктуацией.
    """

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

            if let tokenizer = pipe.tokenizer {
                let encoded = tokenizer.encode(text: " " + self.punctuationPromptText)
                self.punctuationPromptTokens = encoded.filter { $0 < 50_000 }
                DebugLog.log("Transcriber: punctuation prompt tokens=\(self.punctuationPromptTokens.count)")
            } else {
                DebugLog.log("Transcriber: tokenizer is nil (no punctuation prompt available)")
            }

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
        // Wait until ready (or error). Keep this off main work.
        while true {
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
        let usePunctPrompt = settings.punctuationPrompt && !punctuationPromptTokens.isEmpty

        var cleaned = await runDecode(audio: audio, pipe: pipe, usePunctPrompt: usePunctPrompt)

        // Safety net: на некоторых моделях (например `large-v3-turbo` full precision)
        // punctuation-prompt ломает декодер — он сразу выдаёт EOT, и результат пустой
        // на ВСЕХ чанках, хотя аудио явно содержит речь. Промпт затачивался под 4-bit,
        // где он спасает пунктуацию; на full-precision пользы почти нет (см. README/
        // настройки), а вот пустой вывод — катастрофа. Если с промптом получили
        // пусто — молча перераспознаём без промпта. Тоггл становится безопасным:
        // помогает где работает, тихо деградирует где ломает.
        if cleaned.isEmpty && usePunctPrompt {
            DebugLog.log("Transcribe: empty result WITH punctuation prompt — retrying WITHOUT prompt")
            cleaned = await runDecode(audio: audio, pipe: pipe, usePunctPrompt: false)
        }

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
    /// as `preChunk`, so the joined transcript matches what batch mode would produce.
    func startStreaming(samples: @escaping () -> [Float]) {
        cancelStreaming()
        ensureLoaded()
        streamPieces = []
        streamCommittedOffset = 0
        streamDecodeMs = 0
        streamingActive = true
        DebugLog.log("Stream: started")
        streamTask = Task { [weak self] in
            await self?.streamLoop(samples: samples)
        }
    }

    private func streamLoop(samples: @escaping () -> [Float]) async {
        let vad = EnergyVAD()
        while streamingActive && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !streamingActive || Task.isCancelled { break }
            guard case .ready = state, let pipe = pipeline else { continue }

            let snap = samples()
            // Only commit a chunk once a FULL chunk's worth of fresh audio exists, so
            // the trailing edge always has room to be cut on silence rather than mid-word.
            guard snap.count - streamCommittedOffset >= Self.maxChunkSamples else { continue }

            let cut = Self.findSilenceCut(in: snap, from: streamCommittedOffset, upTo: snap.count, vad: vad)
            guard cut > streamCommittedOffset else { continue }

            // Recompute per-iteration so the prompt is picked up once tokens populate
            // (they're computed on model load, which may finish after streaming starts).
            let usePunctPrompt = settings.punctuationPrompt && !punctuationPromptTokens.isEmpty
            let chunk = Array(snap[streamCommittedOffset..<cut])
            let t0 = Date()
            var text = await runDecode(audio: chunk, pipe: pipe, usePunctPrompt: usePunctPrompt)
            if text.isEmpty && usePunctPrompt {
                text = await runDecode(audio: chunk, pipe: pipe, usePunctPrompt: false)
            }
            streamDecodeMs += Int(Date().timeIntervalSince(t0) * 1000)
            if !text.isEmpty { streamPieces.append(text) }
            streamCommittedOffset = cut
            DebugLog.log("Stream: committed chunk up to \(cut) (\(text.count) chars), pieces=\(streamPieces.count)")
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

        var pieces = streamPieces
        let totalDecodeMs = streamDecodeMs
        let tailStart = min(streamCommittedOffset, finalSamples.count)
        let tail = tailStart < finalSamples.count ? Array(finalSamples[tailStart...]) : []
        DebugLog.log("Stream: finishing — committed=\(tailStart), tail=\(tail.count) samples, pieces=\(pieces.count)")
        var tailMs = 0
        if tail.count >= Int(AudioRecorder.targetSampleRate * 0.25) {
            // Tail can itself be longer than one chunk (if the last <800ms tick didn't
            // commit, or audio grew between snapshot and release) — transcribe() handles
            // its own pre-chunking + empty-prompt fallback.
            let t0 = Date()
            let tailText = await transcribe(audio: tail)
            tailMs = Int(Date().timeIntervalSince(t0) * 1000)
            if !tailText.isEmpty { pieces.append(tailText) }
        }

        streamPieces = []
        streamCommittedOffset = 0
        streamDecodeMs = 0
        streamingActive = false

        let cleaned = Self.cleanup(stripHallucinationsUsingSettings(pieces.joined(separator: " ")))
        // Total compute across eager chunks + tail, so the Dashboard RTF stays honest
        // (wall-time would understate it since eager work overlapped recording).
        lastProcessingMs = totalDecodeMs + tailMs
        DebugLog.log("Stream: done — wall=\(Int(Date().timeIntervalSince(start) * 1000))ms compute=\(lastProcessingMs)ms, len=\(cleaned.count), cleaned=\(cleaned.prefix(80))")
        return cleaned
    }

    /// Tear down any active streaming session without producing output (e.g. a new
    /// recording started before the previous finished).
    func cancelStreaming() {
        streamingActive = false
        streamTask?.cancel()
        streamTask = nil
        streamPieces = []
        streamCommittedOffset = 0
    }

    /// One decode pass over the whole audio with a fixed `usePunctPrompt` flag.
    /// Pre-chunks the audio (see `preChunk`) and decodes each chunk independently,
    /// joining the non-empty pieces. Returns the cleaned, joined transcript.
    private func runDecode(audio: [Float], pipe: WhisperKit, usePunctPrompt: Bool) async -> String {
        let opts = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: settings.language,
            temperature: 0,
            temperatureFallbackCount: 3,
            // ВНИМАНИЕ: НЕ задирать выше 224.
            // WhisperKit передаёт `sampleLength` как `maxTokenContext` в
            // `DecodingInputs.reset(...)`, который пишет в MLMultiArray фиксированного
            // размера `Constants.maxTokenContext = 224`. При sampleLength > 224 идёт
            // запись в индексы вне границ — SIGABRT в CoreML (`MLMultiArray
            // setObject:atIndexedSubscript:`). Дефолт WhisperKit — 224, это и есть
            // потолок для текущей архитектуры моделей.
            sampleLength: 224,
            usePrefillPrompt: true,
            // Когда задан promptTokens, WhisperKit внутри пропускает загрузку
            // prefill-cache (см. TextDecoder.swift:355, TODO в исходнике).
            // Но при `usePrefillCache: true` все равно остаются полу-инициализированные
            // структуры — `cacheLength[0]` остаётся равным prefilledCacheSize от
            // последнего вызова, и главный цикл декодера стартует с этого индекса
            // вместо `initialPrompt.count`. Поэтому явно отключаем cache, когда
            // подаём промпт.
            usePrefillCache: !usePunctPrompt,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: usePunctPrompt ? punctuationPromptTokens : nil,
            suppressBlank: false,
            // Когда включён punctuationPrompt, ВСЕ пороги выключаем:
            //   • compressionRatio / logProb / firstTokenLogProb — длинная
            //     prefill-prompt-секция меняет распределение, дефолтные пороги
            //     ложно срабатывают, уход в temperature-fallback и после 3 retry
            //     возвращается пустая строка.
            //   • noSpeechThreshold — это самый коварный: WhisperKit при
            //     срабатывании НЕ делает retry, а молча помечает сегмент как
            //     silence (см. Models.swift:388, `needsFallback: false`).
            //     С промптом `noSpeechProb` стабильно держится выше 0.95 даже
            //     на хорошей речи — отсюда тотально пустой результат.
            // Без промпта пороги нужны (отсекают gibberish), оставляем дефолты.
            compressionRatioThreshold: usePunctPrompt ? nil : 2.4,
            logProbThreshold: usePunctPrompt ? nil : -1.0,
            firstTokenLogProbThreshold: usePunctPrompt ? nil : -1.5,
            noSpeechThreshold: usePunctPrompt ? nil : 0.95
            // chunkingStrategy НЕ передаём: режем аудио сами в `preChunk(audio:)`
            // ниже. Встроенный `.vad` не помогает — он не режет аудио ≤ 30 с вовсе
            // и оставляет одну плотную фразу упираться в 223-токенный потолок
            // декодера. Наш pre-chunk гарантирует, что каждый кусок ≤ 12 с.
        )

        // Pre-chunk сами, до WhisperKit. Встроенный VAD-чанкер не режет аудио ≤ 30 с
        // вовсе (AudioChunker.swift: `if audioArray.count <= maxChunkLength { return [single] }`),
        // а декодер жёстко клипит `sampleLength` до `Constants.maxTokenContext - 1 = 223`
        // (TextDecoder.swift: `loopCount = min(sampleLength, maxTokenContext - 1)`).
        // Итог: одна плотная фраза 25-30 с упирается в 223 токена и обрывается на
        // полуслове. Режем сами на куски ≤ 12 с по найденной тишине, каждый чанк
        // отдельным вызовом transcribe(), результаты склеиваем.
        let chunks = Self.preChunk(audio: audio)
        DebugLog.log("Transcribe: decode pass samples=\(audio.count), chunks=\(chunks.count), usePrompt=\(usePunctPrompt)")
        var pieces: [String] = []
        for (i, chunk) in chunks.enumerated() {
            do {
                let results = try await pipe.transcribe(audioArray: chunk, decodeOptions: opts)
                let text = results.map { $0.text }.joined(separator: " ")
                DebugLog.log("Transcribe: chunk \(i+1)/\(chunks.count) samples=\(chunk.count) → \(text.count) chars")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
            } catch {
                DebugLog.log("Transcribe: chunk \(i+1)/\(chunks.count) FAILED — \(error.localizedDescription)")
            }
        }
        return Self.cleanup(stripHallucinationsUsingSettings(pieces.joined(separator: " ")))
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

    /// Делит аудио на куски ≤ `maxChunkSamples`, стараясь резать по самой длинной
    /// тишине в окне `[target ± silenceSearchWindow]`. Если тишины нет — режет
    /// тупо по `maxChunkSamples` (хуже, но всё равно лучше потерянного хвоста).
    private static func preChunk(audio: [Float]) -> [[Float]] {
        if audio.count <= chunkCutoffSamples { return [audio] }
        let vad = EnergyVAD()  // sampleRate=16000, frameLengthSamples=1600 (0.1 с)
        var result: [[Float]] = []
        var cursor = 0
        while cursor < audio.count {
            let remaining = audio.count - cursor
            if remaining <= chunkCutoffSamples {
                result.append(Array(audio[cursor..<audio.count]))
                break
            }
            let cutAt = findSilenceCut(in: audio, from: cursor, upTo: audio.count, vad: vad)
            result.append(Array(audio[cursor..<cutAt]))
            cursor = cutAt
        }
        return result
    }

    /// Находит точку реза для чанка, начинающегося на `from`: целится в
    /// `from + maxChunkSamples` и сдвигает рез на середину самой длинной тишины в
    /// окне `±silenceSearchWindow`. Если тишины нет — режет ровно по
    /// `maxChunkSamples`. Гарантирует `from < cut <= limit`.
    private static func findSilenceCut(in audio: [Float], from cursor: Int, upTo limit: Int, vad: EnergyVAD) -> Int {
        let target = cursor + maxChunkSamples
        let searchStart = max(cursor + maxChunkSamples - silenceSearchWindowSamples, cursor + 1)
        let searchEnd = min(cursor + maxChunkSamples + silenceSearchWindowSamples, limit)
        var cutAt = target
        if searchEnd > searchStart {
            let window = Array(audio[searchStart..<searchEnd])
            let vadResult = vad.voiceActivity(in: window)
            if let silence = vad.findLongestSilence(in: vadResult),
               silence.endIndex - silence.startIndex >= minSilenceFrames {
                // Тишина достаточно длинная (≥ minSilenceFrames) → это настоящая
                // граница. Режем по её середине — максимальный отступ от речи с
                // обеих сторон. Слишком короткие провалы игнорируем (пауза внутри
                // слова), оставляя рез на `target`.
                let silenceMid = silence.startIndex + (silence.endIndex - silence.startIndex) / 2
                cutAt = searchStart + vad.voiceActivityIndexToAudioSampleIndex(silenceMid)
            }
        }
        return min(max(cutAt, cursor + 1), limit)
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
    /// Дефолтный редактируемый список фраз-галлюцинаций (одна на строку). Пользователь
    /// может править его в Настройках (`AppSettings.hallucinationBlocklist`); на старте
    /// `AppStorage` берёт именно это значение. Технические kill-токены (DimaTorzok и
    /// т.п.) живут отдельно в `hallucinationSubstrings` и не редактируются.
    static let defaultHallucinationBlocklistText = """
    Продолжение следует
    Спасибо за просмотр
    Подписывайтесь на канал
    Подписывайтесь на наш канал
    Ставьте лайки и подписывайтесь
    """

    /// Парсит многострочный список в нормализованное множество для сравнения.
    static func parseBlocklist(_ raw: String) -> Set<String> {
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
        Self.stripHallucinations(text, sentenceBlocklist: Self.parseBlocklist(settings.hallucinationBlocklist))
    }

    private static func normalizeForBlocklist(_ s: String) -> String {
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
