import Foundation

struct TranscriptionRecord: Identifiable, Hashable, Codable {
    var id: Int64?
    /// Что выдал движок распознавания ДО пост-обработки (пунктуация, Sage, LLM,
    /// словарь). Пусто у записей, созданных до появления поля.
    var engineText: String = ""
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
