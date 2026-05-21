import Foundation
import GRDB

final class HistoryStore {
    static let shared = HistoryStore()

    private let db: DatabaseQueue
    private let maxEntries = 200

    private init() {
        self.db = Database.shared.queue
    }

    @discardableResult
    func add(_ record: TranscriptionRecord) -> Int64? {
        var r = record
        try? db.write { db in
            try r.insert(db)
            try TranscriptionRecord
                .order(TranscriptionRecord.Columns.createdAt.desc)
                .limit(10_000, offset: maxEntries)
                .deleteAll(db)
        }
        return r.id
    }

    func updateFinal(id: Int64, finalText: String) {
        _ = try? db.write { db in
            if var rec = try TranscriptionRecord.fetchOne(db, key: id) {
                rec.finalText = finalText
                try rec.update(db)
            }
        }
    }

    func recent(limit: Int = 50) -> [TranscriptionRecord] {
        (try? db.read { db in
            try TranscriptionRecord
                .order(TranscriptionRecord.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    struct Stats {
        var totalRecords: Int = 0
        var totalCharacters: Int = 0
        var totalSeconds: Double = 0
        var totalProcessingMs: Int = 0
        var firstAt: Date?
        var lastAt: Date?
        var averageRTF: Double {
            // realtime factor — how much faster than realtime we ran on average
            guard totalProcessingMs > 0 else { return 0 }
            return totalSeconds / (Double(totalProcessingMs) / 1000)
        }
    }

    func stats() -> Stats {
        let all = (try? db.read { db in
            try TranscriptionRecord.fetchAll(db)
        }) ?? []
        var s = Stats()
        s.totalRecords = all.count
        for r in all {
            s.totalCharacters += r.appliedText.count
            s.totalSeconds += r.durationSeconds
            s.totalProcessingMs += r.processingMs
            if s.firstAt == nil || (s.firstAt.map { r.createdAt < $0 } ?? false) {
                s.firstAt = r.createdAt
            }
            if s.lastAt == nil || (s.lastAt.map { r.createdAt > $0 } ?? false) {
                s.lastAt = r.createdAt
            }
        }
        return s
    }

    func delete(_ record: TranscriptionRecord) {
        guard let id = record.id else { return }
        _ = try? db.write { db in
            try TranscriptionRecord.deleteOne(db, key: id)
        }
    }
}
