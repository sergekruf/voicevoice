import Foundation
import CoreAudio

/// «Не отдавать системный вход Bluetooth-наушникам».
///
/// macOS при подключении BT-гарнитуры сама делает её микрофон системным входом
/// по умолчанию. Само по себе это безвредно, но первое же приложение, открывшее
/// микрофон (звонок в браузере, диктовка, Siri), переключает гарнитуру из
/// музыкального A2DP в гарнитурный HFP — и звук в наушниках падает до
/// телефонного качества (16 кГц моно). Гард слушает смену default input и,
/// если новым дефолтом стала Bluetooth-гарнитура, возвращает встроенный
/// микрофон (или выбранный в настройках, если тот не Bluetooth) — то, что
/// иначе приходится делать руками в System Settings → Sound → Input.
///
/// Осознанный компромисс: пока гард включён, выбрать микрофон гарнитуры
/// системным входом не получится и вручную — об этом предупреждает подсказка
/// у тумблера (для звонков через микрофон гарнитуры гард надо выключить).
@MainActor
final class SystemInputGuard {
    static let shared = SystemInputGuard()
    private init() {}

    private var active = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Привести состояние (слушатель вкл/выкл) к текущему значению настройки.
    func applySetting() {
        if AppSettings.shared.guardSystemInput { start() } else { stop() }
    }

    private func start() {
        guard !active else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in SystemInputGuard.shared.enforce() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        guard status == noErr else {
            DebugLog.log("InputGuard: не удалось подписаться на смену входа (\(status))")
            return
        }
        listener = block
        active = true
        DebugLog.log("InputGuard: включён")
        // Гарнитура могла захватить вход ещё до включения гарда / запуска приложения.
        enforce()
    }

    private func stop() {
        guard active, let block = listener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        listener = nil
        active = false
        DebugLog.log("InputGuard: выключен")
    }

    /// Если системный вход — Bluetooth-устройство, вернуть его на не-BT микрофон.
    /// Цикла не возникает: после переключения дефолт уже не Bluetooth.
    private func enforce() {
        guard AppSettings.shared.guardSystemInput else { return }
        guard let current = AudioDevices.defaultInput(),
              AudioDevices.isBluetooth(current.deviceID) else { return }

        // Куда возвращать: выбранное в настройках устройство (если оно не BT
        // и сейчас подключено), иначе — встроенный микрофон.
        var target: AudioInputDevice?
        let chosenUID = AppSettings.shared.inputDeviceUID
        if !chosenUID.isEmpty,
           let chosen = AudioDevices.inputDevices().first(where: { $0.uid == chosenUID }),
           !AudioDevices.isBluetooth(chosen.deviceID) {
            target = chosen
        }
        if target == nil { target = AudioDevices.builtInInput() }
        guard let target, target.deviceID != current.deviceID else { return }

        if AudioDevices.setDefaultInput(target.deviceID) {
            DebugLog.log("InputGuard: системный вход «\(current.name)» (Bluetooth) → «\(target.name)»")
        } else {
            DebugLog.log("InputGuard: не удалось вернуть вход на «\(target.name)»")
        }
    }
}
