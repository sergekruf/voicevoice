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

    private var manager: AsrManager?
    private var loadingTask: Task<Void, Never>?
    private let settings = AppSettings.shared

    private init() {}

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

    /// Transcribe mono 16 kHz Float samples. Parakeet handles long audio natively, so
    /// no pre-chunking — one call. Reuses the shared hallucination blocklist + cleanup.
    func transcribe(audio: [Float]) async -> String {
        ensureLoaded()
        while true {
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
        do {
            // Language hint left nil: v3 auto-detects, and the hint is only a script
            // filter. Can be wired from settings.language later if needed.
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(audio, decoderState: &decoderState, language: nil)
            lastProcessingMs = Int(Date().timeIntervalSince(start) * 1000)
            let blocklist = Transcriber.parseBlocklist(settings.hallucinationBlocklist)
            let cleaned = Transcriber.cleanup(Transcriber.stripHallucinations(result.text, sentenceBlocklist: blocklist))
            DebugLog.log("Parakeet: done in \(lastProcessingMs)ms, len=\(cleaned.count), cleaned=\(cleaned.prefix(80))")
            return cleaned
        } catch {
            DebugLog.log("Parakeet: transcribe FAILED — \(error.localizedDescription)")
            return ""
        }
    }
}
