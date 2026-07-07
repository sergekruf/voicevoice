import Foundation
import CoreML
import Combine
import CryptoKit

/// Третий движок распознавания: GigaAM-v3 e2e_ctc (SberDevices, MIT) — модель,
/// специализированная на русском (700 тыс. часов русской речи, WER ~3.3% против
/// ~8% у Whisper на русских бенчмарках). Вариант e2e сам расставляет пунктуацию
/// и нормализует текст — RUPunct/PunctuationFixer для этого движка не нужны.
///
/// Модель НЕ бандлится (~440 МБ) и НЕ скачивается автоматически: Core ML-конвертация
/// делается локально скриптом `.mltools/convert_gigaam.py`, артефакты кладутся в
/// `~/Library/Application Support/VoiceVoice/models/GigaAM/`:
///   • GigaAMv3_e2e_ctc.mlpackage — модель (вход: waveform [1×240000] + length,
///     фиксированное 15-секундное окно с паддингом тишиной; выход: log_probs);
///   • gigaam_vocab.json — словарь SentencePiece-кусочков + blank_id для greedy-CTC.
/// Без файлов движок уходит в .error с подсказкой.
///
/// Зеркалит поверхность ParakeetTranscriber: state / lastProcessingMs / ensureLoaded /
/// transcribe(audio:) / livePreview.
@MainActor
final class GigaAMTranscriber: ObservableObject {
    static let shared = GigaAMTranscriber()

    @Published private(set) var state: Transcriber.ModelState = .notLoaded
    @Published private(set) var lastProcessingMs: Int = 0
    @Published private(set) var livePreviewText: String = ""

    private var model: MLModel?
    private var vocab: [String] = []
    private var blankId = 256
    private var windowSamples = 240_000
    private var loadingTask: Task<Void, Never>?

    // ── Live preview state (как у Parakeet) ──────────────────────────────────
    private var previewTask: Task<Void, Never>?
    private var previewPieces: [String] = []
    private var previewCommittedOffset = 0

    private init() {}

    static var modelDir: URL {
        AppPaths.appSupportDir.appendingPathComponent("models/GigaAM")
    }

    /// Модель установлена локально (проверка для UI настроек).
    static var isModelInstalled: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("GigaAMv3_e2e_ctc.mlpackage").path)
    }

    // Модель хостится ассетом отдельного GitHub-релиза (тег без версии приложения —
    // живёт независимо от релизов кода) и скачивается при первом выборе движка.
    private static let downloadBase = "https://github.com/sergekruf/voicevoice/releases/download/gigaam-v3-e2e-ctc-coreml/"
    private static let modelZipName = "GigaAMv3_e2e_ctc.mlpackage.zip"
    private static let vocabName = "gigaam_vocab.json"
    private static let modelZipSHA256 = "1e83ba165e1f83ceac43ec448f226691a87ecf03728e8ae51a888d15dd71c197"

    private struct Err: LocalizedError { let m: String; var errorDescription: String? { m } }
    private struct VocabFile: Decodable {
        let blank_id: Int
        let window_samples: Int
        let vocab: [String]
    }

    func ensureLoaded() {
        if case .ready = state { return }
        if loadingTask != nil { return }
        loadingTask = Task { await load() }
    }

    func reload() {
        model = nil
        state = .notLoaded
        loadingTask?.cancel()
        loadingTask = nil
        ensureLoaded()
    }

    private func load() async {
        state = .loading
        DebugLog.log("GigaAM: load() begin")
        do {
            let dir = Self.modelDir
            let pkg = dir.appendingPathComponent("GigaAMv3_e2e_ctc.mlpackage")
            let vocabURL = dir.appendingPathComponent(Self.vocabName)
            if !FileManager.default.fileExists(atPath: pkg.path)
                || !FileManager.default.fileExists(atPath: vocabURL.path) {
                try await downloadModel(to: dir)
                state = .loading
            }
            let vf = try JSONDecoder().decode(VocabFile.self, from: Data(contentsOf: vocabURL))
            vocab = vf.vocab
            blankId = vf.blank_id
            windowSamples = vf.window_samples

            // Компиляция .mlpackage → .mlmodelc один раз, кэш рядом с моделью.
            let cached = dir.appendingPathComponent("GigaAMv3_e2e_ctc.mlmodelc")
            let compiled: URL
            if FileManager.default.fileExists(atPath: cached.path) {
                compiled = cached
            } else {
                DebugLog.log("GigaAM: compiling model (first run, может занять минуты)…")
                let tmp = try await MLModel.compileModel(at: pkg)
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.copyItem(at: tmp, to: cached)
                compiled = cached
            }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            model = try MLModel(contentsOf: compiled, configuration: cfg)
            state = .ready
            AppSettings.shared.lastSuccessfulLoadAt = Date().timeIntervalSince1970
            AppSettings.shared.lastSuccessfulModelId = "gigaam-v3-e2e-ctc"
            DebugLog.log("GigaAM: state=ready (vocab=\(vocab.count), blank=\(blankId))")
        } catch {
            DebugLog.log("GigaAM: load FAILED — \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
        loadingTask = nil
    }

    // MARK: - Model download

    /// Скачивает модель (~400 МБ, с прогрессом в `state`) и словарь с GitHub-релиза,
    /// проверяет SHA256 и распаковывает в `modelDir`.
    private func downloadModel(to dir: URL) async throws {
        DebugLog.log("GigaAM: downloading model from GitHub release…")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let vocabRemote = URL(string: Self.downloadBase + Self.vocabName),
              let zipRemote = URL(string: Self.downloadBase + Self.modelZipName) else {
            throw Err(m: "bad model URL")
        }
        let (vocabData, vocabResp) = try await URLSession.shared.data(from: vocabRemote)
        guard (vocabResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Err(m: "Не удалось скачать словарь модели (нет сети?)")
        }

        let tmpZip = try await downloadWithProgress(zipRemote)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        // SHA256 + распаковка — тяжёлые синхронные операции, уводим с главного потока.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let hash = try Self.sha256Hex(of: tmpZip)
                    guard hash == Self.modelZipSHA256 else {
                        throw Err(m: "Контрольная сумма модели не совпала — попробуйте ещё раз")
                    }
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    proc.arguments = ["-x", "-k", tmpZip.path, dir.path]
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else {
                        throw Err(m: "Не удалось распаковать модель")
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        try vocabData.write(to: dir.appendingPathComponent(Self.vocabName))
        DebugLog.log("GigaAM: model downloaded and verified")
    }

    /// downloadTask + опрос `task.progress` — прогресс без делегата URLSession.
    private func downloadWithProgress(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
                if let err { cont.resume(throwing: err); return }
                guard let tmp, let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    cont.resume(throwing: Err(m: "Не удалось скачать модель (HTTP-ошибка)"))
                    return
                }
                // Временный файл системы живёт только внутри completion — переносим.
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gigaam-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: tmp, to: dst)
                    cont.resume(returning: dst)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            task.resume()
            Task { @MainActor [weak self] in
                while task.state == .running {
                    if let self, task.progress.fractionCompleted > 0 {
                        self.state = .downloading(progress: task.progress.fractionCompleted)
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        while let chunk = try fh.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Transcribe

    /// Транскрибирует mono 16 кГц Float-сэмплы. Куски ≤14 с (тот же chunkBySilence,
    /// что у других движков) → паддинг до 15-секундного окна → greedy-CTC.
    func transcribe(audio: [Float]) async -> String {
        await stopPreview()
        ensureLoaded()
        while true {
            if Task.isCancelled { return "" }
            switch state {
            case .ready: break
            case .error(let m): NSLog("VoiceVoice GigaAM error: \(m)"); return ""
            default:
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            break
        }
        guard let model else { return "" }
        guard audio.count >= Int(AudioRecorder.targetSampleRate * 0.25) else {
            DebugLog.log("GigaAM: audio too short (\(audio.count) samples)")
            return ""
        }

        let start = Date()
        let chunks = Transcriber.chunkBySilence(audio)
        var items: [(text: String, realPauseAfter: Bool)] = []
        var failedChunks = 0
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { break }
            do {
                let t = try await decode(chunk.samples, model: model)
                DebugLog.log("GigaAM: chunk \(i + 1)/\(chunks.count) samples=\(chunk.samples.count) → \(t.count) chars")
                // Крошечный хвостовой кусок (<1.2 с), распознанный в одну букву, —
                // остаточный звук/выдох, а не речь («…не тот товар. У.»).
                let isTinyTail = i == chunks.count - 1 && chunks.count > 1
                    && chunk.samples.count < Int(AudioRecorder.targetSampleRate * 1.2)
                if isTinyTail && t.filter({ $0.isLetter }).count <= 1 {
                    DebugLog.log("GigaAM: dropping single-letter tail noise: \"\(t)\"")
                } else if !t.isEmpty {
                    items.append((t, chunk.realPauseAfter))
                }
            } catch {
                failedChunks += 1
                DebugLog.log("GigaAM: chunk \(i + 1)/\(chunks.count) FAILED — \(error.localizedDescription); keeping the rest")
            }
        }
        lastProcessingMs = Int(Date().timeIntervalSince(start) * 1000)
        let cleaned = Transcriber.cleanup(Transcriber.joinChunkTexts(items))
        DebugLog.log("GigaAM: done in \(lastProcessingMs)ms, chunks=\(chunks.count), failed=\(failedChunks), len=\(cleaned.count), cleaned=\(cleaned.prefix(80))")
        return cleaned
    }

    /// Один прогон окна: паддинг → predict (фоновая очередь, MLModel потокобезопасен
    /// для prediction) → greedy-CTC по валидным фреймам.
    private func decode(_ samples: [Float], model: MLModel) async throws -> String {
        guard samples.count >= Int(AudioRecorder.targetSampleRate * 0.25) else { return "" }
        let window = windowSamples
        var padded = [Float](repeating: 0, count: window)
        let n = min(samples.count, window)
        padded.replaceSubrange(0..<n, with: samples[0..<n])

        let wavArray = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
        padded.withUnsafeBufferPointer { src in
            wavArray.dataPointer.bindMemory(to: Float.self, capacity: window)
                .update(from: src.baseAddress!, count: window)
        }
        // Длина в граф не передаётся: маска всегда полная, паддинг-тишина в хвосте
        // даёт блэнки (эквивалентность проверена при конвертации).
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "waveform": wavArray,
        ])

        let out: MLFeatureProvider = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try model.prediction(from: provider)) }
                catch { cont.resume(throwing: error) }
            }
        }
        guard let logProbs = out.featureValue(for: "log_probs")?.multiArrayValue else { return "" }

        // log_probs: [1, T, vocab] за ПОЛНОЕ окно — декодируем ВСЕ фреймы.
        // Обрезка по длине реального аудио теряла финальный знак препинания:
        // CTC ставит «.»/«?» на фреймах ПОСЛЕ последнего слова (уже в тишине).
        // Паддинг-тишина даёт блэнки и мусора не добавляет (проверено на живом аудио).
        let totalFrames = logProbs.shape[1].intValue
        let vocabSize = logProbs.shape[2].intValue
        // ANE отдаёт выход как Float16 — MLShapedArray<Float> на нём ассертит
        // (крэш приложения). Читаем строго по фактическому типу; MLShapedArray
        // заодно корректно разворачивает страйды.
        let scalars: [Float]
        switch logProbs.dataType {
        case .float32:
            scalars = MLShapedArray<Float>(logProbs).scalars
        case .float16:
            if #available(macOS 15.0, *) {
                scalars = MLShapedArray<Float16>(logProbs).scalars.map(Float.init)
            } else {
                // macOS 14: MLShapedArray<Float16> недоступен — поэлементное чтение.
                var out = [Float](repeating: 0, count: totalFrames * vocabSize)
                for i in 0..<out.count { out[i] = logProbs[i].floatValue }
                scalars = out
            }
        default:
            DebugLog.log("GigaAM: unexpected log_probs dtype rawValue=\(logProbs.dataType.rawValue)")
            return ""
        }

        var pieces: [String] = []
        var prev = -1
        for t in 0..<totalFrames {
            let base = t * vocabSize
            var best = 0
            var bestVal = -Float.greatestFiniteMagnitude
            for v in 0..<vocabSize where scalars[base + v] > bestVal {
                bestVal = scalars[base + v]
                best = v
            }
            if best != prev && best != blankId && best < vocab.count {
                pieces.append(vocab[best])
            }
            prev = best
        }
        return Self.stripUnitTails(
            pieces.joined()
                .replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Unit-symbol artifacts

    /// Встроенная нормализация GigaAM иногда «смешивает» символ и хвост исходного
    /// слова: «двадцать три градуса» → «23°дуса» (greedy-CTC интерливит две
    /// конкурирующие записи — «23°» и «23 градуса»). Убираем кириллический хвост
    /// после символа единицы, если он — суффикс соответствующего слова (≥2 букв).
    private static let unitTailWords: [Character: [String]] = [
        "°": ["градус", "градуса", "градусов", "градусах", "градусам"],
        "%": ["процент", "процента", "процентов", "процентах", "процентам"],
        "№": ["номер", "номера", "номеров"],
        "$": ["доллар", "доллара", "долларов", "долларах"],
        "€": ["евро"],
        "₽": ["рубль", "рубля", "рублей", "рублях", "рублям"],
    ]

    static func stripUnitTails(_ s: String) -> String {
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            result.append(ch)
            i = s.index(after: i)
            guard let words = unitTailWords[ch] else { continue }
            // Хвост: опционально один пробел, дальше подряд идущие кириллические буквы.
            var j = i
            if j < s.endIndex, s[j] == " " { j = s.index(after: j) }
            var tail = ""
            while j < s.endIndex, let sc = s[j].unicodeScalars.first,
                  (0x0400...0x04FF).contains(sc.value) {
                tail.append(s[j])
                j = s.index(after: j)
            }
            if tail.count >= 2, words.contains(where: { $0.hasSuffix(tail.lowercased()) }) {
                DebugLog.log("GigaAM: dropped unit tail «\(ch)\(tail)» → «\(ch)»")
                i = j
            }
        }
        return result
    }

    // MARK: - Live preview (как у Parakeet)

    func startPreview(samples: @escaping () -> [Float]) {
        previewTask?.cancel()
        previewPieces = []
        previewCommittedOffset = 0
        livePreviewText = ""
        previewTask = Task { [weak self] in await self?.previewLoop(samples: samples) }
    }

    func stopPreview() async {
        previewTask?.cancel()
        _ = await previewTask?.value
        previewTask = nil
    }

    func clearLivePreview() { livePreviewText = "" }

    private func previewLoop(samples: @escaping () -> [Float]) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { break }
            guard case .ready = state, let model else { continue }

            let snap = samples()
            guard snap.count - previewCommittedOffset >= Int(AudioRecorder.targetSampleRate * 0.6) else { continue }
            let fresh = Array(snap[previewCommittedOffset...])
            let chunks = Transcriber.chunkBySilence(fresh)
            guard !chunks.isEmpty else { continue }
            for ch in chunks.dropLast() {
                if Task.isCancelled { return }
                let t = (try? await decode(ch.samples, model: model)) ?? ""
                if !t.isEmpty { previewPieces.append(t) }
                previewCommittedOffset += ch.samples.count
            }
            if Task.isCancelled { return }
            let tailText = (try? await decode(chunks[chunks.count - 1].samples, model: model)) ?? ""
            if Task.isCancelled { return }
            let joined = (previewPieces + [tailText]).filter { !$0.isEmpty }.joined(separator: " ")
            if !joined.isEmpty { livePreviewText = joined }
        }
    }
}
