import Foundation

struct CorrectionEntry: Identifiable, Hashable, Codable {
    var id: Int64?
    var wrong: String
    var right: String
    var contextBefore: String?
    var confirmedCount: Int
    var rejectedCount: Int
    var createdAt: Date
    var lastUsedAt: Date

    var isAutoApplied: Bool {
        confirmedCount >= 2 && confirmedCount > rejectedCount * 2
    }

    var netScore: Int {
        confirmedCount - rejectedCount
    }
}
