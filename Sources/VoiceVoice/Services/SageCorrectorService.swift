import Foundation
import CoreML
import Combine
import CryptoKit
import Tokenizers

/// Нейро-исправление ошибок распознавания: sage-fredt5-distilled-95m (SberDevices,
/// MIT) — русская seq2seq-модель (T5, 95M), исправляющая орфографию, пунктуацию и
/// регистр одним проходом. Обучена в т.ч. на транскриптах видео — то есть на
/// ошибках, похожих на ASR-ные («лижат» → «лежат», «такйо» → «такой»).
///
/// Две Core ML-сети (конвертация: `.mltools/convert_sage.py`, валидация против
/// PyTorch-эталона 6/6) в `~/Library/Application Support/VoiceVoice/models/Sage/`:
///   • encoder: (input_ids [1×S], pos_bias [1×6×S×S]) → enc_hidden [1×S×512];
///   • decoder: (dec_ids [1×T], enc_hidden, self_bias [1×6×T×T], cross_bias
///     [1×6×T×S]) → logits [1×50364] последней позиции; жадный цикл на Swift.
///
/// T5 relative position bias подаётся ВХОДОМ (таблицы 32×6 в sage_meta.json,
/// бакетизация здесь) — иначе trace запекает длину примера и гибкие размеры
/// тихо ломаются. Каузальная маска декодера вшита в self_bias (−1e4).
///
/// ⚠️ Compute units ТОЛЬКО .cpuAndGPU: у fp16-энкодера на .cpuOnly накапливается
/// ошибка (max|Δ|=0.35 — активации T5 большие) и на выходе мусор из <pad>.
/// ANE (.all) не нужен: гибкие размеры вызывают перекомпиляцию на каждую длину.
///
/// Правки seq2seq-модели проверяются диф-гардом: если буквенное расстояние
/// Левенштейна больше трети длины (или длина уплыла) — чанк остаётся как был.
/// ЛЮБАЯ ошибка на любом этапе — фолбэк на исходный текст.
@MainActor
final class SageCorrectorService: ObservableObject {
    static let shared = SageCorrectorService()

    @Published private(set) var state: Transcriber.ModelState = .notLoaded
    @Published private(set) var lastProcessingMs: Int = 0

    private var encoder: MLModel?
    private var decoder: MLModel?
    private var tokenizer: (any Tokenizers.Tokenizer)?
    private var meta: Meta?
    private var loadingTask: Task<Void, Never>?

    private init() {}

    static var modelDir: URL {
        AppPaths.appSupportDir.appendingPathComponent("models/Sage")
    }

    /// Модель установлена локально (проверка для UI настроек).
    static var isModelInstalled: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("SageCorrector_encoder.mlpackage").path)
    }

    // Модели хостятся ассетами отдельного GitHub-релиза (тег живёт независимо от
    // релизов кода) и скачиваются при первом включении тумблера в настройках.
    private static let downloadBase = "https://github.com/sergekruf/voicevoice/releases/download/sage-corrector-coreml/"
    private static let metaName = "sage_meta.json"
    /// (имя zip-архива без расширения, SHA256 zip-архива)
    private static let modelParts: [(name: String, sha256: String)] = [
        ("SageCorrector_encoder.mlpackage", "2901c3972d628444027ba1e9a9371dad6bce0a6eadaf6253a7fa97bed0c4ab09"),
        ("SageCorrector_decoder.mlpackage", "8c74573f9bcb5a9c503dc3d724725c1b76145dc539bcfacaad2d36f0a1da07b1"),
        ("tokenizer", "0566aabc4761051ae83c422734fb9d86b9ef836d2a48e970a28f782cd1728f63"),
    ]

    /// Слов в одном чанке инференса. Предложения группируются до этого лимита;
    /// 45 слов ≈ 120–140 BPE-токенов — с запасом до RangeDim-потолка 384.
    private let maxChunkWords = 45

    private struct Err: LocalizedError { let m: String; var errorDescription: String? { m } }

    private struct Meta: Decodable {
        let d_model: Int
        let n_heads: Int
        let num_buckets: Int
        let max_distance: Int
        let neg_inf: Float
        let bos_id: Int
        let eos_id: Int
        let pad_id: Int
        let decoder_start_id: Int
        let max_len: Int
        let enc_bias_table: [[Float]]   // (32, heads)
        let dec_bias_table: [[Float]]
        let probe_text: String
        let probe_ids: [Int]
    }

    func ensureLoaded() {
        if case .ready = state { return }
        if loadingTask != nil { return }
        loadingTask = Task { await load() }
    }

    func reload() {
        encoder = nil
        decoder = nil
        tokenizer = nil
        meta = nil
        state = .notLoaded
        loadingTask?.cancel()
        loadingTask = nil
        ensureLoaded()
    }

    private func load() async {
        state = .loading
        DebugLog.log("Sage: load() begin")
        do {
            let dir = Self.modelDir
            let metaURL = dir.appendingPathComponent(Self.metaName)
            let missing = Self.modelParts.contains {
                !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.name).path)
            } || !FileManager.default.fileExists(atPath: metaURL.path)
            if missing {
                try await downloadModel(to: dir)
                state = .loading
            }

            let m = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL))
            let tok = try await AutoTokenizer.from(modelFolder: dir.appendingPathComponent("tokenizer"))

            // Паритет токенизации Swift vs HF: если swift-transformers токенизирует
            // хоть чуть иначе, модель получит чужие ids — лучше честно отключиться.
            let probe = tok.encode(text: m.probe_text)
            guard probe == m.probe_ids else {
                throw Err(m: "tokenizer parity failed: \(probe.prefix(8)) vs \(m.probe_ids.prefix(8))")
            }

            encoder = try await Self.compileAndLoad(
                pkg: dir.appendingPathComponent("SageCorrector_encoder.mlpackage"), units: .cpuAndGPU)
            decoder = try await Self.compileAndLoad(
                pkg: dir.appendingPathComponent("SageCorrector_decoder.mlpackage"), units: .cpuAndGPU)
            tokenizer = tok
            meta = m
            state = .ready
            DebugLog.log("Sage: state=ready (heads=\(m.n_heads), maxLen=\(m.max_len))")
            // Прогрев: самые первые predict'ы компилируют Metal-пайплайны (до ~10 с
            // на первом запуске после установки). Холостой прогон сразу после
            // загрузки — чтобы эту цену не платила первая диктовка.
            Task { [weak self] in
                let t0 = Date()
                _ = await self?.correct("прогрев модели после загрузки")
                DebugLog.log("Sage: warm-up done in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
        } catch {
            DebugLog.log("Sage: load FAILED — \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
        loadingTask = nil
    }

    /// Компиляция .mlpackage → .mlmodelc (кэш рядом с моделью) + загрузка.
    private static func compileAndLoad(pkg: URL, units: MLComputeUnits) async throws -> MLModel {
        let cached = pkg.deletingPathExtension().appendingPathExtension("mlmodelc")
        if !FileManager.default.fileExists(atPath: cached.path) {
            DebugLog.log("Sage: compiling \(pkg.lastPathComponent)…")
            let tmp = try await MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.copyItem(at: tmp, to: cached)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try MLModel(contentsOf: cached, configuration: cfg)
    }

    // MARK: - Download

    /// Скачивает модели (~230 МБ, с прогрессом в `state`) и мету с GitHub-релиза,
    /// проверяет SHA256 и распаковывает в `modelDir`. Схема — как у GigaAM.
    private func downloadModel(to dir: URL) async throws {
        DebugLog.log("Sage: downloading model from GitHub release…")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let metaRemote = URL(string: Self.downloadBase + Self.metaName) else {
            throw Err(m: "bad model URL")
        }
        let (metaData, metaResp) = try await URLSession.shared.data(from: metaRemote)
        guard (metaResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Err(m: "Не удалось скачать мету модели (нет сети?)")
        }

        for part in Self.modelParts {
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(part.name).path) else { continue }
            guard let zipRemote = URL(string: Self.downloadBase + part.name + ".zip") else {
                throw Err(m: "bad model URL")
            }
            let tmpZip = try await downloadWithProgress(zipRemote)
            defer { try? FileManager.default.removeItem(at: tmpZip) }

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let hash = try Self.sha256Hex(of: tmpZip)
                        guard hash == part.sha256 else {
                            throw Err(m: "Контрольная сумма \(part.name) не совпала — попробуйте ещё раз")
                        }
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        proc.arguments = ["-x", "-k", tmpZip.path, dir.path]
                        try proc.run()
                        proc.waitUntilExit()
                        guard proc.terminationStatus == 0 else {
                            throw Err(m: "Не удалось распаковать \(part.name)")
                        }
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        try metaData.write(to: dir.appendingPathComponent(Self.metaName))
        DebugLog.log("Sage: models downloaded and verified")
    }

    private func downloadWithProgress(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
                if let err { cont.resume(throwing: err); return }
                guard let tmp, let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    cont.resume(throwing: Err(m: "Не удалось скачать модель (HTTP-ошибка)"))
                    return
                }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sage-\(UUID().uuidString).zip")
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

    // MARK: - Correction

    /// Исправляет ошибки в тексте. Возвращает вход без изменений при любой проблеме.
    /// Если модель ещё качается — НЕ ждёт (загрузка минуты), просто пропускает.
    func correct(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        ensureLoaded()
        // Компиляция/загрузка — секунды, ждём; скачивание — нет.
        let waitStart = Date()
        while true {
            switch state {
            case .ready: break
            case .downloading:
                DebugLog.log("Sage: model is downloading — skipping correction")
                return text
            case .error(let m):
                DebugLog.log("Sage: not correcting (error: \(m))")
                return text
            default:
                if Date().timeIntervalSince(waitStart) > 25 {
                    DebugLog.log("Sage: load wait timed out — skipping correction")
                    return text
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            break
        }
        guard let encoder, let decoder, let tokenizer, let meta else { return text }

        let start = Date()
        var pieces: [String] = []
        for chunk in Self.splitChunks(trimmed, maxWords: maxChunkWords) {
            if Task.isCancelled { return text }
            let corrected = await inferChunk(
                chunk, encoder: encoder, decoder: decoder, tokenizer: tokenizer, meta: meta)
            pieces.append(Self.acceptable(original: chunk, corrected: corrected) ? corrected! : chunk)
        }
        lastProcessingMs = Int(Date().timeIntervalSince(start) * 1000)
        let result = pieces.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        DebugLog.log("Sage: corrected in \(lastProcessingMs)ms, chunks=\(pieces.count), len \(trimmed.count)→\(result.count)")
        return result.isEmpty ? text : result
    }

    // MARK: - Chunking

    /// Режет текст на чанки: по границам предложений (терминатор + пробел/конец,
    /// чтобы не разрезать «12.30»), группируя до maxWords; предложение длиннее
    /// лимита режется по словам. Для текста вовсе без знаков — просто по словам.
    static func splitChunks(_ text: String, maxWords: Int) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            if ".!?…".contains(ch) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next == " " || next == "\n" {
                    let s = current.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { sentences.append(s) }
                    current = ""
                }
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        var chunks: [String] = []
        var acc: [String] = []
        var accWords = 0
        func flush() {
            if !acc.isEmpty { chunks.append(acc.joined(separator: " ")); acc = []; accWords = 0 }
        }
        for s in sentences {
            let words = s.split(separator: " ")
            if words.count > maxWords {
                flush()
                // сверхдлинное «предложение» (обычно текст без пунктуации) — по словам
                var i = 0
                while i < words.count {
                    let end = min(i + maxWords, words.count)
                    chunks.append(words[i..<end].joined(separator: " "))
                    i = end
                }
                continue
            }
            if accWords + words.count > maxWords { flush() }
            acc.append(s)
            accWords += words.count
        }
        flush()
        return chunks
    }

    /// Знаки, которых нет в BPE-словаре Sage осмысленным токеном: модель кодирует
    /// их байт-фолбэком и на генерации «исправляет» в мусор («380 ₽» → «380 $*»,
    /// «$$», «$$^» — наблюдалось вживую). GigaAM же выдаёт ₽ корректно.
    /// «*» и «^» тоже здесь: в словаре GigaAM их нет вовсе — в оригинале они
    /// не встречаются, а в правке могут быть только мусором генерации.
    private static let protectedSigns: Set<Character> = ["₽", "€", "$", "%", "№", "*", "^"]

    /// Диф-гард: seq2seq теоретически может переписать текст — принимаем правку,
    /// только если буквенно-цифровое ядро изменилось умеренно (опечатки), а не
    /// переписано/оборвано (галлюцинация).
    static func acceptable(original: String, corrected: String?) -> Bool {
        guard let corrected, !corrected.isEmpty else { return false }
        // Валютные и специальные знаки должны пережить правку один-в-один:
        // потерялся или появился ₽/€/$/%/№ — вся правка чанка отклоняется.
        let signsA = original.filter { protectedSigns.contains($0) }.sorted()
        let signsB = corrected.filter { protectedSigns.contains($0) }.sorted()
        guard signsA == signsB else { return false }
        let a = lettersDigits(original)
        let b = lettersDigits(corrected)
        guard !a.isEmpty, !b.isEmpty else { return false }
        guard b.count * 3 >= a.count * 2, b.count * 2 <= a.count * 3 else { return false }
        let dist = a.levenshteinDistance(to: b)
        return dist <= max(2, a.count / 3)
    }

    private static func lettersDigits(_ s: String) -> String {
        String(s.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Inference

    /// Один чанк: токенизация → энкодер → жадный авторегрессионный цикл декодера.
    /// nil при любой ошибке (вызывающий оставит исходный чанк).
    private func inferChunk(
        _ chunk: String, encoder: MLModel, decoder: MLModel,
        tokenizer: any Tokenizers.Tokenizer, meta: Meta
    ) async -> String? {
        let ids = tokenizer.encode(text: chunk)
        let s = ids.count
        // потолок RangeDim с запасом на генерацию (T ≤ 1.5×S тоже должен влезть)
        guard s > 0, s <= 240 else { return nil }

        let out: [Int]? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let encBias = Self.makeBias(
                        table: meta.enc_bias_table, q: s, k: s,
                        bidirectional: true, causal: false, meta: meta)
                    let inputIds = try Self.int32Array(ids)
                    let encOut = try encoder.prediction(from: MLDictionaryFeatureProvider(
                        dictionary: ["input_ids": inputIds, "pos_bias": encBias]))
                    guard let encHiddenRaw = encOut.featureValue(for: "enc_hidden")?.multiArrayValue else {
                        cont.resume(returning: nil); return
                    }
                    // Выход может прийти Float16 — перечитываем строго по типу в fp32-вход декодера.
                    let encHidden = try Self.toFloat32(encHiddenRaw)

                    var hyp: [Int] = [meta.decoder_start_id]
                    let maxSteps = min(s * 3 / 2 + 2, meta.max_len - 4)
                    for _ in 0..<maxSteps {
                        let t = hyp.count
                        let selfBias = Self.makeBias(
                            table: meta.dec_bias_table, q: t, k: t,
                            bidirectional: false, causal: true, meta: meta)
                        let crossBias = try MLMultiArray(
                            shape: [1, NSNumber(value: meta.n_heads), NSNumber(value: t), NSNumber(value: s)],
                            dataType: .float32)
                        memset(crossBias.dataPointer, 0, meta.n_heads * t * s * MemoryLayout<Float>.size)
                        let decOut = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                            "dec_ids": Self.int32Array(hyp),
                            "enc_hidden": encHidden,
                            "self_bias": selfBias,
                            "cross_bias": crossBias,
                        ]))
                        guard let logits = decOut.featureValue(for: "logits")?.multiArrayValue else {
                            cont.resume(returning: nil); return
                        }
                        guard let k = Self.argmax(logits) else {
                            cont.resume(returning: nil); return
                        }
                        if k == meta.eos_id { break }
                        hyp.append(k)
                    }
                    cont.resume(returning: hyp)
                } catch {
                    DebugLog.log("Sage: inferChunk FAILED — \(error.localizedDescription)")
                    cont.resume(returning: nil)
                }
            }
        }

        guard let out, out.count > 1 else { return nil }
        // страховка от спецтокенов в выводе (<pad>/<unk>/<extra_id_*> и т.п.)
        let clean = out.dropFirst().filter { $0 > 4 && $0 < 50257 }
        guard !clean.isEmpty else { return nil }
        return tokenizer.decode(tokens: Array(clean), skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Tensor helpers

    private static func int32Array(_ ids: [Int]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        let p = arr.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
        for (i, v) in ids.enumerated() { p[i] = Int32(v) }
        return arr
    }

    /// ЛЮБОЕ чтение MLMultiArray — только через dtype-switch (fp16-ловушка).
    private static func toFloat32(_ src: MLMultiArray) throws -> MLMultiArray {
        let count = src.count
        let dst = try MLMultiArray(shape: src.shape, dataType: .float32)
        let dp = dst.dataPointer.bindMemory(to: Float.self, capacity: count)
        switch src.dataType {
        case .float32:
            let sp = src.dataPointer.bindMemory(to: Float.self, capacity: count)
            dp.update(from: sp, count: count)
        case .float16:
            if #available(macOS 15.0, *) {
                let scalars = MLShapedArray<Float16>(src).scalars
                for i in 0..<count { dp[i] = Float(scalars[i]) }
            } else {
                for i in 0..<count { dp[i] = src[i].floatValue }
            }
        default:
            throw Err(m: "unexpected dtype \(src.dataType.rawValue)")
        }
        return dst
    }

    private static func argmax(_ logits: MLMultiArray) -> Int? {
        let n = logits.count
        var best = -1
        var bestVal = -Float.greatestFiniteMagnitude
        switch logits.dataType {
        case .float32:
            let p = logits.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n where p[i] > bestVal { bestVal = p[i]; best = i }
        case .float16:
            if #available(macOS 15.0, *) {
                let scalars = MLShapedArray<Float16>(logits).scalars
                for i in 0..<n {
                    let v = Float(scalars[i])
                    if v > bestVal { bestVal = v; best = i }
                }
            } else {
                for i in 0..<n {
                    let v = logits[i].floatValue
                    if v > bestVal { bestVal = v; best = i }
                }
            }
        default:
            return nil
        }
        return best >= 0 ? best : nil
    }

    // MARK: - Position bias (T5 relative attention, эталон — convert_sage.py)

    private static func relBucket(_ rel: Int, bidirectional: Bool, numBuckets: Int, maxDistance: Int) -> Int {
        var ret = 0
        var buckets = numBuckets
        var r = rel
        if bidirectional {
            buckets /= 2
            if r > 0 { ret += buckets }
            r = abs(r)
        } else {
            r = -min(r, 0)
        }
        let maxExact = buckets / 2
        if r < maxExact { return ret + r }
        let v = maxExact + Int(
            log(Double(r) / Double(maxExact)) / log(Double(maxDistance) / Double(maxExact))
                * Double(buckets - maxExact))
        return ret + min(v, buckets - 1)
    }

    /// bias (1, heads, q, k): значение таблицы для бакета относительной позиции;
    /// для каузального (декодер) будущие позиции глушатся neg_inf.
    private static func makeBias(
        table: [[Float]], q: Int, k: Int, bidirectional: Bool, causal: Bool, meta: Meta
    ) -> MLMultiArray {
        let heads = meta.n_heads
        // shape гарантированно валиден — сбой аллокации тут практически невозможен,
        // но на всякий случай не роняем процесс.
        guard let arr = try? MLMultiArray(
            shape: [1, NSNumber(value: heads), NSNumber(value: q), NSNumber(value: k)],
            dataType: .float32) else {
            return MLMultiArray()
        }
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: heads * q * k)
        for qi in 0..<q {
            for ki in 0..<k {
                if causal && ki > qi {
                    for h in 0..<heads { p[h * q * k + qi * k + ki] = meta.neg_inf }
                } else {
                    let b = relBucket(ki - qi, bidirectional: bidirectional,
                                      numBuckets: meta.num_buckets, maxDistance: meta.max_distance)
                    let row = table[b]
                    for h in 0..<heads { p[h * q * k + qi * k + ki] = row[h] }
                }
            }
        }
        return arr
    }
}
