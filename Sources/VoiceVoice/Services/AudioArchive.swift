import Foundation

/// Архив аудио диктовок для проверки качества распознавания (opt-in, по умолчанию
/// выключен). Без записей сравнить движки и настройки можно только на синтезированном
/// голосе, а он чище живой речи. Файлы называются по id записи истории:
/// `recordings/<id>.wav` (16 кГц моно 16 бит) и `<id>.json` — сырой текст движка и
/// итоговый текст (обновляется, когда пользователь правит запись в истории: это и есть
/// эталон). Текст дублируется рядом, потому что история обрезается до 200 записей.
/// Хранится только на этом Mac, старше `retentionDays` удаляется.
enum AudioArchive {
    static let retentionDays = 14

    static var directory: URL {
        AppPaths.appSupportDir.appendingPathComponent("recordings", isDirectory: true)
    }

    static func url(forHistoryId id: Int64) -> URL {
        directory.appendingPathComponent("\(id).wav")
    }

    private static func textURL(forHistoryId id: Int64) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// Пишет в фоне, чтобы не задерживать вставку текста.
    static func save(_ samples: [Float], historyId: Int64, engineText: String, finalText: String) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try wavData(samples).write(to: url(forHistoryId: historyId), options: .atomic)
                let meta: [String: Any] = ["engineText": engineText, "finalText": finalText,
                                           "createdAt": ISO8601DateFormatter().string(from: Date())]
                try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
                    .write(to: textURL(forHistoryId: historyId), options: .atomic)
                prune()
            } catch {
                DebugLog.log("AudioArchive: save FAILED — \(error.localizedDescription)")
            }
        }
    }

    /// Правка записи в истории — это эталон для проверки: переносим её в архив.
    static func updateFinalText(_ finalText: String, historyId: Int64) {
        let u = textURL(forHistoryId: historyId)
        guard let data = try? Data(contentsOf: u),
              var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        meta["finalText"] = finalText
        meta["editedByUser"] = true
        try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: u, options: .atomic)
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for f in files where ["wav", "json"].contains(f.pathExtension) {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if date < cutoff { try? fm.removeItem(at: f) }
        }
    }

    private static func wavData(_ samples: [Float]) -> Data {
        let sampleRate = UInt32(AudioRecorder.targetSampleRate)
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
