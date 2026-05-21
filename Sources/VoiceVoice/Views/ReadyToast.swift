import SwiftUI

struct ReadyToast: View {
    @ObservedObject private var transcriber = Transcriber.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .padding(4)
    }

    private var icon: String {
        switch transcriber.state {
        case .ready: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .downloading, .loading, .notLoaded: return "arrow.down.circle"
        }
    }
    private var iconColor: Color {
        switch transcriber.state {
        case .ready: return .green
        case .error: return .yellow
        default: return .white
        }
    }

    private var title: String {
        switch transcriber.state {
        case .ready: return "VoiceVoice готов"
        case .error(let m): return "Ошибка загрузки модели: \(m)"
        case .downloading(let p): return "Загрузка модели: \(Int(p * 100))%"
        case .loading: return "Компиляция модели для Neural Engine…"
        case .notLoaded: return "Загрузка модели (~626 МБ)…"
        }
    }

    private var subtitle: String {
        switch transcriber.state {
        case .ready: return "Зажми \(settings.hotkey.displayName) в любом приложении"
        case .error: return "Проверь интернет; модель кэшируется один раз"
        case .loading: return "При первом запуске ANE компилирует модель 3–10 минут. Потом мгновенно."
        case .downloading, .notLoaded: return "При первом запуске ~626 МБ из HuggingFace"
        }
    }
}
