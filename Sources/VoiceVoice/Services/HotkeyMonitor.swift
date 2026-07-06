import Foundation
import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// Listens globally for press/release of a chosen modifier-like key (Fn, right Option, Caps Lock).
/// Uses `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` which requires only
/// Accessibility — no Input Monitoring. Modifier-only detection is the lightest possible
/// path on macOS Tahoe.
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private var currentHotkey: HotkeyKind = .fn

    private init() {}

    // MARK: - Accessibility

    @discardableResult
    func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: [String: Bool] = [key: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Ground-truth check: attempt to install a real global event monitor. Returns nil if
    /// Accessibility was actually denied by TCC for this binary (e.g. after a rebuild),
    /// even when AXIsProcessTrusted reports true.
    func canCreateEventTap() -> Bool {
        let token = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { _ in }
        guard let token else { return false }
        NSEvent.removeMonitor(token)
        return true
    }

    /// Input Monitoring is NOT required for modifier-only (.flagsChanged) global monitors,
    /// so we report it as always granted. Kept here so the rest of the code/UI can ask.
    func inputMonitoringGranted() -> Bool { true }
    @discardableResult
    func requestInputMonitoring() -> Bool { true }

    // MARK: - Lifecycle

    func start(with hotkey: HotkeyKind) {
        stop()
        currentHotkey = hotkey
        DebugLog.log("Hotkey: start(\(hotkey.rawValue)) — installing monitors")

        // Don't gate on AXIsProcessTrusted — it lies. The only reliable signal is
        // whether NSEvent actually returns a monitor token.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
            return event
        }

        if globalMonitor == nil {
            DebugLog.log("Hotkey: GLOBAL monitor returned nil — Accessibility actually denied. Toggle off/on in System Settings.")
        } else {
            DebugLog.log("Hotkey: global flagsChanged monitor ACTIVE")
        }

        // Toggle mode starts from a known state: lock off, no phantom "first press
        // turns caps off and gets ignored".
        if hotkey == .capsLock {
            Self.setSystemCapsLock(on: false)
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    func reconfigure(hotkey: HotkeyKind) {
        start(with: hotkey)
    }

    // MARK: - Event handling

    private func handle(event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags

        DebugLog.log("Hotkey: flagsChanged keyCode=\(keyCode) flags=\(flags.rawValue) fn=\(flags.contains(.function))")

        switch currentHotkey {
        case .fn:
            // The Fn / 🌐 key fires flagsChanged with keyCode 63.
            if keyCode == 63 {
                updateState(down: flags.contains(.function))
            }
        case .rightOption:
            if keyCode == 61 {
                updateState(down: flags.contains(.option))
            }
        case .capsLock:
            // flagsChanged для Caps Lock отражает состояние ЗАМКА, а не физической
            // клавиши — key-up не детектится, поэтому «удержание» невозможно.
            // Режим — переключатель: нажатие = старт, следующее нажатие = стоп.
            // Реагируем только на включение замка (наш программный сброс ниже даёт
            // событие с выключенным флагом — оно игнорируется, петля исключена) и
            // сразу гасим замок, чтобы пользователь не остался печатать капсом.
            if keyCode == 57 && flags.contains(.capsLock) {
                Self.setSystemCapsLock(on: false)
                updateState(down: !isDown)
            }
        }
    }

    /// Sync the virtual press state after a dictation ends outside the normal
    /// release path (Esc cancel, failed recorder start). Critical for the Caps Lock
    /// toggle mode, where `isDown` isn't tied to any physical key state.
    func resetPressState() { isDown = false }

    /// Force the system Caps Lock LOCK state via the IOHIDSystem user client.
    /// Used by the Caps Lock hotkey mode so dictation presses don't leave the
    /// user's keyboard in caps.
    private static func setSystemCapsLock(on: Bool) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }

    private func updateState(down: Bool) {
        if down && !isDown {
            isDown = true
            DebugLog.log("Hotkey: PRESS fired")
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else if !down && isDown {
            isDown = false
            DebugLog.log("Hotkey: RELEASE fired")
            DispatchQueue.main.async { [weak self] in self?.onRelease?() }
        }
    }
}
