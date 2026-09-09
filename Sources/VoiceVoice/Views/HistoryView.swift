import SwiftUI

struct HistoryView: View {
    @State private var records: [TranscriptionRecord] = []
    @State private var selection: TranscriptionRecord.ID?

    var body: some View {
        VStack {
            Table(records, selection: $selection) {
                TableColumn("Когда") { r in
                    Text(r.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                }.width(min: 110, ideal: 130)
                TableColumn("Длительность") { r in
                    Text(String(format: "%.1fс", r.durationSeconds))
                        .font(.system(size: 11))
                }.width(min: 70, ideal: 80)
                TableColumn("Текст") { r in
                    Text(r.preview).font(.system(size: 12))
                }
            }
            // Двойной клик по строке открывает правку (штатный primaryAction таблицы),
            // правый клик — то же меню, что и кнопки под списком.
            .contextMenu(forSelectionType: TranscriptionRecord.ID.self) { ids in
                Button("Открыть в Edit & Learn") { open(ids) }
                Button("Удалить", role: .destructive) { delete(ids) }
            } primaryAction: { ids in
                open(ids)
            }
            HStack {
                Button("Открыть в Edit & Learn") { openSelected() }
                    .disabled(selection == nil)
                Button("Удалить") { deleteSelected() }
                    .disabled(selection == nil)
                Spacer()
                Button("Обновить") { reload() }
            }
        }
        .padding(12)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .voiceVoiceDataDidChange)) { _ in
            reload()
        }
    }

    private func reload() {
        records = HistoryStore.shared.recent(limit: 200)
    }
    private func openSelected() { open(selection.map { [$0] } ?? []) }
    private func deleteSelected() { delete(selection.map { [$0] } ?? []) }

    private func open(_ ids: Set<TranscriptionRecord.ID>) { open(Array(ids)) }
    private func delete(_ ids: Set<TranscriptionRecord.ID>) { delete(Array(ids)) }

    private func open(_ ids: [TranscriptionRecord.ID]) {
        guard let id = ids.first, let r = records.first(where: { $0.id == id }) else { return }
        EditAndLearnController.shared.open(record: r)
    }
    private func delete(_ ids: [TranscriptionRecord.ID]) {
        let doomed = records.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return }
        for r in doomed { HistoryStore.shared.delete(r) }
        reload()
    }
}
