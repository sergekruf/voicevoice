import Foundation
import CoreML
import Combine
import CryptoKit

/// Третий движок распознавания: GigaAM-v3 e2e_rnnt (SberDevices, MIT) — модель,
/// специализированная на русском (700 тыс. часов русской речи). Вариант e2e сам
/// расставляет пунктуацию и нормализует текст — RUPunct/PunctuationFixer не нужны.
///
/// RNNT вместо CTC: декодер авторегрессионный (каждый токен выбирается с учётом
/// уже написанного), поэтому невозможно смешение конкурирующих записей числительных
/// («де9сто 5ятого»), которым страдал greedy-CTC. Словарь 1024 токена (у CTC — 256).
///
/// Три Core ML-сети (конвертация: `.mltools/convert_gigaam_rnnt.py`, валидация
/// против PyTorch-эталона) в `~/Library/Application Support/VoiceVoice/models/GigaAM/`:
///   • encoder: waveform [1×240000] (15 с, паддинг тишиной) → encoded [1×375×768], ANE;
///   • decoder (prediction network, LSTM 1×320): (token, h, c) → (dec_out, h', c'), CPU;
///   • joint: (enc_frame, dec_out) → log_probs [1×1025], CPU.
/// Скачиваются с GitHub-релиза при первом выборе движка (SHA256 на каждый файл).
///
/// Зеркалит поверхность ParakeetTranscriber: state / lastProcessingMs / ensureLoaded /
/// transcribe(audio:) / livePreview.
@MainActor
final class GigaAMTranscriber: ObservableObject {
    static let shared = GigaAMTranscriber()

    @Published private(set) var state: Transcriber.ModelState = .notLoaded
    @Published private(set) var lastProcessingMs: Int = 0
    @Published private(set) var livePreviewText: String = ""

    private struct RNNTModels {
        let encoder: MLModel
        let decoder: MLModel
        let joint: MLModel
    }
    private var models: RNNTModels?
    private var vocab: [String] = []
    private var blankId = 1024
    private var windowSamples = 240_000
    private var predHidden = 320
    private var predLayers = 1
    private var maxSymbolsPerFrame = 10
    private var segmenter: SentencePieceSegmenter?
    private var loadingTask: Task<Void, Never>?

    // ── Live preview state (как у Parakeet) ──────────────────────────────────
    private var previewTask: Task<Void, Never>?
    private var previewPieces: [String] = []
    private var previewCommittedOffset = 0

    private init() {}

    static var modelDir: URL {
        // Для сравнения версий модели без подмены установленной: папка из окружения.
        if let dir = ProcessInfo.processInfo.environment["VOICEVOICE_GIGAAM_MODEL_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return AppPaths.appSupportDir.appendingPathComponent("models/GigaAM")
    }

    /// Модель установлена локально (проверка для UI настроек).
    static var isModelInstalled: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("GigaAMv3_rnnt_encoder.mlpackage").path)
    }

    // Модели хостятся ассетами отдельного GitHub-релиза (тег без версии приложения —
    // живёт независимо от релизов кода) и скачиваются при первом выборе движка.
    private static let downloadBase = "https://github.com/sergekruf/voicevoice/releases/download/gigaam-v3-e2e-rnnt-coreml/"
    private static let vocabName = "gigaam_rnnt_vocab.json"
    /// (имя пакета, SHA256 zip-архива)
    private static let modelParts: [(pkg: String, sha256: String)] = [
        ("GigaAMv3_rnnt_encoder.mlpackage", "1b7514263ac7960248eb9a55c3ac3f71888165e37df604251bcc022cfcd68365"),
        ("GigaAMv3_rnnt_decoder.mlpackage", "85a527462144ea642c9c81892b0fe0b85de4b98c3b026d157188852782e2209b"),
        ("GigaAMv3_rnnt_joint.mlpackage", "bf8caee4137a269ad3b51341b974d469c7a6462cf78cd9becd1fd5e4d18a9013"),
    ]

    private struct Err: LocalizedError { let m: String; var errorDescription: String? { m } }
    private struct VocabFile: Decodable {
        let blank_id: Int
        let window_samples: Int
        let pred_hidden: Int
        let pred_layers: Int
        let max_symbols_per_frame: Int
        let vocab: [String]
        /// Оценки кусков SentencePiece (есть в словаре с версии модели 25 с) — нужны,
        /// чтобы разбить подсказанные термины на токены модели.
        let scores: [Double]?
    }

    func ensureLoaded() {
        if case .ready = state { return }
        if loadingTask != nil { return }
        loadingTask = Task { await load() }
    }

    func reload() {
        models = nil
        state = .notLoaded
        loadingTask?.cancel()
        loadingTask = nil
        ensureLoaded()
    }

    private func load() async {
        state = .loading
        DebugLog.log("GigaAM: load() begin (rnnt)")
        do {
            let dir = Self.modelDir
            let vocabURL = dir.appendingPathComponent(Self.vocabName)
            let missing = Self.modelParts.contains {
                !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.pkg).path)
            } || !FileManager.default.fileExists(atPath: vocabURL.path)
            if missing {
                try await downloadModel(to: dir)
                state = .loading
            }
            let vf = try JSONDecoder().decode(VocabFile.self, from: Data(contentsOf: vocabURL))
            vocab = vf.vocab
            blankId = vf.blank_id
            windowSamples = vf.window_samples
            predHidden = vf.pred_hidden
            predLayers = vf.pred_layers
            maxSymbolsPerFrame = vf.max_symbols_per_frame
            segmenter = SentencePieceSegmenter(vocab: vf.vocab, scores: vf.scores ?? Self.bundledPieceScores(for: vf.vocab))

            // Энкодер — на ANE; декодер и joint — крошечные сети, которые дёргаются
            // сотни раз за кусок: CPU, чтобы не платить диспатч на ANE за каждый вызов.
            let encoder = try await Self.compileAndLoad(
                pkg: dir.appendingPathComponent("GigaAMv3_rnnt_encoder.mlpackage"), units: .all)
            let decoder = try await Self.compileAndLoad(
                pkg: dir.appendingPathComponent("GigaAMv3_rnnt_decoder.mlpackage"), units: .cpuOnly)
            let joint = try await Self.compileAndLoad(
                pkg: dir.appendingPathComponent("GigaAMv3_rnnt_joint.mlpackage"), units: .cpuOnly)
            models = RNNTModels(encoder: encoder, decoder: decoder, joint: joint)
            state = .ready
            AppSettings.shared.lastSuccessfulLoadAt = Date().timeIntervalSince1970
            AppSettings.shared.lastSuccessfulModelId = "gigaam-v3-e2e-rnnt"
            DebugLog.log("GigaAM: state=ready (rnnt, vocab=\(vocab.count), blank=\(blankId))")
        } catch {
            DebugLog.log("GigaAM: load FAILED — \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
        loadingTask = nil
    }

    /// Компиляция .mlpackage → .mlmodelc (кэш рядом с моделью) + загрузка.
    private static func compileAndLoad(pkg: URL, units: MLComputeUnits) async throws -> MLModel {
        let cached = pkg.deletingPathExtension().appendingPathExtension("mlmodelc")
        if !FileManager.default.fileExists(atPath: cached.path) {
            DebugLog.log("GigaAM: compiling \(pkg.lastPathComponent)…")
            let tmp = try await MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.copyItem(at: tmp, to: cached)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try MLModel(contentsOf: cached, configuration: cfg)
    }

    // MARK: - Model download

    /// Скачивает модель (~400 МБ, с прогрессом в `state`) и словарь с GitHub-релиза,
    /// проверяет SHA256 и распаковывает в `modelDir`.
    private func downloadModel(to dir: URL) async throws {
        DebugLog.log("GigaAM: downloading model from GitHub release…")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let vocabRemote = URL(string: Self.downloadBase + Self.vocabName) else {
            throw Err(m: "bad model URL")
        }
        let (vocabData, vocabResp) = try await URLSession.shared.data(from: vocabRemote)
        guard (vocabResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Err(m: "Не удалось скачать словарь модели (нет сети?)")
        }

        // Три сети по очереди (энкодер ~400 МБ задаёт прогресс, остальные мгновенны).
        for part in Self.modelParts {
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(part.pkg).path) else { continue }
            guard let zipRemote = URL(string: Self.downloadBase + part.pkg + ".zip") else {
                throw Err(m: "bad model URL")
            }
            let tmpZip = try await downloadWithProgress(zipRemote)
            defer { try? FileManager.default.removeItem(at: tmpZip) }

            // SHA256 + распаковка — тяжёлые синхронные операции, уводим с главного потока.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let hash = try Self.sha256Hex(of: tmpZip)
                        guard hash == part.sha256 else {
                            throw Err(m: "Контрольная сумма \(part.pkg) не совпала — попробуйте ещё раз")
                        }
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        proc.arguments = ["-x", "-k", tmpZip.path, dir.path]
                        try proc.run()
                        proc.waitUntilExit()
                        guard proc.terminationStatus == 0 else {
                            throw Err(m: "Не удалось распаковать \(part.pkg)")
                        }
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        try vocabData.write(to: dir.appendingPathComponent(Self.vocabName))
        DebugLog.log("GigaAM: models downloaded and verified")
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
        guard let models else { return "" }
        guard audio.count >= Int(AudioRecorder.targetSampleRate * 0.25) else {
            DebugLog.log("GigaAM: audio too short (\(audio.count) samples)")
            return ""
        }

        let start = Date()
        let chunks = Transcriber.chunkBySilence(audio, windowSeconds: windowSamples / Int(AudioRecorder.targetSampleRate))
        var decoded: [(text: String, sentenceEnds: [Int])?] = Array(repeating: nil, count: chunks.count)
        var failedChunks = 0
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { break }
            do {
                let d = try await decodeDetailed(chunk.samples, models: models, precise: true)
                let t = d.text
                DebugLog.log("GigaAM: chunk \(i + 1)/\(chunks.count) samples=\(chunk.samples.count) → \(t.count) chars")
                // Крошечный хвостовой кусок (<1.2 с), распознанный в одну букву, —
                // остаточный звук/выдох, а не речь («…не тот товар. У.»).
                let isTinyTail = i == chunks.count - 1 && chunks.count > 1
                    && chunk.samples.count < Int(AudioRecorder.targetSampleRate * 1.2)
                if isTinyTail && t.filter({ $0.isLetter }).count <= 1 {
                    DebugLog.log("GigaAM: dropping single-letter tail noise: \"\(t)\"")
                } else if !t.isEmpty {
                    decoded[i] = d
                }
            } catch {
                failedChunks += 1
                DebugLog.log("GigaAM: chunk \(i + 1)/\(chunks.count) FAILED — \(error.localizedDescription); keeping the rest")
            }
        }
        let items = await reconcileSeams(audio: audio, chunks: chunks, decoded: decoded, models: models)
        lastProcessingMs = Int(Date().timeIntervalSince(start) * 1000)
        let cleaned = Transcriber.cleanup(Transcriber.joinChunkTexts(items))
        DebugLog.log("GigaAM: done in \(lastProcessingMs)ms, chunks=\(chunks.count), failed=\(failedChunks), len=\(cleaned.count), cleaned=\(cleaned.prefix(80))")
        return cleaned
    }

    /// Стыки кусков. Движок расставляет знаки в каждом куске по отдельности и конец
    /// куска считает концом высказывания, поэтому заминка посреди фразы, на которую
    /// пришёлся рез, становится ложной границей («маршрутизацию? Трафика»,
    /// «ветровке. В одном из городов России»). Стык, где левый кусок кончился знаком,
    /// распознаётся ещё раз с контекстом по обе стороны, и решение о знаке берётся из
    /// этого прогона. Окно начинается с начала последнего предложения левого куска:
    /// с середины фразы движок недоставляет знаки и терял настоящий «?» («…к десяти
    /// утра? Если нет…»). Цена — один прогон (~0,1 с) на стык со знаком.
    private func reconcileSeams(audio: [Float], chunks: [Transcriber.AudioChunk],
                                decoded: [(text: String, sentenceEnds: [Int])?],
                                models: RNNTModels) async -> [(text: String, realPauseAfter: Bool)] {
        let sr = Int(AudioRecorder.targetSampleRate)
        var texts = decoded.map { $0?.text }
        var pauses = chunks.map(\.realPauseAfter)
        var carryQuestion = false
        var chunkStart = 0
        for i in chunks.indices {
            defer { chunkStart += chunks[i].samples.count }
            if carryQuestion, let t = texts[i] {
                let moved = Transcriber.moveQuestionMark(into: t)
                texts[i] = moved.text
                carryQuestion = !moved.done
            }
            guard i + 1 < chunks.count, !Task.isCancelled,
                  let left = texts[i], let right = texts[i + 1], let ends = decoded[i]?.sentenceEnds
            else { continue }
            // Второй вид ложной границы: знака нет, но следующий кусок начат с заглавной —
            // декодер пишет так начало любого окна («как | Другие разработчики», «дело |
            // Прокачать»). Имя это или артефакт, решает тот же контекстный прогон.
            let leftTerminated = Transcriber.endsWithSentenceTerminator(left)
            let rightCapitalized = right.first(where: { $0.isLetter })?.isUppercase == true
            guard leftTerminated || rightCapitalized else { continue }
            let length = chunks[i].samples.count
            // Знаки в последние 1,5 с куска — это и есть проверяемый стык.
            let sentenceStart = ends.last(where: { $0 < length - 3 * sr / 2 }) ?? 0
            let seam = chunkStart + length
            let maxWindow = windowSamples - sr
            var lo = chunkStart + sentenceStart
            var hi = min(audio.count, seam + 6 * sr)
            if hi - lo > maxWindow { hi = max(min(audio.count, seam + 3 * sr), lo + maxWindow) }
            if hi - lo > maxWindow { lo = hi - maxWindow }
            guard let context = try? await decode(Array(audio[lo..<hi]), models: models) else { continue }
            let seamText = "«…\(left.split(separator: " ").suffix(2).joined(separator: " ")) | "
                + "\(right.split(separator: " ").prefix(2).joined(separator: " "))…»"
            switch Transcriber.reconcileSeam(left: left, right: right, context: context) {
            case .unmatched:
                DebugLog.log("GigaAM: стык \(i + 1) \(seamText) — в контексте не найден, без изменений")
            case .boundary:
                if leftTerminated { pauses[i] = true }
                DebugLog.log("GigaAM: стык \(i + 1) \(seamText) — граница подтверждена")
            case .continuation(let newLeft, let newRight, let removedQuestion):
                texts[i] = newLeft
                texts[i + 1] = newRight
                pauses[i] = true
                if removedQuestion { carryQuestion = true }
                DebugLog.log("GigaAM: стык \(i + 1) \(seamText) — ложная граница, знак убран")
            }
        }
        if carryQuestion, let last = texts.lastIndex(where: { $0 != nil }), let t = texts[last] {
            texts[last] = t.trimmingCharacters(in: .whitespaces) + "?"
        }
        return texts.indices.compactMap { i in texts[i].map { ($0, pauses[i]) } }
    }

    /// Служебные прогоны (контекст стыка, живой предпросмотр) — жадным декодом: там нужен
    /// знак на стыке или черновик, а точный поиск втрое дороже.
    private func decode(_ samples: [Float], models: RNNTModels) async throws -> String {
        try await decodeDetailed(samples, models: models, precise: false).text
    }

    private final class SentenceEnds: @unchecked Sendable { var samples: [Int] = [] }

    /// Ширина поиска (1 — жадный декод) и прибавка за токен подсказанного термина
    /// (0 — без подсказок). Окружение перекрывает настройки — для сравнительных замеров.
    private var searchConfig: (beam: Int, hotwordBonus: Double) {
        let env = ProcessInfo.processInfo.environment
        let settings = AppSettings.shared
        let beam = env["VOICEVOICE_GIGAAM_BEAM"].flatMap(Int.init) ?? settings.gigaamBeamSize
        let bonus = env["VOICEVOICE_GIGAAM_HOTWORDS"].flatMap(Double.init)
            ?? (settings.gigaamHotwords ? Self.defaultHotwordBonus : 0)
        return (max(1, beam), max(0, bonus))
    }
    static let defaultHotwordBonus = 1.5

    /// Термины для подсказки — правые части словаря правок (то, как слово должно быть
    /// написано), но только несклоняемые на практике: латиница (Claude, API, DBS),
    /// аббревиатуры (ФБС, СДЭК, ЭДО) и названия с заглавной. Обычное слово подсказка
    /// тянет в точную форму: на проверке «на дашборде» стало «на дашборд».
    private func buildHotwords(bonus: Double) -> HotwordGraph? {
        guard bonus > 0, let segmenter else { return nil }
        let graph = HotwordGraph(bonus: bonus)
        var seen = Set<String>()
        for entry in CorrectionStore.shared.allOrdered() {
            let phrase = entry.right.trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted)
            guard !phrase.isEmpty, phrase.count <= 40, Self.isHotwordCandidate(phrase),
                  seen.insert(phrase).inserted else { continue }
            if let ids = segmenter.encode(phrase), ids.count <= 10 { graph.insert(ids) }
        }
        return graph.count > 0 ? graph : nil
    }

    /// Оценки кусков из ресурсов приложения — для модели, скачанной до того, как они
    /// появились в её словаре. Берутся, только если куски совпадают один в один.
    private static func bundledPieceScores(for vocab: [String]) -> [Double] {
        struct Pieces: Decodable { let vocab: [String]; let scores: [Double] }
        guard let url = Bundle.module.url(forResource: "gigaam_rnnt_pieces", withExtension: "json", subdirectory: "GigaAM"),
              let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Pieces.self, from: data), p.vocab == vocab else { return [] }
        return p.scores
    }

    nonisolated static func isHotwordCandidate(_ phrase: String) -> Bool {
        let letters = phrase.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if letters.contains(where: { $0.isASCII }) { return true }
        if letters.filter(\.isUppercase).count >= 2 { return true }
        return letters.first?.isUppercase == true
    }

    /// Один прогон окна: паддинг → энкодер (ANE) → жадный RNNT-цикл (CPU): на каждом
    /// кадре joint выбирает токен с учётом состояния декодера; blank двигает кадр,
    /// не-blank дописывается в гипотезу и прокручивает декодер. Весь цикл — одним
    /// куском на фоновой очереди (сотни мелких predict; MLModel потокобезопасен).
    /// Кроме текста — позиции (в сэмплах от начала окна) токенов «. ? ! …»: по ним
    /// стык находит начало последнего предложения куска.
    private func decodeDetailed(_ samples: [Float], models: RNNTModels, precise: Bool) async throws -> (text: String, sentenceEnds: [Int]) {
        guard samples.count >= Int(AudioRecorder.targetSampleRate * 0.25) else { return ("", []) }
        let window = windowSamples
        var padded = [Float](repeating: 0, count: window)
        let n = min(samples.count, window)
        padded.replaceSubrange(0..<n, with: samples[0..<n])

        let wavArray = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
        padded.withUnsafeBufferPointer { src in
            wavArray.dataPointer.bindMemory(to: Float.self, capacity: window)
                .update(from: src.baseAddress!, count: window)
        }

        let vocab = self.vocab
        let blank = self.blankId
        let maxSym = self.maxSymbolsPerFrame
        let config = precise ? searchConfig : (beam: 1, hotwordBonus: 0)
        let hotwords = buildHotwords(bonus: config.hotwordBonus)
        let layers = self.predLayers
        let hidden = self.predHidden

        let ends = SentenceEnds()
        let raw: String = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // ── Энкодер: waveform → encoded [1, T, D] ────────────────────
                    // Модель с окном 25 с принимает ещё и длину речи: добитая до окна
                    // тишина маскируется, как в оригинале (иначе 3 с речи + 22 с нулей
                    // сбивали знаки и нормализацию чисел). Старая 15-секундная — без неё.
                    var feed: [String: Any] = ["waveform": wavArray]
                    if models.encoder.modelDescription.inputDescriptionsByName["length"] != nil {
                        let len = try MLMultiArray(shape: [1], dataType: .int32)
                        len[0] = NSNumber(value: n)
                        feed["length"] = len
                    }
                    let encOut = try models.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: feed))
                    guard let encoded = encOut.featureValue(for: "encoded")?.multiArrayValue else {
                        DebugLog.log("GigaAM: encoder output 'encoded' missing; features=\(encOut.featureNames)")
                        cont.resume(returning: ""); return
                    }
                    let totalFrames = encoded.shape[1].intValue
                    let dim = encoded.shape[2].intValue
                    // Кадры речи; хвост после них — маска, декодировать нечего.
                    var speechFrames = totalFrames
                    if let lenOut = encOut.featureValue(for: "encoded_length")?.multiArrayValue, lenOut.count > 0 {
                        let v: Int
                        switch lenOut.dataType {
                        case .int32: v = Int(lenOut.dataPointer.bindMemory(to: Int32.self, capacity: 1)[0])
                        case .float16: v = Int(Float(lenOut.dataPointer.bindMemory(to: Float16.self, capacity: 1)[0]))
                        case .float32: v = Int(lenOut.dataPointer.bindMemory(to: Float.self, capacity: 1)[0])
                        default: v = lenOut[0].intValue
                        }
                        speechFrames = max(0, min(totalFrames, v))
                    }
                    // ANE отдаёт Float16 — читаем строго по фактическому типу.
                    let encScalars: [Float]
                    switch encoded.dataType {
                    case .float32:
                        encScalars = MLShapedArray<Float>(encoded).scalars
                    case .float16:
                        if #available(macOS 15.0, *) {
                            encScalars = MLShapedArray<Float16>(encoded).scalars.map(Float.init)
                        } else {
                            var tmp = [Float](repeating: 0, count: totalFrames * dim)
                            for i in 0..<tmp.count { tmp[i] = encoded[i].floatValue }
                            encScalars = tmp
                        }
                    default:
                        cont.resume(returning: ""); return
                    }

                    if config.beam > 1 || hotwords != nil {
                        let text = try Self.beamDecode(models: models, encScalars: encScalars, dim: dim,
                                                       frames: speechFrames, blank: blank, vocab: vocab,
                                                       layers: layers, hidden: hidden, beam: config.beam,
                                                       hotwords: hotwords) { t in
                            ends.samples.append(t * window / totalFrames)
                        }
                        cont.resume(returning: text); return
                    }
                    // ── Буферы цикла (переиспользуются между вызовами) ───────────
                    let encFrame = try MLMultiArray(shape: [1, 1, NSNumber(value: dim)], dataType: .float32)
                    let token = try MLMultiArray(shape: [1, 1], dataType: .int32)
                    var h = try MLMultiArray(shape: [NSNumber(value: layers), 1, NSNumber(value: hidden)], dataType: .float32)
                    var c = try MLMultiArray(shape: [NSNumber(value: layers), 1, NSNumber(value: hidden)], dataType: .float32)
                    // MLMultiArray НЕ гарантирует нулевую инициализацию — зануляем.
                    memset(h.dataPointer, 0, layers * hidden * MemoryLayout<Float>.size)
                    memset(c.dataPointer, 0, layers * hidden * MemoryLayout<Float>.size)

                    var decOut: MLMultiArray!
                    func decoderStep(_ tok: Int) throws {
                        token[0] = NSNumber(value: tok)
                        let out = try models.decoder.prediction(
                            from: MLDictionaryFeatureProvider(dictionary: ["token": token, "h_in": h, "c_in": c]))
                        guard let d = out.featureValue(for: "dec_out")?.multiArrayValue,
                              let ho = out.featureValue(for: "h_out")?.multiArrayValue,
                              let co = out.featureValue(for: "c_out")?.multiArrayValue else {
                            throw Err(m: "decoder returned no outputs")
                        }
                        decOut = d; h = ho; c = co
                    }
                    // Свежий старт: embed(blank) = 0 (padding_idx) при нулевых
                    // состояниях — эквивалент predict(None) в оригинале.
                    try decoderStep(blank)

                    let framePtr = encFrame.dataPointer.bindMemory(to: Float.self, capacity: dim)
                    var pieces: [String] = []
                    for t in 0..<speechFrames {
                        let base = t * dim
                        encScalars.withUnsafeBufferPointer { src in
                            framePtr.update(from: src.baseAddress! + base, count: dim)
                        }
                        var emitted = 0
                        while emitted < maxSym {
                            let jOut = try models.joint.prediction(
                                from: MLDictionaryFeatureProvider(dictionary: ["enc_frame": encFrame, "dec_out": decOut!]))
                            guard let lp = jOut.featureValue(for: "log_probs")?.multiArrayValue,
                                  let best = Self.argmaxIndex(lp) else {
                                DebugLog.log("GigaAM: joint output unreadable (dtype=\(String(describing: jOut.featureValue(for: "log_probs")?.multiArrayValue?.dataType.rawValue)))")
                                break
                            }
                            if best == blank { break }
                            if best < vocab.count {
                                pieces.append(vocab[best])
                                if vocab[best].contains(where: { ".?!…".contains($0) }) {
                                    ends.samples.append(t * window / totalFrames)
                                }
                            }
                            try decoderStep(best)
                            emitted += 1
                        }
                    }
                    cont.resume(returning: pieces.joined()
                        .replacingOccurrences(of: "▁", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return (Self.dropInconsistentBoundaries(Self.stripUnitTails(raw)), ends.samples)
    }

    /// Поиск по нескольким вариантам (RNNTBeamSearch) поверх тех же сетей. Состояния
    /// декодера копируются в массивы: гипотез несколько, а выходы Core ML — общие буферы.
    nonisolated private static func beamDecode(models: RNNTModels, encScalars: [Float], dim: Int, frames: Int,
                                               blank: Int, vocab: [String], layers: Int, hidden: Int,
                                               beam: Int, hotwords: HotwordGraph?,
                                               sentenceEnd: (Int) -> Void) throws -> String {
        let encFrame = try MLMultiArray(shape: [1, 1, NSNumber(value: dim)], dataType: .float32)
        let framePtr = encFrame.dataPointer.bindMemory(to: Float.self, capacity: dim)
        let token = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let hIn = try MLMultiArray(shape: [NSNumber(value: layers), 1, NSNumber(value: hidden)], dataType: .float32)
        let cIn = try MLMultiArray(shape: [NSNumber(value: layers), 1, NSNumber(value: hidden)], dataType: .float32)
        var decIn: MLMultiArray?

        func floats(_ a: MLMultiArray) -> [Float] {
            switch a.dataType {
            case .float16:
                let p = a.dataPointer.bindMemory(to: Float16.self, capacity: a.count)
                return (0..<a.count).map { Float(p[$0]) }
            case .double:
                let p = a.dataPointer.bindMemory(to: Double.self, capacity: a.count)
                return (0..<a.count).map { Float(p[$0]) }
            default:
                return Array(UnsafeBufferPointer(start: a.dataPointer.bindMemory(to: Float.self, capacity: a.count), count: a.count))
            }
        }
        func fill(_ a: MLMultiArray, _ v: [Float]) {
            v.withUnsafeBufferPointer { a.dataPointer.bindMemory(to: Float.self, capacity: v.count).update(from: $0.baseAddress!, count: v.count) }
        }
        func step(_ tok: Int, _ st: RNNTBeamSearch.DecoderState) throws -> RNNTBeamSearch.DecoderState {
            token[0] = NSNumber(value: tok)
            fill(hIn, st.h); fill(cIn, st.c)
            let out = try models.decoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["token": token, "h_in": hIn, "c_in": cIn]))
            guard let d = out.featureValue(for: "dec_out")?.multiArrayValue,
                  let ho = out.featureValue(for: "h_out")?.multiArrayValue,
                  let co = out.featureValue(for: "c_out")?.multiArrayValue else {
                throw Err(m: "decoder returned no outputs")
            }
            if decIn == nil { decIn = try MLMultiArray(shape: d.shape, dataType: .float32) }
            return .init(decOut: floats(d), h: floats(ho), c: floats(co))
        }
        let zeros = [Float](repeating: 0, count: layers * hidden)
        let initial = try step(blank, .init(decOut: [], h: zeros, c: zeros))
        let result = try RNNTBeamSearch.decode(
            frames: frames, blank: blank, beamSize: beam, initial: initial, hotwords: hotwords,
            joint: { t, decOut in
                encScalars.withUnsafeBufferPointer { framePtr.update(from: $0.baseAddress! + t * dim, count: dim) }
                fill(decIn!, decOut)
                let j = try models.joint.prediction(
                    from: MLDictionaryFeatureProvider(dictionary: ["enc_frame": encFrame, "dec_out": decIn!]))
                guard let lp = j.featureValue(for: "log_probs")?.multiArrayValue else { throw Err(m: "joint returned no output") }
                return floats(lp)
            },
            decoderStep: step)
        var pieces: [String] = []
        for (tok, t) in zip(result.tokens, result.frames) where tok < vocab.count {
            pieces.append(vocab[tok])
            if vocab[tok].contains(where: { ".?!…".contains($0) }) { sentenceEnd(t) }
        }
        return pieces.joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Output post-fixes

    /// Argmax по вектору логитов с учётом фактического типа массива — CoreML на
    /// разных compute units отдаёт то Float32, то Float16 (arm64-only приложение,
    /// Float16 читается напрямую).
    private static func argmaxIndex(_ arr: MLMultiArray) -> Int? {
        let count = arr.count
        guard count > 0 else { return nil }
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
            var best = 0
            var bestVal = -Float.greatestFiniteMagnitude
            for k in 0..<count where p[k] > bestVal { bestVal = p[k]; best = k }
            return best
        case .float16:
            let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: count)
            var best = 0
            var bestVal = Float16(-Float16.greatestFiniteMagnitude)
            for k in 0..<count where p[k] > bestVal { bestVal = p[k]; best = k }
            return best
        case .double:
            let p = arr.dataPointer.bindMemory(to: Double.self, capacity: count)
            var best = 0
            var bestVal = -Double.greatestFiniteMagnitude
            for k in 0..<count where p[k] > bestVal { bestVal = p[k]; best = k }
            return best
        default:
            return nil
        }
    }

    /// GigaAM иногда ставит точку, не подняв заглавную следующего слова
    /// («Маркета. при запросе») — противоречивая граница, слабый сигнал модели
    /// (правило обкатано на RUPunct: настоящая граница = точка + заглавная).
    /// Точку перед строчной буквой убираем; «?»/«!» не трогаем.
    static func dropInconsistentBoundaries(_ s: String) -> String {
        var words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 1 else { return s }
        for i in 0..<(words.count - 1) {
            let w = words[i]
            guard w.count >= 2, w.hasSuffix(".") || w.hasSuffix("…") else { continue }
            guard let next = words[i + 1].first, next.isLetter, next.isLowercase else { continue }
            var trimmed = w
            while trimmed.hasSuffix(".") || trimmed.hasSuffix("…") { trimmed.removeLast() }
            if !trimmed.isEmpty { words[i] = trimmed }
        }
        return words.joined(separator: " ")
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
            guard case .ready = state, let models else { continue }

            let snap = samples()
            guard snap.count - previewCommittedOffset >= Int(AudioRecorder.targetSampleRate * 0.6) else { continue }
            let fresh = Array(snap[previewCommittedOffset...])
            let chunks = Transcriber.chunkBySilence(fresh, windowSeconds: windowSamples / Int(AudioRecorder.targetSampleRate))
            guard !chunks.isEmpty else { continue }
            for ch in chunks.dropLast() {
                if Task.isCancelled { return }
                let t = (try? await decode(ch.samples, models: models)) ?? ""
                if !t.isEmpty { previewPieces.append(t) }
                previewCommittedOffset += ch.samples.count
            }
            if Task.isCancelled { return }
            let tailText = (try? await decode(chunks[chunks.count - 1].samples, models: models)) ?? ""
            if Task.isCancelled { return }
            let joined = (previewPieces + [tailText]).filter { !$0.isEmpty }.joined(separator: " ")
            if !joined.isEmpty { livePreviewText = joined }
        }
    }
}
