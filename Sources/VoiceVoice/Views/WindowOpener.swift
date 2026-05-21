import AppKit
import SwiftUI

@MainActor
enum WindowOpener {
    private static var mainWindow: NSWindow?
    private static var onboardingWindow: NSWindow?

    static func openDashboard()  { openMain(tab: .dashboard) }
    static func openHistory()    { openMain(tab: .history) }
    static func openDictionary() { openMain(tab: .dictionary) }
    static func openSettings()   { openMain(tab: .settings) }

    private static func openMain(tab: MainTab) {
        MainWindowState.shared.tab = tab
        if let w = mainWindow {
            ensureRegularActivation()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: MainWindow())
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "VoiceVoice"
        w.center()
        w.contentViewController = host
        w.isReleasedWhenClosed = false
        w.delegate = WindowDelegate.shared
        mainWindow = w
        ensureRegularActivation()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func openOnboarding() {
        if let w = onboardingWindow {
            ensureRegularActivation()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: OnboardingView(onClose: {
            closeOnboarding()
        }))
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "VoiceVoice — начальная настройка"
        w.center()
        w.contentViewController = host
        w.isReleasedWhenClosed = false
        w.delegate = WindowDelegate.shared
        onboardingWindow = w
        ensureRegularActivation()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        updateActivationPolicy()
    }

    static func ensureRegularActivation() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func updateActivationPolicy() {
        let anyOpen = [mainWindow, onboardingWindow].contains { $0?.isVisible == true }
        let desired: NSApplication.ActivationPolicy = anyOpen ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
        }
    }
}

final class WindowDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowDelegate()
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            WindowOpener.updateActivationPolicy()
        }
    }
}
