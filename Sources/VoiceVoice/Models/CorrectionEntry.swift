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

    /// Единый предикат «запись активна» (автоприменяется) — используется применением,
    /// статистикой и бейджем в словаре. Раньше у трёх мест были три копии логики с
    /// разными порогами (бейдж врал при minConfirmedToApply=1).
    func isActive(minConfirmed: Int) -> Bool {
        confirmedCount >= minConfirmed && confirmedCount > rejectedCount * 2
    }

    var netScore: Int {
        confirmedCount - rejectedCount
    }
}
