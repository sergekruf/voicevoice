import Foundation
import AVFoundation

/// Decodes an arbitrary audio file into mono 16 kHz Float32 samples — the format both
/// engines (WhisperKit, Parakeet) consume. Strategy, from cheapest to most robust:
///   1. `AVAudioFile` in-process (Core Audio): mp3, m4a/aac, wav, aiff, caf, flac — and
///      on recent macOS even ogg/opus.
///   2. Fallback `afconvert` (built into every macOS, `/usr/bin/afconvert`): transcode to
///      a temp 16 kHz mono WAV, then decode that. Covers ogg/opus/vorbis here.
///   3. Fallback `ffmpeg` (if installed): universal last resort.
/// Result is always mono 16 kHz Float32 in [-1, 1].
enum AudioFileDecoder {
    struct DecodeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Audio file extensions we advertise in the open panel (Core Audio + ffmpeg-able).
    static let supportedExtensions: [String] = [
        "ogg", "oga", "opus", "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff",
        "aifc", "caf", "flac", "mp4", "m4b", "amr", "wma", "ac3",
    ]

    static func targetSampleRate() -> Double { AudioRecorder.targetSampleRate }

    /// Decode `url` to mono 16 kHz Float32. Throws if every strategy fails.
    static func decode(url: URL) throws -> [Float] {
        // 1. Native (in-process).
        if let samples = try? decodeNative(url), !samples.isEmpty {
            DebugLog.log("FileDecode: native AVAudioFile ok (\(samples.count) samples) — \(url.lastPathComponent)")
            return samples
        }

        // 2/3. Transcode to a temp 16 kHz mono WAV via an external tool, then decode that.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicevoice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }

        if transcode(input: url, output: temp, tool: .afconvert),
           let samples = try? decodeNative(temp), !samples.isEmpty {
            DebugLog.log("FileDecode: afconvert fallback ok (\(samples.count) samples) — \(url.lastPathComponent)")
            return samples
        }
        if let ffmpeg = ffmpegPath(),
           transcode(input: url, output: temp, tool: .ffmpeg(ffmpeg)),
           let samples = try? decodeNative(temp), !samples.isEmpty {
            DebugLog.log("FileDecode: ffmpeg fallback ok (\(samples.count) samples) — \(url.lastPathComponent)")
            return samples
        }

        throw DecodeError(message: "Не удалось декодировать \(url.lastPathComponent). Формат не поддержан ни Core Audio, ни afconvert, ни ffmpeg.")
    }

    // MARK: - Native decode

    private static func decodeNative(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
            throw DecodeError(message: "Пустой или нечитаемый аудиопоток")
        }
        try file.read(into: inBuf)
        return resampleToMono16k(inBuf, from: inFormat)
    }

    /// Convert any PCM buffer to mono 16 kHz Float32 via AVAudioConverter (one-shot).
    private static func resampleToMono16k(_ inBuf: AVAudioPCMBuffer, from inFormat: AVAudioFormat) -> [Float] {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate(),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return [] }

        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 4096)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return [] }

        var supplied = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        guard error == nil, let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    // MARK: - External transcode

    private enum Tool { case afconvert, ffmpeg(String) }

    private static func transcode(input: URL, output: URL, tool: Tool) -> Bool {
        let process = Process()
        switch tool {
        case .afconvert:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            // 16-bit LE PCM, 16 kHz, mono, WAVE container.
            process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, output.path]
        case .ffmpeg(let path):
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-y", "-i", input.path, "-ar", "16000", "-ac", "1", "-f", "wav", output.path]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
                && FileManager.default.fileExists(atPath: output.path)
        } catch {
            DebugLog.log("FileDecode: transcode launch failed — \(error.localizedDescription)")
            return false
        }
    }

    private static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }
}
