import SwiftUI

struct RecordingHUD: View {
    @ObservedObject private var controller = AppController.shared

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(circleColor)
                .frame(width: 12, height: 12)
                .scaleEffect(pulsing ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulsing)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                LevelBar(level: levelValue)
                    .frame(height: 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .padding(4)
    }

    private var pulsing: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    private var title: String {
        switch controller.state {
        case .recording: return "Запись… отпусти, чтобы распознать"
        case .transcribing: return "Распознавание…"
        case .complete: return "Готово"
        case .error(let msg): return "Ошибка: \(msg)"
        case .idle: return "Готов"
        }
    }

    private var circleColor: Color {
        switch controller.state {
        case .recording: return .red
        case .transcribing: return .orange
        case .complete: return .green
        case .error: return .yellow
        case .idle: return .gray
        }
    }

    private var levelValue: Float {
        if case .recording(let l) = controller.state { return l }
        return 0
    }
}

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(Color.white.opacity(0.9))
                    .frame(width: max(2, CGFloat(level) * geo.size.width))
            }
        }
    }
}
