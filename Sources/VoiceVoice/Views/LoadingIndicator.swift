import SwiftUI

struct LoadingIndicator: View {
    @ObservedObject private var transcriber = Transcriber.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .padding(4)
    }

    private var title: String {
        switch transcriber.state {
        case .notLoaded: return "Подготовка модели…"
        case .downloading(let p): return "Загрузка модели — \(Int(p * 100))%"
        case .loading: return "Компиляция модели для Neural Engine…"
        case .ready: return "Готово"
        case .error(let m): return "Ошибка: \(m)"
        }
    }

    private var subtitle: String {
        switch transcriber.state {
        case .notLoaded: return "Сейчас начнётся"
        case .downloading: return "Из HuggingFace, один раз"
        case .loading: return "При первом запуске занимает несколько минут — нужно один раз скомпилировать модель для Neural Engine. Дальше — мгновенно."
        case .ready: return "Зажми Fn для записи"
        case .error: return "Открой меню → Настройки"
        }
    }
}
