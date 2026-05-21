import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @State private var entries: [CorrectionEntry] = []
    @State private var selection: Set<CorrectionEntry.ID> = []
    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Поиск", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Button("Экспорт JSON") { exportJSON() }
                Button("Импорт JSON") { importJSON() }
                Button("Обновить") { reload() }
            }
            Table(filtered, selection: $selection) {
                TableColumn("Wrong") { e in
                    Text(e.wrong).font(.system(.body, design: .monospaced))
                }
                TableColumn("Right") { e in
                    Text(e.right).font(.system(.body, design: .monospaced))
                }
                TableColumn("Контекст") { e in
                    Text(e.contextBefore ?? "—").foregroundStyle(.secondary).font(.system(size: 11))
                }.width(min: 70, ideal: 100)
                TableColumn("✓") { e in
                    Text("\(e.confirmedCount)").foregroundStyle(.green)
                }.width(min: 30, max: 50)
                TableColumn("✗") { e in
                    Text("\(e.rejectedCount)").foregroundStyle(.red)
                }.width(min: 30, max: 50)
                TableColumn("Активно") { e in
                    Image(systemName: e.isAutoApplied ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(e.isAutoApplied ? .green : .secondary)
                }.width(min: 50, max: 60)
            }
            HStack {
                Button(deleteLabel) { deleteSelected() }
                    .disabled(selection.isEmpty)
                    .keyboardShortcut(.delete, modifiers: [])
                if !selection.isEmpty {
                    Button("Снять выделение") { selection.removeAll() }
                }
                Spacer()
                if !filtered.isEmpty {
                    Button("Выделить всё") { selection = Set(filtered.compactMap { $0.id }) }
                }
                Text("Всего: \(entries.count)").foregroundStyle(.secondary).font(.system(size: 11))
            }
        }
        .padding(12)
        .onAppear { reload() }
    }

    private var deleteLabel: String {
        selection.count > 1 ? "Удалить выбранное (\(selection.count))" : "Удалить"
    }

    private var filtered: [CorrectionEntry] {
        guard !search.isEmpty else { return entries }
        let q = search.lowercased()
        return entries.filter { $0.wrong.contains(q) || $0.right.lowercased().contains(q) }
    }

    private func reload() {
        entries = CorrectionStore.shared.allOrdered()
        // Drop selection of any rows that no longer exist.
        selection = selection.filter { id in entries.contains(where: { $0.id == id }) }
    }

    private func deleteSelected() {
        let toDelete = entries.filter { selection.contains($0.id) }
        for entry in toDelete {
            CorrectionStore.shared.delete(entry)
        }
        selection.removeAll()
        reload()
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voicevoice-dictionary.json"
        panel.allowedContentTypes = [.json]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                enc.dateEncodingStrategy = .iso8601
                let data = try enc.encode(entries)
                try data.write(to: url)
            } catch {
                NSLog("export failed: \(error)")
            }
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let arr = try dec.decode([CorrectionEntry].self, from: data)
                CorrectionStore.shared.importEntries(arr, merge: true)
                reload()
            } catch {
                NSLog("import failed: \(error)")
            }
        }
    }
}
