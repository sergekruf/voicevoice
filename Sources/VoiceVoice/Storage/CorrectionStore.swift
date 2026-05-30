import Foundation
import GRDB

final class CorrectionStore {
    static let shared = CorrectionStore()

    private let db: DatabaseQueue
    private init() {
        self.db = Database.shared.queue
    }

    func allOrdered() -> [CorrectionEntry] {
        (try? db.read { db in
            try CorrectionEntry
                .order(CorrectionEntry.Columns.lastUsedAt.desc)
                .fetchAll(db)
        }) ?? []
    }

    struct Stats {
        var totalEntries: Int = 0
        var activeEntries: Int = 0    // entries that are currently auto-applied
        var totalConfirmations: Int = 0
        var totalRejections: Int = 0
    }

    func stats(minConfirmedToApply: Int) -> Stats {
        let all = allOrdered()
        var s = Stats()
        s.totalEntries = all.count
        for e in all {
            s.totalConfirmations += e.confirmedCount
            s.totalRejections += e.rejectedCount
            if e.confirmedCount >= minConfirmedToApply && e.confirmedCount > e.rejectedCount * 2 {
                s.activeEntries += 1
            }
        }
        return s
    }

    func find(wrong: String, contextBefore: String?) -> CorrectionEntry? {
        try? db.read { db in
            try CorrectionEntry
                .filter(CorrectionEntry.Columns.wrong == wrong)
                .filter(CorrectionEntry.Columns.contextBefore == contextBefore)
                .fetchOne(db)
        }
    }

    func recordConfirmation(wrong: String, right: String, contextBefore: String? = nil) {
        try? db.write { db in
            if var existing = try CorrectionEntry
                .filter(CorrectionEntry.Columns.wrong == wrong)
                .filter(CorrectionEntry.Columns.right == right)
                .filter(CorrectionEntry.Columns.contextBefore == contextBefore)
                .fetchOne(db) {
                existing.confirmedCount += 1
                existing.lastUsedAt = Date()
                try existing.update(db)
            } else {
                var entry = CorrectionEntry(
                    wrong: wrong,
                    right: right,
                    contextBefore: contextBefore,
                    confirmedCount: 1,
                    rejectedCount: 0,
                    createdAt: Date(),
                    lastUsedAt: Date()
                )
                try entry.insert(db)
            }
        }
    }

    /// Add (or reinforce) a correction the user typed in by hand. Seeds
    /// `confirmedCount` high enough (3) that it's immediately auto-applied and
    /// survives a couple of accidental rejections — the user is certain about a
    /// manual entry, unlike an auto-learned one. `wrong` is lowercased to match the
    /// applier's case-insensitive comparison.
    func addManual(wrong: String, right: String, contextBefore: String? = nil) {
        let w = wrong.lowercased()
        let ctx = (contextBefore?.isEmpty == true) ? nil : contextBefore
        try? db.write { db in
            if var existing = try CorrectionEntry
                .filter(CorrectionEntry.Columns.wrong == w)
                .filter(CorrectionEntry.Columns.right == right)
                .filter(CorrectionEntry.Columns.contextBefore == ctx)
                .fetchOne(db) {
                existing.confirmedCount = max(existing.confirmedCount + 1, 3)
                existing.lastUsedAt = Date()
                try existing.update(db)
            } else {
                var entry = CorrectionEntry(
                    wrong: w,
                    right: right,
                    contextBefore: ctx,
                    confirmedCount: 3,
                    rejectedCount: 0,
                    createdAt: Date(),
                    lastUsedAt: Date()
                )
                try entry.insert(db)
            }
        }
    }

    func recordRejection(wrong: String, right: String, contextBefore: String? = nil) {
        try? db.write { db in
            if var existing = try CorrectionEntry
                .filter(CorrectionEntry.Columns.wrong == wrong)
                .filter(CorrectionEntry.Columns.right == right)
                .filter(CorrectionEntry.Columns.contextBefore == contextBefore)
                .fetchOne(db) {
                existing.rejectedCount += 1
                existing.lastUsedAt = Date()
                try existing.update(db)
            }
        }
    }

    func delete(_ entry: CorrectionEntry) {
        guard let id = entry.id else { return }
        _ = try? db.write { db in
            try CorrectionEntry.deleteOne(db, key: id)
        }
    }

    func upsert(_ entry: CorrectionEntry) {
        var e = entry
        e.lastUsedAt = Date()
        _ = try? db.write { db in
            try e.save(db)
        }
    }

    func export() -> [CorrectionEntry] {
        allOrdered()
    }

    func importEntries(_ entries: [CorrectionEntry], merge: Bool = true) {
        try? db.write { db in
            for entry in entries {
                var e = entry
                e.id = nil
                if merge,
                   var existing = try CorrectionEntry
                    .filter(CorrectionEntry.Columns.wrong == e.wrong)
                    .filter(CorrectionEntry.Columns.right == e.right)
                    .filter(CorrectionEntry.Columns.contextBefore == e.contextBefore)
                    .fetchOne(db) {
                    existing.confirmedCount += e.confirmedCount
                    existing.rejectedCount += e.rejectedCount
                    try existing.update(db)
                } else {
                    try e.insert(db)
                }
            }
        }
    }
}
