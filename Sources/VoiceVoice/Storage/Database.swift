import Foundation
import GRDB

enum AppPaths {
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("VoiceVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var databaseURL: URL { appSupportDir.appendingPathComponent("data.db") }
    static var modelsDir: URL {
        let dir = appSupportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

final class Database {
    static let shared = Database()
    let queue: DatabaseQueue

    private init() {
        do {
            queue = try DatabaseQueue(path: AppPaths.databaseURL.path)
            try migrate()
        } catch {
            fatalError("Cannot open SQLite at \(AppPaths.databaseURL.path): \(error)")
        }
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "corrections") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("wrong", .text).notNull().indexed()
                t.column("right", .text).notNull()
                t.column("contextBefore", .text)
                t.column("confirmedCount", .integer).notNull().defaults(to: 1)
                t.column("rejectedCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.uniqueKey(["wrong", "contextBefore"])
            }
            try db.create(table: "transcriptions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rawText", .text).notNull()
                t.column("appliedText", .text).notNull()
                t.column("finalText", .text).notNull()
                t.column("durationSeconds", .double).notNull().defaults(to: 0)
                t.column("processingMs", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }
        try migrator.migrate(queue)
    }
}

extension CorrectionEntry: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "corrections"
    enum Columns {
        static let id = Column("id")
        static let wrong = Column("wrong")
        static let right = Column("right")
        static let contextBefore = Column("contextBefore")
        static let confirmedCount = Column("confirmedCount")
        static let rejectedCount = Column("rejectedCount")
        static let createdAt = Column("createdAt")
        static let lastUsedAt = Column("lastUsedAt")
    }
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension TranscriptionRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcriptions"
    enum Columns {
        static let id = Column("id")
        static let rawText = Column("rawText")
        static let appliedText = Column("appliedText")
        static let finalText = Column("finalText")
        static let durationSeconds = Column("durationSeconds")
        static let processingMs = Column("processingMs")
        static let createdAt = Column("createdAt")
    }
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
