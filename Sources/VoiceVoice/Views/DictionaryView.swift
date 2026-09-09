import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @State private var entries: [CorrectionEntry] = []
    @State private var selection: Set<CorrectionEntry.ID> = []
    @State private var search: String = ""
    @State private var showingAdd = false
    @State private var auditFindings: [DictionaryAudit.Finding]? = nil
    @State private var miningCandidates: [HistoryMining.Candidate]? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Поиск", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Button {
                    showingAdd = true
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
                Button("Разбор диктовок…") {
                    miningCandidates = HistoryMining.candidates(
                        from: HistoryStore.shared.recent(limit: 500), existing: entries)
                }
                .help("Найти в истории исправления, которые повторяются раз за разом, и предложить их в словарь.")
                Button("Ревизия…") { auditFindings = DictionaryAudit.audit(entries) }
                    .help("Найти правила, которые будут портить будущие диктовки: замены обычных слов, дубликаты, отклонённые вами.")
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
                    let active = e.isActive(minConfirmed: AppSettings.shared.minConfirmedToApply)
                    Image(systemName: active ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(active ? .green : .secondary)
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
        .onReceive(NotificationCenter.default.publisher(for: .voiceVoiceDataDidChange)) { _ in
            reload()
        }
        .sheet(item: Binding(
            get: { auditFindings.map { AuditResult(findings: $0) } },
            set: { if $0 == nil { auditFindings = nil } }
        )) { result in
            DictionaryAuditSheet(findings: result.findings, total: entries.count) { doomed in
                for entry in doomed { CorrectionStore.shared.delete(entry) }
                auditFindings = nil
                reload()
            } onCancel: {
                auditFindings = nil
            }
        }
        .sheet(item: Binding(
            get: { miningCandidates.map { MiningResult(candidates: $0) } },
            set: { if $0 == nil { miningCandidates = nil } }
        )) { result in
            HistoryMiningSheet(candidates: result.candidates) { chosen in
                for c in chosen {
                    CorrectionStore.shared.addManual(wrong: c.wrong, right: c.right, contextBefore: nil)
                }
                miningCandidates = nil
                reload()
            } onCancel: {
                miningCandidates = nil
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCorrectionSheet { wrong, right, context in
                CorrectionStore.shared.addManual(wrong: wrong, right: right, contextBefore: context)
                reload()
            }
        }
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

/// Modal form for adding a correction by hand. `onSave(wrong, right, context)` is
/// called only when both required fields are filled and differ.
private struct AddCorrectionSheet: View {
    let onSave: (_ wrong: String, _ right: String, _ context: String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var wrong = ""
    @State private var right = ""
    @State private var context = ""

    private var canSave: Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        return !w.isEmpty && !r.isEmpty && w.lowercased() != r.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новая правка словаря")
                .font(.headline)
            Text("«Как распозналось» будет автоматически заменяться на «Как должно быть» при следующих диктовках (с учётом нечёткого сравнения, если оно включено).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Как распозналось", text: $wrong, prompt: Text("клод код"))
                TextField("Как должно быть", text: $right, prompt: Text("Claude Code"))
                TextField("Контекст (необяз.)", text: $context, prompt: Text("предыдущее слово"))
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Добавить") {
                    onSave(
                        wrong.trimmingCharacters(in: .whitespacesAndNewlines),
                        right.trimmingCharacters(in: .whitespacesAndNewlines),
                        context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil : context.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}


/// Обёртка для `.sheet(item:)` — массив находок сам по себе не Identifiable.
private struct AuditResult: Identifiable {
    let findings: [DictionaryAudit.Finding]
    var id: Int { findings.count }
}

/// Результаты ревизии: что предлагается убрать и почему. Ничего не удаляется без
/// подтверждения — именно автоматическое пополнение словаря и намусорило в нём.
private struct DictionaryAuditSheet: View {
    let findings: [DictionaryAudit.Finding]
    let total: Int
    let onDelete: ([CorrectionEntry]) -> Void
    let onCancel: () -> Void

    @State private var checked: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "stethoscope").foregroundStyle(.tint)
                Text("Ревизия словаря").font(.headline)
                Spacer()
                Text("проверено правил: \(total)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if findings.isEmpty {
                Text("Проблемных правил не найдено.").foregroundStyle(.secondary)
            } else {
                Text("Эти правила применяются ко всем будущим диктовкам и, скорее всего, будут портить текст. Отметьте те, что нужно удалить.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(findings) { f in
                            Toggle(isOn: Binding(
                                get: { checked.contains(f.id) },
                                set: { on in if on { checked.insert(f.id) } else { checked.remove(f.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("«\(f.entry.wrong)» → «\(f.entry.right)»")
                                        .font(.system(.body, design: .monospaced))
                                    Text(f.reason + (f.neverUsed ? " · ни разу не применялось" : ""))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 380)
            }
            HStack {
                if !findings.isEmpty {
                    Button("Отметить все") { checked = Set(findings.map(\.id)) }
                    Button("Снять все") { checked.removeAll() }
                }
                Spacer()
                Button("Закрыть", action: onCancel)
                Button("Удалить отмеченные (\(checked.count))") {
                    onDelete(findings.filter { checked.contains($0.id) }.map(\.entry))
                }
                .buttonStyle(.borderedProminent)
                .disabled(checked.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear {
            // Заранее отмечаем только бесспорное: дубликаты, самозамены, отклонённые
            // и правила, которые ни разу не пригодились.
            checked = Set(findings.filter { f in
                f.neverUsed || f.issues.contains(where: { $0 != .realWord })
            }.map(\.id))
        }
    }
}


private struct MiningResult: Identifiable {
    let candidates: [HistoryMining.Candidate]
    var id: Int { candidates.count }
}

/// Кандидаты в словарь из истории: исправления, которые повторились несколько раз.
/// Как и ревизия, ничего не добавляет без подтверждения.
private struct HistoryMiningSheet: View {
    let candidates: [HistoryMining.Candidate]
    let onAdd: ([HistoryMining.Candidate]) -> Void
    let onCancel: () -> Void

    @State private var checked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.tint)
                Text("Разбор диктовок").font(.headline)
            }
            if candidates.isEmpty {
                Text("Повторяющихся исправлений пока не найдено. Разбор смотрит, что пост-обработка чинила в ваших диктовках не меньше двух раз; записи, сделанные до обновления, в анализ не попадают.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Эти исправления повторялись в ваших диктовках. Добавьте их в словарь — тогда замена будет мгновенной и не будет зависеть от моделей.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { c in
                            Toggle(isOn: Binding(
                                get: { checked.contains(c.id) },
                                set: { on in if on { checked.insert(c.id) } else { checked.remove(c.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("«\(c.wrong)» → «\(c.right)»  ·  \(c.count)×")
                                        .font(.system(.body, design: .monospaced))
                                    Text(c.example).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 360)
            }
            HStack {
                if !candidates.isEmpty {
                    Button("Отметить все") { checked = Set(candidates.map(\.id)) }
                    Button("Снять все") { checked.removeAll() }
                }
                Spacer()
                Button("Закрыть", action: onCancel)
                Button("Добавить в словарь (\(checked.count))") {
                    onAdd(candidates.filter { checked.contains($0.id) })
                }
                .buttonStyle(.borderedProminent)
                .disabled(checked.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
