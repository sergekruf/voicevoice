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

    private let settings = AppSettings.shared

    /// Punctuation-rich seed. Whisper uses `promptTokens` as "previous context", which
    /// strongly biases it to match the style — including reliably emitting commas,
    /// periods, question and exclamation marks for Russian. Particularly important for
    /// 4-bit quantized models, where punctuation is often dropped.
    private let punctuationPromptText = """
    Привет, друзья! Сегодня я хочу рассказать о том, как работают современные технологии. \
    Знаете ли вы, что нейросети могут распознавать речь? Это удивительно: модель учится \
    на огромных объёмах данных. В итоге, мы получаем точную транскрипцию с пунктуацией — \
    запятыми, точками, тире, вопросительными и восклицательными знаками. Замечательно, правда?
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
        DebugLog.log("Transcriber: load() begin for model=\(modelName)")

        do {
            DebugLog.log("Transcriber: building WhisperKitConfig")
            let config = WhisperKitConfig(
                model: modelName,
                modelRepo: "argmaxinc/whisperkit-coreml",
                verbose: false,
                logLevel: .error,
                prewarm: false,  // skip the warm-up inference pass; saves ~3-5s on cold load
                load: true,
                download: true
            )
            DebugLog.log("Transcriber: calling WhisperKit(config)…")
            let pipe = try await WhisperKit(config)
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

        let usePunctPrompt = settings.punctuationPrompt && !punctuationPromptTokens.isEmpty
        let opts = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: settings.language,
            temperature: 0,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: usePunctPrompt ? punctuationPromptTokens : nil,
            suppressBlank: false,
            noSpeechThreshold: 0.95
        )

        let start = Date()
        DebugLog.log("Transcribe: starting, samples=\(audio.count), usePrompt=\(usePunctPrompt)")
        do {
            let results = try await pipe.transcribe(audioArray: audio, decodeOptions: opts)
            let text = results.map { $0.text }.joined(separator: " ")
            lastProcessingMs = Int(Date().timeIntervalSince(start) * 1000)
            let cleaned = Self.cleanup(text)
            DebugLog.log("Transcribe: done in \(lastProcessingMs)ms, rawLen=\(text.count), cleaned=\(cleaned.prefix(80))")
            return cleaned
        } catch {
            DebugLog.log("Transcribe: FAILED — \(error.localizedDescription)")
            return ""
        }
    }

    private static func cleanup(_ s: String) -> String {
        // Trim and collapse leading/trailing whitespace; Whisper sometimes adds a leading space.
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse multiple spaces.
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }
}
