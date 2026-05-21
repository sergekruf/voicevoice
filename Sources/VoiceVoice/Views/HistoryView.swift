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
    }

    private func reload() {
        records = HistoryStore.shared.recent(limit: 200)
    }
    private func openSelected() {
        guard let id = selection, let r = records.first(where: { $0.id == id }) else { return }
        EditAndLearnController.shared.open(record: r)
    }
    private func deleteSelected() {
        guard let id = selection, let r = records.first(where: { $0.id == id }) else { return }
        HistoryStore.shared.delete(r)
        reload()
    }
}
