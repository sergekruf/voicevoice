import SwiftUI

/// Large, centered, low-opacity recording animation. Borderless, click-through, click-protected,
/// and stays on top of everything including fullscreen apps. When live preview is on,
/// a draft of the recognized text (fully on-device) floats above the indicator.
struct RecordingOverlay: View {
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var transcriber = Transcriber.shared
    @ObservedObject private var parakeet = ParakeetTranscriber.shared

    static let panelSize = NSSize(width: 640, height: 240)

    var body: some View {
        VStack(spacing: 10) {
            if showsIndicator && settings.livePreview && !previewText.isEmpty {
                LivePreviewBubble(text: previewText)
            }
            ZStack {
                switch controller.state {
                case .recording:
                    RecordingPulse(level: levelValue)
                case .transcribing:
                    TranscribingSpinner()
                default:
                    EmptyView()
                }
            }
            .frame(width: 120, height: 120)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .bottom)
        .background(Color.clear)
    }

    private var showsIndicator: Bool {
        switch controller.state {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    /// Draft from whichever engine is active.
    private var previewText: String {
        settings.sttEngine == .parakeet ? parakeet.livePreviewText : transcriber.livePreviewText
    }

    private var levelValue: Float {
        if case .recording(let l) = controller.state { return l }
        return 0
    }
}

/// Черновой распознанный текст: последние строки важнее — длинный текст
/// обрезается СПЕРЕДИ (truncationMode .head).
private struct LivePreviewBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.95))
            .lineLimit(3)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .frame(maxWidth: 600)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecordingPulse: View {
    let level: Float
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            // Outer pulsing rings driven by audio level.
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.red.opacity(0.45 - Double(i) * 0.12), lineWidth: 1.5)
                    .scaleEffect(0.5 + CGFloat(level) * 0.5 + CGFloat(i) * 0.15 + phase * 0.12)
                    .opacity(1 - phase)
            }

            // Solid core.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.red.opacity(0.95), Color.red.opacity(0.55)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 36
                    )
                )
                .frame(width: 44 + CGFloat(level) * 28, height: 44 + CGFloat(level) * 28)
                .shadow(color: Color.red.opacity(0.55), radius: 10)

            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

private struct TranscribingSpinner: View {
    @State private var rotation: Double = 0
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: 56, height: 56)
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                .frame(width: 50, height: 50)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 50, height: 50)
                .rotationEffect(.degrees(rotation))
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
