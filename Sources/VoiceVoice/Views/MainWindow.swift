import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case dashboard = "Дашборд"
    case history = "История"
    case dictionary = "Словарь"
    case settings = "Настройки"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar.doc.horizontal"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class MainWindowState: ObservableObject {
    static let shared = MainWindowState()
    @Published var tab: MainTab = .dashboard
    private init() {}
}

struct MainWindow: View {
    @ObservedObject private var state = MainWindowState.shared

    private var tab: Binding<MainTab> {
        Binding(get: { state.tab }, set: { state.tab = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: tab) {
                ForEach(MainTab.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 520)

            Divider()

            Group {
                switch state.tab {
                case .dashboard:  DashboardView()
                case .history:    HistoryView()
                case .dictionary: DictionaryView()
                case .settings:   SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 480, idealHeight: 600)
    }
}
