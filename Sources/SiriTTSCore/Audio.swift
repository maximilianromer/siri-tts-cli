import AudioToolbox
import CoreAudioTypes
import Foundation

public enum AudioIO {
    public static func validatePCM(_ pcm: Data, spec: AudioSpec, text: String, allowSilence: Bool = false) throws -> AudioResult {
        guard spec.sampleRate > 0, spec.channels > 0, spec.bitsPerChannel == 16,
              spec.bytesPerFrame == spec.channels * 2,
              !pcm.isEmpty, pcm.count.isMultiple(of: spec.bytesPerFrame) else {
            throw CLIError("Synthesis produced invalid or empty PCM audio", code: .noAudio)
        }

        var nonSilent = false
        pcm.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) where sample != 0 {
                nonSilent = true
                break
            }
        }
        guard nonSilent || allowSilence else {
            throw CLIError("Synthesis produced only silence", code: .noAudio)
        }

        let samples = pcm.count / spec.bytesPerFrame
        let duration = Double(samples) / spec.sampleRate
        let spokenLength = text.filter { !$0.isWhitespace }.utf16.count
        let minimum = max(0.05, Double(spokenLength) * 0.005)
        guard duration >= minimum else {
            throw CLIError(
                "Synthesis produced only \(String(format: "%.3f", duration)) seconds of audio",
                code: .noAudio
            )
        }
        let plausibleMaximum = max(30, Double(spokenLength) * 3)
        guard duration <= plausibleMaximum else {
            throw CLIError(
                "Synthesis duration is implausible for the supplied text",
                code: .noAudio
            )
        }

        return AudioResult(
            format: "pcm_s16le",
            output: "",
            sampleRate: spec.sampleRate,
            channels: spec.channels,
            bitsPerChannel: spec.bitsPerChannel,
            bytes: pcm.count,
            sampleCount: samples,
            durationSeconds: duration,
            nonSilent: nonSilent
        )
    }

    static func applyingVolume(_ gain: Float, to pcm: Data) -> Data {
        if gain == 1 { return pcm }
        if gain == 0 { return Data(repeating: 0, count: pcm.count) }
        var result = pcm
        result.withUnsafeMutableBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for index in samples.indices { samples[index] = Int16((Float(samples[index]) * gain).rounded()) }
        }
        return result
    }

    public static func makeWAV(pcm: Data, spec: AudioSpec) throws -> Data {
        var wav = try makeWAVHeader(pcmByteCount: Int64(pcm.count), spec: spec)
        wav.append(pcm)
        return wav
    }

    public static func writeWAV(pcmAt pcmURL: URL, spec: AudioSpec, to outputURL: URL) throws {
        let byteCount = try fileSize(at: pcmURL)
        let output = try FileHandle(forWritingTo: createEmptyFile(at: outputURL))
        defer { try? output.close() }
        try output.write(contentsOf: makeWAVHeader(pcmByteCount: byteCount, spec: spec))
        try copyFile(at: pcmURL, to: output)
        try output.synchronize()
    }

    public static func makeCAF(pcm: Data, spec: AudioSpec, at url: URL) throws {
        var asbd = spec.asbd
        var audioFile: AudioFileID?
        let create = AudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &asbd,
            .eraseFile,
            &audioFile
        )
        guard create == noErr, let audioFile else {
            throw CLIError("Could not create CAF output (OSStatus \(create))", code: .internalFailure)
        }
        defer { AudioFileClose(audioFile) }
        var bytes = UInt32(pcm.count)
        let write = pcm.withUnsafeBytes {
            AudioFileWriteBytes(audioFile, false, 0, &bytes, $0.baseAddress!)
        }
        guard write == noErr, bytes == pcm.count else {
            throw CLIError("Could not write CAF output (OSStatus \(write))", code: .internalFailure)
        }
    }

    public static func writeCAF(pcmAt pcmURL: URL, spec: AudioSpec, to outputURL: URL) throws {
        var asbd = spec.asbd
        var audioFile: AudioFileID?
        let create = AudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileCAFType,
            &asbd,
            .eraseFile,
            &audioFile
        )
        guard create == noErr, let audioFile else {
            throw CLIError("Could not create CAF output (OSStatus \(create))", code: .internalFailure)
        }
        defer { AudioFileClose(audioFile) }

        let input = try FileHandle(forReadingFrom: pcmURL)
        defer { try? input.close() }
        var offset: Int64 = 0
        while true {
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            var bytes = UInt32(data.count)
            let write = data.withUnsafeBytes {
                AudioFileWriteBytes(audioFile, false, offset, &bytes, $0.baseAddress!)
            }
            guard write == noErr, bytes == data.count else {
                throw CLIError(
                    "Could not write CAF output (OSStatus \(write))",
                    code: .internalFailure
                )
            }
            offset += Int64(bytes)
        }
    }

    private static func makeWAVHeader(pcmByteCount: Int64, spec: AudioSpec) throws -> Data {
        guard pcmByteCount >= 0,
              pcmByteCount <= Int64(UInt32.max) - 36,
              spec.sampleRate <= Double(UInt32.max),
              spec.channels <= Int(UInt16.max),
              spec.bitsPerChannel == 16 else {
            throw CLIError(
                "WAV output is limited to 4 GB; use CAF or raw PCM for longer audio",
                code: .noAudio
            )
        }
        let sampleRate = UInt32(spec.sampleRate.rounded())
        let channels = UInt16(spec.channels)
        let blockAlign = UInt16(spec.bytesPerFrame)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(pcmByteCount)

        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.appendLE(UInt32(36) + dataSize)
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))
        wav.appendLE(channels)
        wav.appendLE(sampleRate)
        wav.appendLE(byteRate)
        wav.appendLE(blockAlign)
        wav.appendLE(UInt16(spec.bitsPerChannel))
        wav.append(Data("data".utf8))
        wav.appendLE(dataSize)
        return wav
    }

    private static func createEmptyFile(at url: URL) throws -> URL {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CLIError("Could not create audio output at \(url.path)", code: .internalFailure)
        }
        return url
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw CLIError("Could not determine PCM file size", code: .internalFailure)
        }
        return Int64(size)
    }

    private static func copyFile(at url: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        while true {
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { return }
            try output.write(contentsOf: data)
        }
    }
}

final class PCMSpool {
    let url: URL
    private var handle: FileHandle?

    init(directory: URL = FileManager.default.temporaryDirectory) throws {
        url = directory.appendingPathComponent(".siri-tts-\(UUID().uuidString).pcm")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CLIError("Could not create temporary audio storage", code: .internalFailure)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle?.close()
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ data: Data) throws {
        guard let handle else {
            throw CLIError("Temporary audio storage is closed", code: .internalFailure)
        }
        try handle.write(contentsOf: data)
    }

    func close() throws {
        guard let handle else { return }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
    }

    func materialize(format: AudioFormat, spec: AudioSpec, at destination: URL) throws {
        try close()
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        switch format {
        case .pcm:
            try FileManager.default.copyItem(at: url, to: temporary)
        case .wav:
            try AudioIO.writeWAV(pcmAt: url, spec: spec, to: temporary)
        case .caf:
            try AudioIO.writeCAF(pcmAt: url, spec: spec, to: temporary)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
