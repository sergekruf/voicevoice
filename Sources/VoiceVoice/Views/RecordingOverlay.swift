import SwiftUI

/// Large, centered, low-opacity recording animation. Borderless, click-through, click-protected,
/// and stays on top of everything including fullscreen apps.
struct RecordingOverlay: View {
    @ObservedObject private var controller = AppController.shared

    var body: some View {
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
        .background(Color.clear)
    }

    private var levelValue: Float {
        if case .recording(let l) = controller.state { return l }
        return 0
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
