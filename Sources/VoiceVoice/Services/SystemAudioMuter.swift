import Foundation
import CoreAudio

/// Глушит системный звук на время записи (опция «Приглушать звук во время записи»):
/// играющая музыка/видео не попадает в микрофон и не мешает распознаванию.
///
/// Механика: у текущего устройства вывода по умолчанию выставляется mute-флаг
/// (kAudioDevicePropertyMute); если устройство его не поддерживает (часть BT-гарнитур),
/// фоллбэк — громкость в 0 с восстановлением прежнего значения. Если пользователь
/// САМ был в mute/нулевой громкости — ничего не делаем и ничего не восстанавливаем.
/// Восстановление привязано к тому же устройству, которое глушили.
final class SystemAudioMuter {
    static let shared = SystemAudioMuter()
    private init() {}

    private enum Saved {
        case mute(AudioDeviceID)                      // сняли с mute=0 → вернуть 0
        case volume(AudioDeviceID, Float32)           // выставили 0 → вернуть прежнюю
    }
    private var saved: Saved?

    func mute() {
        guard saved == nil else { return }   // уже заглушено нами
        guard let device = Self.defaultOutputDevice() else {
            DebugLog.log("Muter: no default output device")
            return
        }

        // Основной путь: mute-флаг устройства.
        if let current = Self.getMute(device) {
            if current == 1 { return }       // пользователь сам в mute — не вмешиваемся
            if Self.setMute(device, 1) {
                saved = .mute(device)
                DebugLog.log("Muter: output muted (device \(device))")
                return
            }
            // mute есть, но read-only — пробуем фоллбэк на громкость
        }

        // Фоллбэк: главная громкость → 0.
        if let vol = Self.getVolume(device), vol > 0.001, Self.setVolume(device, 0) {
            saved = .volume(device, vol)
            DebugLog.log("Muter: output volume 0 (was \(vol), device \(device))")
        } else {
            DebugLog.log("Muter: device \(device) supports neither mute nor volume — skipped")
        }
    }

    func restore() {
        guard let saved else { return }
        switch saved {
        case .mute(let device):
            _ = Self.setMute(device, 0)
            DebugLog.log("Muter: output unmuted (device \(device))")
        case .volume(let device, let vol):
            _ = Self.setVolume(device, vol)
            DebugLog.log("Muter: output volume restored to \(vol) (device \(device))")
        }
        self.saved = nil
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return (status == noErr && device != 0) ? device : nil
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func getMute(_ device: AudioDeviceID) -> UInt32? {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func setMute(_ device: AudioDeviceID, _ value: UInt32) -> Bool {
        var addr = muteAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(device, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    /// Громкость: сперва master-элемент, иначе каналы 1–2 (у части устройств
    /// главного элемента нет).
    private static func getVolume(_ device: AudioDeviceID) -> Float32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
            return value
        }
        addr.mElement = 1
        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
            return value
        }
        return nil
    }

    @discardableResult
    private static func setVolume(_ device: AudioDeviceID, _ value: Float32) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var v = value
        if AudioObjectHasProperty(device, &addr),
           AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr {
            return true
        }
        var ok = false
        for channel: UInt32 in 1...2 {
            addr.mElement = channel
            var vv = value
            if AudioObjectHasProperty(device, &addr),
               AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vv) == noErr {
                ok = true
            }
        }
        return ok
    }
}
