import Foundation
import AVFoundation
import Accelerate
import CoreAudio

final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterOutputFormat: AVAudioFormat?
    private var buffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "voicevoice.audio.buffer")
    private(set) var isRecording = false

    /// Callback fired ~10× per second with the current RMS (0..1).
    var onLevel: ((Float) -> Void)?

    func requestPermissionIfNeeded(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() throws {
        guard !isRecording else { return }

        // If the user has picked a specific input device in Settings, route engine input
        // through it. Empty UID = follow system default (no override).
        let chosenUID = AppSettings.shared.inputDeviceUID
        if !chosenUID.isEmpty, let deviceID = AudioDevices.deviceID(forUID: chosenUID) {
            try setEngineInputDevice(deviceID)
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "VoiceVoice.Audio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No active microphone input found.",
            ])
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VoiceVoice.Audio", code: 2)
        }
        converterOutputFormat = outFormat
        converter = AVAudioConverter(from: inputFormat, to: outFormat)

        bufferQueue.sync { buffer.removeAll(keepingCapacity: true) }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] inBuf, _ in
            self?.process(inBuf)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return bufferQueue.sync { buffer }
    }

    func cancel() {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
        }
        bufferQueue.sync { buffer.removeAll(keepingCapacity: true) }
    }

    private func process(_ inBuf: AVAudioPCMBuffer) {
        guard let converter, let outFormat = converterOutputFormat else { return }

        let ratio = outFormat.sampleRate / inBuf.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var supplied = false
        converter.convert(to: outBuf, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }

        guard error == nil,
              let ch = outBuf.floatChannelData?[0]
        else { return }

        let frames = Int(outBuf.frameLength)
        if frames == 0 { return }

        let chunk = Array(UnsafeBufferPointer(start: ch, count: frames))

        // RMS level
        var rms: Float = 0
        vDSP_rmsqv(chunk, 1, &rms, vDSP_Length(frames))
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(min(1, rms * 4))
        }

        bufferQueue.sync {
            buffer.append(contentsOf: chunk)
        }
    }

    var currentDurationSeconds: Double {
        bufferQueue.sync { Double(buffer.count) / Self.targetSampleRate }
    }

    /// Thread-safe snapshot of the audio captured so far, without stopping the
    /// engine. Used by the eager-streaming transcriber to decode completed chunks
    /// while recording continues.
    func currentSamples() -> [Float] {
        bufferQueue.sync { buffer }
    }

    /// Route `AVAudioEngine`'s inputNode through a specific CoreAudio device.
    /// Must be called before `engine.start()`.
    private func setEngineInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let au = engine.inputNode.audioUnit else {
            throw NSError(domain: "VoiceVoice.Audio", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Input node has no audioUnit"
            ])
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(domain: "VoiceVoice.Audio", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "AudioUnitSetProperty CurrentDevice failed (\(status))"
            ])
        }
    }
}
