import Foundation
import FluidAudio
import Combine

/// Опциональный движок распознавания на NVIDIA Parakeet TDT v3 через FluidAudio
/// (CoreML/ANE). По сравнению с WhisperKit: ~5× быстрее, ~66 МБ RAM, нативно держит
/// длинное аудио (нет 223-токенного потолка → не нужен наш pre-chunking) и поддерживает
/// русский. Слабее с пунктуацией — компенсируется нашим PunctuationFixer на этапе
/// постобработки (см. AppController.finalize).
///
/// Дефолтный движок остаётся WhisperKit; Parakeet включается в Настройках, и его модель
/// (~600 МБ) скачивается только при первом выборе — вес дефолтной сборки не растёт.
///
/// Зеркалит минимальную поверхность, которую дёргают AppController и UI: `state`,
/// `lastProcessingMs`, `ensureLoaded()`, `transcribe(audio:)`. Состояние использует тот
/// же `Transcriber.ModelState`, чтобы меню/настройки рендерили оба движка единообразно.
@MainActor
final class ParakeetTranscriber: ObservableObject {
    static let shared = ParakeetTranscriber()

    @Published private(set) var state: Transcriber.ModelState = .notLoaded
    @Published private(set) var lastProcessingMs: Int = 0
    /// Draft text of the current dictation, refreshed every ~1.5 s while recording
    /// (committed silence-cut chunks decoded once + the live tail re-decoded each
    /// tick — Parakeet on ANE is fast enough for that). Shown in the recording HUD.
    @Published private(set) var livePreviewText: String = ""

    private var manager: AsrManager?
    private var loadingTask: Task<Void, Never>?
    private let settings = AppSettings.shared

    // ── Live preview state ───────────────────────────────────────────────────
    private var previewTask: Task<Void, Never>?
    private var previewPieces: [String] = []
    private var previewCommittedOffset = 0

    private init() {}

    // MARK: - Live preview (during recording)

    /// Start refreshing `livePreviewText` from the recorder's buffer snapshots.
    /// No-op work while the model isn't ready (never blocks recording).
    func startPreview(samples: @escaping () -> [Float]) {
        previewTask?.cancel()
        previewPieces = []
        previewCommittedOffset = 0
        livePreviewText = ""
        previewTask = Task { [weak self] in await self?.previewLoop(samples: samples) }
    }

    /// Stop the preview loop and WAIT for an in-flight decode to finish — the final
    /// transcription must not run concurrently with a preview decode on the same
    /// AsrManager. Keeps the last draft on screen (cleared via clearLivePreview()).
    func stopPreview() async {
        previewTask?.cancel()
        _ = await previewTask?.value
        previewTask = nil
    }

    /// Clear the draft (dictation finished or aborted).
    func clearLivePreview() { livePreviewText = "" }

    private func previewLoop(samples: @escaping () -> [Float]) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { break }
            guard case .ready = state, let manager else { continue }

            let snap = samples()
            guard snap.count - previewCommittedOffset >= Int(AudioRecorder.targetSampleRate * 0.6) else { continue }
            let fresh = Array(snap[previewCommittedOffset...])
            // Same silence-cut chunking as the final path: every chunk except the
            // last is finished speech — decode once and commit; the last one is the
            // live tail — re-decode it each tick (≤ one Parakeet window, fast).
            let chunks = Transcriber.chunkBySilence(fresh)
            guard !chunks.isEmpty else { continue }
            for ch in chunks.dropLast() {
                if Task.isCancelled { return }
                let t = await previewDecode(ch.samples, manager: manager)
                if !t.isEmpty { previewPieces.append(t) }
                previewCommittedOffset += ch.samples.count
            }
            if Task.isCancelled { return }
            let tailText = await previewDecode(chunks[chunks.count - 1].samples, manager: manager)
            if Task.isCancelled { return }
            let joined = (previewPieces + [tailText]).filter { !$0.isEmpty }.joined(separator: " ")
            if !joined.isEmpty { livePreviewText = joined }
        }
    }

    private func previewDecode(_ audio: [Float], manager: AsrManager) async -> String {
        guard audio.count >= Int(AudioRecorder.targetSampleRate * 0.5) else { return "" }
        do {
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(audio, decoderState: &decoderState, language: nil)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            DebugLog.log("Parakeet: preview decode failed — \(error.localizedDescription)")
            return ""
        }
    }

    func ensureLoaded() {
        if case .ready = state { return }
        if loadingTask != nil { return }
        loadingTask = Task { await load() }
    }

    private func load() async {
        state = .loading
        DebugLog.log("Parakeet: load() begin (v3)")
        do {
            // Idempotent download (cached after first run) with progress, mirroring the
            // WhisperKit path so the first-run ~600MB fetch shows a real percentage.
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { [weak self] progress in
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
            let mgr = AsrManager()
            try await mgr.loadModels(models)
            self.manager = mgr
            self.state = .ready
            settings.lastSuccessfulLoadAt = Date().timeIntervalSince1970
            settings.lastSuccessfulModelId = "parakeet-tdt-0.6b-v3"
            DebugLog.log("Parakeet: state=ready")
        } catch {
            DebugLog.log("Parakeet: load FAILED — \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
        loadingTask = nil
    }

    func reload() {
        manager = nil
        state = .notLoaded
        loadingTask?.cancel()
        loadingTask = nil
        ensureLoaded()
    }

    /// Transcribe mono 16 kHz Float samples. Pre-chunks long audio into ≤14 с pieces on
    /// silence: FluidAudio gives punctuation+capitalization only on a single window
    /// ≤15 с (`maxModelSamples = 240_000`); beyond that it falls into a sliding-window
    /// path that returns a lowercase, unpunctuated blob. Each chunk decoded with a fresh
    /// decoder state → standalone punctuated sentence → joined. Short audio (≤13 с) is a
    /// single call, unchanged. Reuses the shared hallucination blocklist + cleanup.
    func transcribe(audio: [Float]) async -> String {
        // The preview loop shares the AsrManager — make sure it's fully stopped
        // before the final decode.
        await stopPreview()
        ensureLoaded()
        while true {
            if Task.isCancelled { return "" }
            switch state {
            case .ready: break
            case .error(let m): NSLog("VoiceVoice Parakeet error: \(m)"); return ""
            default:
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            break
        }
        guard let manager else {
            DebugLog.log("Parakeet: manager is nil")
            return ""
        }
        guard audio.count >= Int(AudioRecorder.targetSampleRate * 0.25) else {
            DebugLog.log("Parakeet: audio too short (\(audio.count) samples)")
            return ""
        }

        let start = Date()
        // ≤13 с → один кусок (быстрый путь без изменений). Длиннее → режем по тишине,
        // каждый кусок остаётся в «однооконном» пунктуационном пути FluidAudio.
        // do/catch — ВНУТРИ цикла: ошибка одного куска (сбой CoreML/ANE) не должна
        // выбрасывать уже распознанные — для часового файла это потеря всего результата.
        let chunks = Transcriber.chunkBySilence(audio)
        var items: [(text: String, realPauseAfter: Bool)] = []
        var failedChunks = 0
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { break }
            do {
                // Свежее decoder-состояние на каждый кусок → самостоятельная фраза с
                // собственной пунктуацией и заглавной буквой.
                var decoderState = try TdtDecoderState()
                // Language hint nil: v3 auto-detects (hint — лишь скрипт-фильтр).
                let result = try await manager.transcribe(chunk.samples, decoderState: &decoderState, language: nil)
                let t = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                DebugLog.log("Parakeet: chunk \(i + 1)/\(chunks.count) samples=\(chunk.samples.count) → \(t.count) chars, realPauseAfter=\(chunk.realPauseAfter)")
                if !t.isEmpty { items.append((t, chunk.realPauseAfter)) }
            } catch {
                failedChunks += 1
                DebugLog.log("Parakeet: chunk \(i + 1)/\(chunks.count) FAILED — \(error.localizedDescription); keeping the rest")
            }
        }
        lastProcessingMs = Int(Date().timeIntervalSince(start) * 1000)
        let blocklist = Transcriber.parseBlocklist(settings.hallucinationBlocklist)
        // Умная склейка: на вынужденных резах убираем ложную точку/заглавную.
        let cleaned = Transcriber.cleanup(Transcriber.stripHallucinations(Transcriber.joinChunkTexts(items), sentenceBlocklist: blocklist))
        DebugLog.log("Parakeet: done in \(lastProcessingMs)ms, chunks=\(chunks.count), failed=\(failedChunks), len=\(cleaned.count), cleaned=\(cleaned.prefix(80))")
        return cleaned
    }
}
