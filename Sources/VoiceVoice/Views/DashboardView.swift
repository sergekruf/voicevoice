import SwiftUI

struct DashboardView: View {
    @State private var dictStats = CorrectionStore.Stats()
    @State private var histStats = HistoryStore.Stats()
    @State private var dbBytes: Int64 = 0
    @State private var modelsBytes: Int64 = 0
    @ObservedObject private var settings = AppSettings.shared
    @State private var refreshTick: Int = 0
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var exactSubstitutions: Int {
        max(0, settings.totalSubstitutions - settings.fuzzySubstitutions)
    }
    private var fuzzySharePercent: Int {
        guard settings.totalSubstitutions > 0 else { return 0 }
        return Int((Double(settings.fuzzySubstitutions) / Double(settings.totalSubstitutions) * 100).rounded())
    }

    /// Average realtime factor (audio_seconds / processing_seconds) over all-time.
    private var lifetimeRTF: Double {
        guard settings.lifetimeProcessingMs > 0 else { return 0 }
        return settings.lifetimeAudioSeconds / (Double(settings.lifetimeProcessingMs) / 1000)
    }
    private var firstRecordDate: Date? {
        settings.firstRecordAt > 0 ? Date(timeIntervalSince1970: settings.firstRecordAt) : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Дашборд")
                    .font(.title2.bold())

                Group {
                    sectionTitle("Распознавание")
                    HStack(spacing: 12) {
                        StatCard(title: "Всего расшифровок", value: "\(settings.lifetimeRecordsCount)", icon: "waveform.path")
                        StatCard(title: "Распознано символов", value: numberCompact(settings.lifetimeCharactersCount), icon: "text.alignleft")
                        StatCard(title: "Записано аудио", value: duration(settings.lifetimeAudioSeconds), icon: "clock")
                    }
                    HStack(spacing: 12) {
                        StatCard(title: "Сред. RTF", value: lifetimeRTF > 0 ? String(format: "%.1f×", lifetimeRTF) : "—",
                                 icon: "speedometer", subtitle: "во сколько раз быстрее реального времени")
                        StatCard(title: "Первая запись", value: firstRecordDate.map(shortDate) ?? "—", icon: "calendar.badge.plus")
                        StatCard(title: "Последняя запись", value: histStats.lastAt.map(shortDate) ?? "—", icon: "calendar")
                    }
                }

                Group {
                    sectionTitle("Словарь")
                    HStack(spacing: 12) {
                        StatCard(title: "Всего записей", value: "\(dictStats.totalEntries)", icon: "character.book.closed")
                        StatCard(title: "Активных", value: "\(dictStats.activeEntries)",
                                 icon: "checkmark.seal", subtitle: "автоматически подставляются")
                        StatCard(title: "Подтверждений", value: "\(dictStats.totalConfirmations)", icon: "hand.thumbsup")
                    }
                    HStack(spacing: 12) {
                        StatCard(title: "Подстановок всего", value: "\(settings.totalSubstitutions)",
                                 icon: "arrow.left.arrow.right", subtitle: "слов заменено из словаря")
                        StatCard(title: "Точных", value: "\(exactSubstitutions)",
                                 icon: "equal.circle", subtitle: "буква-в-букву")
                        StatCard(title: "Нечётких (fuzzy)", value: "\(settings.fuzzySubstitutions)",
                                 icon: "wand.and.sparkles",
                                 subtitle: settings.totalSubstitutions > 0 ? "\(fuzzySharePercent)% от всех" : "пока ни одной")
                    }
                }

                Group {
                    sectionTitle("Место на диске")
                    HStack(spacing: 12) {
                        StatCard(title: "База данных", value: byteString(dbBytes),
                                 icon: "cylinder", subtitle: "история + словарь")
                        StatCard(title: "Модель Whisper", value: byteString(modelsBytes),
                                 icon: "cpu", subtitle: settings.modelName)
                        StatCard(title: "Итого", value: byteString(dbBytes + modelsBytes), icon: "internaldrive")
                    }
                }

                Group {
                    sectionTitle("Настройки")
                    HStack(spacing: 12) {
                        StatCard(title: "Модель", value: shortModelName(settings.modelName), icon: "brain")
                        StatCard(title: "Hotkey", value: settings.hotkey.displayName, icon: "keyboard")
                        StatCard(title: "Порог подтверждений", value: "\(settings.minConfirmedToApply)",
                                 icon: "checkmark.shield", subtitle: "сколько раз править до автоприменения")
                    }
                    HStack(spacing: 12) {
                        StatCard(title: "Старт приложения", value: settings.eagerLoad ? "С прогревом" : "Lazy",
                                 icon: "bolt",
                                 subtitle: settings.eagerLoad ? "Модель грузится при запуске" : "Модель грузится по требованию")
                        StatCard(title: "Следующая загрузка модели", value: nextLoadEstimate.0,
                                 icon: "clock.arrow.2.circlepath", subtitle: nextLoadEstimate.1)
                    }
                }

                Spacer(minLength: 8)
                HStack {
                    Spacer()
                    Button("Обновить") { reload() }
                    Text("обновляется автоматически каждые 5 сек")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .onAppear { reload() }
        .onReceive(timer) { _ in reload() }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func reload() {
        dictStats = CorrectionStore.shared.stats(minConfirmedToApply: settings.minConfirmedToApply)
        histStats = HistoryStore.shared.stats()
        dbBytes = fileSize(at: AppPaths.databaseURL)
        modelsBytes = directorySize(at: hubModelsURL())
        refreshTick += 1
    }

    /// WhisperKit downloads models into `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<modelName>/`.
    private func hubModelsURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(settings.modelName)", isDirectory: true)
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? Int64) ?? 0
    }

    private func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dч %dм", h, m) }
        if m > 0 { return String(format: "%dм %dс", m, s) }
        return "\(s) сек"
    }

    private func numberCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    /// Predicts how fast the next model load will be based on:
    ///  • whether the current model has ever loaded successfully (then ANE has a kernel cache)
    ///  • how long ago that was (cache is OS-managed; usually preserved across launches but
    ///    can be evicted on disk pressure or OS updates)
    private var nextLoadEstimate: (String, String) {
        let lastModel = settings.lastSuccessfulModelId
        let lastAt = settings.lastSuccessfulLoadAt
        if lastModel.isEmpty || lastAt == 0 {
            return ("Долгая", "Эта модель ещё не загружалась — первый раз ANE будет компилировать 3–10 мин")
        }
        if lastModel != settings.modelName {
            return ("Долгая", "Сменилась модель — для новой ANE нужно скомпилировать (3–10 мин)")
        }
        // Same model loaded before → subsequent loads use cached ANE binaries.
        return ("Быстрая (~3 сек)", "ANE-кэш этой модели прогрет; загрузка из cold start будет мгновенной")
    }

    private func shortModelName(_ raw: String) -> String {
        // raw like "large-v3-v20240930_turbo_632MB" — return the human-friendly piece.
        if let choice = WhisperModelChoice(rawValue: raw) { return choice.displayName.components(separatedBy: " (").first ?? raw }
        return raw
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.08))
        )
    }
}
