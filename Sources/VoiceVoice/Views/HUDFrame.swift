import SwiftUI

/// Wraps any HUD content with a small countdown ring + close button in the top-right
/// corner. The ring drains from full to empty over `duration` seconds, then the panel
/// auto-dismisses; the close button lets the user dismiss it at any moment.
struct HUDFrame<Content: View>: View {
    let duration: TimeInterval
    let onClose: () -> Void
    let content: Content

    @State private var startTime = Date()
    @State private var progress: Double = 1.0
    @State private var hovered: Bool = false

    init(duration: TimeInterval, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.duration = duration
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            DismissControl(progress: progress, hovered: hovered, action: onClose)
                .onHover { hovered = $0 }
                .padding(.top, 6)
                .padding(.trailing, 6)
        }
        .onAppear {
            startTime = Date()
            progress = 1.0
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            let elapsed = Date().timeIntervalSince(startTime)
            let next = max(0, 1.0 - elapsed / max(duration, 0.001))
            if abs(next - progress) > 0.005 {
                progress = next
            }
        }
    }
}

private struct DismissControl: View {
    let progress: Double
    let hovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(hovered ? 0.18 : 0.06))
                    .frame(width: 22, height: 22)
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.white.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18, height: 18)
                Image(systemName: "xmark")
                    .font(.system(size: hovered ? 9 : 7, weight: .bold))
                    .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
            }
        }
        .buttonStyle(.plain)
        .help("Закрыть")
    }
}
