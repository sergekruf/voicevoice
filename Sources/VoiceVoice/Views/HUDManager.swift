import AppKit
import SwiftUI

@MainActor
final class HUDManager {
    static let shared = HUDManager()

    private var centerOverlayPanel: NSPanel?

    private var resultPanel: NSPanel?
    private var resultDismissTask: DispatchWorkItem?

    private var learnedPanel: NSPanel?
    private var learnedDismissTask: DispatchWorkItem?

    private var loadingPanel: NSPanel?
    private var readyPanel: NSPanel?
    private init() {}

    // MARK: - Recording overlay (bottom-center pulsing mic)

    func showRecording() { showRecordingOverlay() }
    func showTranscribing() { showRecordingOverlay() }
    func hideRecording() { hideRecordingOverlay() }

    private func showRecordingOverlay() {
        if centerOverlayPanel == nil {
            let host = NSHostingController(rootView: RecordingOverlay())
            let panel = makePanel(size: NSSize(width: 120, height: 120), content: host.view)
            panel.ignoresMouseEvents = true
            centerOverlayPanel = panel
        }
        positionBottomCenter(centerOverlayPanel, offsetY: 24)
        centerOverlayPanel?.orderFrontRegardless()
    }

    private func hideRecordingOverlay() {
        centerOverlayPanel?.orderOut(nil)
    }

    // MARK: - Result HUD

    func showResult(record: TranscriptionRecord) {
        hideRecording()
        guard AppSettings.shared.showResultHUD else { return }
        present(view: ResultHUD(record: record), ref: &resultPanel, size: NSSize(width: 520, height: 160), autohide: 7.0)
    }

    func hideResult() { resultPanel?.orderOut(nil) }

    // MARK: - Learned-correction toast

    func showLearned(corrections: [(wrong: String, right: String)]) {
        guard !corrections.isEmpty else { return }
        // Height grows with number of correction pairs shown (max 3 + "…and N more").
        let rowCount = min(corrections.count, 3) + (corrections.count > 3 ? 1 : 0)
        let height = CGFloat(64 + rowCount * 22)
        present(view: LearnedToast(corrections: corrections), ref: &learnedPanel, size: NSSize(width: 500, height: height), autohide: 4.0)
    }

    // MARK: - Model loading

    func showLoadingIndicator() {
        present(view: LoadingIndicator(), ref: &loadingPanel, autohide: nil)
    }

    func hideLoadingIndicator() {
        loadingPanel?.orderOut(nil)
    }

    // MARK: - Ready toast (after onboarding)

    func showReady() {
        present(view: ReadyToast(), ref: &readyPanel, autohide: 5.0)
    }

    // MARK: - Panel presentation primitive

    /// Build (or reuse) a bottom-center panel for any SwiftUI toast.
    /// Uses fixed panel dimensions (generous enough for wrapped text) — the inner SwiftUI
    /// views constrain themselves to `.frame(maxWidth: 460)` and use `.fixedSize(vertical:true)`
    /// so multi-line text renders cleanly. Don't combine `sizingOptions = .preferredContentSize`
    /// with manual `setContentSize` — they fight and trigger a layout-recursion crash.
    private func present<V: View>(view: V, ref: inout NSPanel?, size: NSSize = NSSize(width: 500, height: 120), autohide: TimeInterval?) {
        let panel: NSPanel
        if let existing = ref {
            panel = existing
        } else {
            panel = makePanel(size: size, content: NSView())
            ref = panel
        }
        let onClose: () -> Void = { [weak panel] in panel?.orderOut(nil) }

        let hostController: NSHostingController<AnyView>
        if let dur = autohide {
            hostController = NSHostingController(rootView: AnyView(
                HUDFrame(duration: dur, onClose: onClose) { view }
            ))
        } else {
            hostController = NSHostingController(rootView: AnyView(view))
        }
        panel.contentViewController = hostController
        panel.setContentSize(size)

        positionBottomCenter(panel, offsetY: bottomOffsetForToast())
        panel.orderFrontRegardless()

        if let autohide {
            let panelRef = panel
            DispatchQueue.main.asyncAfter(deadline: .now() + autohide) { [weak panelRef] in
                panelRef?.orderOut(nil)
            }
        }
    }

    /// Toasts sit above the recording mic when it's visible, otherwise hug the bottom.
    private func bottomOffsetForToast() -> CGFloat {
        if let mic = centerOverlayPanel, mic.isVisible { return 160 }
        return 24
    }

    // MARK: - Panel factory + positioning

    private func makePanel(size: NSSize, content: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = content
        return panel
    }

    private func positionBottomCenter(_ panel: NSPanel?, offsetY: CGFloat) {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let w = panel.frame.width
        let h = panel.frame.height
        let x = frame.midX - w / 2
        let y = frame.minY + offsetY
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}
