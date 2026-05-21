import Foundation

struct TranscriptionRecord: Identifiable, Hashable, Codable {
    var id: Int64?
    var rawText: String
    var appliedText: String
    var finalText: String
    var durationSeconds: Double
    var processingMs: Int
    var createdAt: Date

    var preview: String {
        let text = finalText.isEmpty ? appliedText : finalText
        if text.count <= 80 { return text }
        return String(text.prefix(77)) + "..."
    }
}
