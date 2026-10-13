@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudioTypes
import Foundation

struct SiriSourceAudioChunk: Sendable {
    let audioData: Data
    let format: AudioStreamBasicDescription
    let packetDescriptions: Data
    let packetCount: Int
    let reportedSampleCount: Int
}

/// Stateful because Opus priming and resampling history span daemon callbacks.
/// One instance must be used for exactly one synthesis request.
final class SiriAudioNormalizer: @unchecked Sendable {
    // The daemon's LPCM `packetCount` is not consistently a packet count. On
    // current macOS releases it may contain the number of PCM frames in the
    // callback, so it is deliberately ignored for LPCM. Bound the actual byte
    // payload instead; that is the memory this normalizer copies and converts.
    private static let maximumPCMCallbackBytes = 64 * 1_024 * 1_024
    private static let maximumOpusCallbackBytes = 16 * 1_024 * 1_024
    private static let maximumOpusPacketsPerCallback = 32_768

    private enum Mode {
        case directPCM
        case converted(
            signature: FormatSignature,
            converter: AVAudioConverter,
            inputFormat: AVAudioFormat
        )
    }

    private struct FormatSignature: Equatable {
        let sampleRate: Double
        let formatID: AudioFormatID
        let formatFlags: AudioFormatFlags
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channelsPerFrame: UInt32
        let bitsPerChannel: UInt32

        init(_ value: AudioStreamBasicDescription) {
            sampleRate = value.mSampleRate
            formatID = value.mFormatID
            formatFlags = value.mFormatFlags
            bytesPerPacket = value.mBytesPerPacket
            framesPerPacket = value.mFramesPerPacket
            bytesPerFrame = value.mBytesPerFrame
            channelsPerFrame = value.mChannelsPerFrame
            bitsPerChannel = value.mBitsPerChannel
        }
    }

    private let allowFormatChanges: Bool
    private var sourceSignature: FormatSignature?
    init(allowFormatChanges: Bool = false) { self.allowFormatChanges = allowFormatChanges }
    private let lock = NSLock()
    private var mode: Mode?
    private var nextFrame = 0
    private var finished = false
    private var pendingPCM = Data()
    private var pendingPCMSignature: FormatSignature?

    func append(_ source: SiriSourceAudioChunk) throws -> [NormalizedPCMChunk] {
        try lock.withLock {
            guard !finished else {
                throw CLIError("Audio arrived after the Siri stream ended", code: .noAudio)
            }
            if source.audioData.isEmpty, source.packetCount == 0 {
                // sirittsd commonly emits empty, format-bearing callbacks.
                // They must not choose or change the stream format.
                return []
            }
            guard source.format.mSampleRate.isFinite,
                  source.format.mSampleRate > 0,
                  source.format.mChannelsPerFrame > 0 else {
                throw CLIError("Siri daemon returned an invalid audio format", code: .noAudio)
            }

            let signature = FormatSignature(source.format)
            var prefix: [NormalizedPCMChunk] = []
            if allowFormatChanges, let previous = sourceSignature, previous != signature {
                guard pendingPCM.isEmpty else { throw CLIError("Format changed with an incomplete PCM frame", code: .noAudio) }
                if case .converted(_, let converter, _) = mode { prefix = try drain(converter) }
                mode = nil
                pendingPCMSignature = nil
            }
            sourceSignature = signature
            switch source.format.mFormatID {
            case kAudioFormatLinearPCM:
                return prefix + (try appendPCM(source))
            case kAudioFormatOpus:
                return prefix + (try appendOpus(source))
            default:
                throw CLIError(
                    "Unsupported Siri daemon audio codec \(fourCC(source.format.mFormatID))",
                    code: .noAudio
                )
            }
        }
    }

    func finish() throws -> [NormalizedPCMChunk] {
        try lock.withLock {
            guard !finished else { return [] }
            finished = true
            guard pendingPCM.isEmpty else {
                throw CLIError("Siri daemon ended with a partial LPCM frame", code: .noAudio)
            }
            guard case .converted(_, let converter, _) = mode else { return [] }
            return try drain(converter)
        }
    }

    private func appendPCM(_ source: SiriSourceAudioChunk) throws -> [NormalizedPCMChunk] {
        let format = source.format
        guard source.audioData.count <= Self.maximumPCMCallbackBytes else {
            throw CLIError("Siri daemon returned an oversized LPCM callback", code: .noAudio)
        }
        guard format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              format.mBytesPerFrame > 0 else {
            throw CLIError("Siri daemon returned malformed LPCM frames", code: .noAudio)
        }
        let bytesPerFrame = Int(format.mBytesPerFrame)
        let completeFrames = source.audioData.count / bytesPerFrame
        if source.reportedSampleCount > 0,
           source.reportedSampleCount != completeFrames {
            throw CLIError("Siri daemon reported inconsistent LPCM sample counts", code: .noAudio)
        }
        let signature = FormatSignature(format)
        if let pendingPCMSignature, pendingPCMSignature != signature {
            throw CLIError("Siri daemon changed audio format during synthesis", code: .noAudio)
        }
        pendingPCMSignature = signature
        pendingPCM.append(source.audioData)
        let processableBytes = pendingPCM.count - pendingPCM.count % bytesPerFrame
        guard processableBytes > 0 else { return [] }
        let bytes = Data(pendingPCM.prefix(processableBytes))
        pendingPCM.removeFirst(processableBytes)
        let frames = bytes.count / bytesPerFrame
        guard frames > 0 else { return [] }

        if isCanonicalPCM(format) {
            guard mode == nil || isDirectMode else {
                throw CLIError("Siri daemon changed audio format during synthesis", code: .noAudio)
            }
            mode = .directPCM
            return [makeChunk(bytes)]
        }

        let inputFormat = try makeFormat(format)
        let converter = try converter(for: signature, inputFormat: inputFormat)
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else {
            throw CLIError("Could not allocate a Siri PCM input buffer", code: .noAudio)
        }
        input.frameLength = AVAudioFrameCount(frames)
        guard let destination = input.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw CLIError("Could not access a Siri PCM input buffer", code: .noAudio)
        }
        _ = bytes.withUnsafeBytes {
            memcpy(destination, $0.baseAddress!, bytes.count)
        }
        return try convert(input, estimatedFrames: frames, using: converter)
    }

    private func appendOpus(_ source: SiriSourceAudioChunk) throws -> [NormalizedPCMChunk] {
        let format = source.format
        guard source.audioData.count <= Self.maximumOpusCallbackBytes,
              source.packetCount <= Self.maximumOpusPacketsPerCallback else {
            throw CLIError("Siri daemon returned an oversized Opus callback", code: .noAudio)
        }
        guard format.mFramesPerPacket > 0,
              source.packetCount > 0,
              !source.audioData.isEmpty else {
            // A format-only callback is harmless, but encoded bytes without
            // packet metadata cannot be decoded safely.
            if source.audioData.isEmpty, source.packetCount == 0 { return [] }
            throw CLIError("Siri daemon returned malformed Opus packet metadata", code: .noAudio)
        }

        let descriptions = try packetDescriptions(
            source.packetDescriptions,
            count: source.packetCount,
            byteCount: source.audioData.count
        )
        var repackedData = Data()
        repackedData.reserveCapacity(source.audioData.count)
        var repackedDescriptions: [AudioStreamPacketDescription] = []
        repackedDescriptions.reserveCapacity(descriptions.count)
        for description in descriptions {
            let start = Int(description.mStartOffset)
            let end = start + Int(description.mDataByteSize)
            let repackedStart = repackedData.count
            repackedData.append(source.audioData[start..<end])
            repackedDescriptions.append(AudioStreamPacketDescription(
                mStartOffset: Int64(repackedStart),
                mVariableFramesInPacket: description.mVariableFramesInPacket,
                mDataByteSize: description.mDataByteSize
            ))
        }
        let signature = FormatSignature(format)
        let inputFormat = try makeFormat(format)
        let converter = try converter(for: signature, inputFormat: inputFormat)
        let maximumPacketSize = repackedDescriptions.map { Int($0.mDataByteSize) }.max() ?? 0
        guard maximumPacketSize > 0 else {
            throw CLIError("Could not allocate a Siri Opus input buffer", code: .noAudio)
        }
        let input = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: AVAudioPacketCount(source.packetCount),
            maximumPacketSize: maximumPacketSize
        )
        _ = repackedData.withUnsafeBytes {
            memcpy(input.data, $0.baseAddress!, repackedData.count)
        }
        input.byteLength = UInt32(repackedData.count)
        input.packetCount = AVAudioPacketCount(source.packetCount)
        guard let targetDescriptions = input.packetDescriptions else {
            throw CLIError("Could not allocate Siri Opus packet descriptions", code: .noAudio)
        }
        for (index, description) in repackedDescriptions.enumerated() {
            targetDescriptions[index] = description
        }
        let estimated = source.packetCount * Int(format.mFramesPerPacket)
        return try convert(input, estimatedFrames: estimated, using: converter)
    }

    private var isDirectMode: Bool {
        if case .directPCM = mode { return true }
        return false
    }

    private func converter(
        for signature: FormatSignature,
        inputFormat: AVAudioFormat
    ) throws -> AVAudioConverter {
        switch mode {
        case nil:
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: AudioSpec.siriPCM.sampleRate,
                channels: AVAudioChannelCount(AudioSpec.siriPCM.channels),
                interleaved: true
            ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw CLIError("Could not create the Siri audio converter", code: .noAudio)
            }
            mode = .converted(
                signature: signature,
                converter: converter,
                inputFormat: inputFormat
            )
            return converter
        case .converted(let existing, let converter, _):
            guard existing == signature else {
                throw CLIError("Siri daemon changed audio format during synthesis", code: .noAudio)
            }
            return converter
        case .directPCM:
            throw CLIError("Siri daemon changed audio format during synthesis", code: .noAudio)
        }
    }

    private func convert(
        _ input: AVAudioBuffer,
        estimatedFrames: Int,
        using converter: AVAudioConverter
    ) throws -> [NormalizedPCMChunk] {
        let provider = OneShotAudioInput(input)
        let capacity = AVAudioFrameCount(min(8_192, max(4_096, estimatedFrames + 1_024)))
        var chunks: [NormalizedPCMChunk] = []

        for _ in 0..<1_024 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: capacity
            ) else {
                throw CLIError("Could not allocate a Siri PCM output buffer", code: .noAudio)
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                provider.next(status: inputStatus)
            }
            if let conversionError {
                throw CLIError(
                    "Could not decode Siri audio: \(conversionError.localizedDescription)",
                    code: .noAudio
                )
            }
            if output.frameLength > 0 {
                chunks.append(try makeChunk(output))
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return chunks
            case .error:
                throw CLIError("Could not decode Siri audio", code: .noAudio)
            @unknown default:
                throw CLIError("Unknown Siri audio conversion state", code: .noAudio)
            }
        }
        throw CLIError("Siri audio converter did not consume its input", code: .noAudio)
    }

    private func drain(_ converter: AVAudioConverter) throws -> [NormalizedPCMChunk] {
        var chunks: [NormalizedPCMChunk] = []
        for _ in 0..<1_024 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: 4_096
            ) else {
                throw CLIError("Could not allocate a Siri PCM output buffer", code: .noAudio)
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError {
                throw CLIError(
                    "Could not finish decoding Siri audio: \(conversionError.localizedDescription)",
                    code: .noAudio
                )
            }
            if output.frameLength > 0 {
                chunks.append(try makeChunk(output))
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return chunks
            case .error:
                throw CLIError("Could not finish decoding Siri audio", code: .noAudio)
            @unknown default:
                throw CLIError("Unknown Siri audio conversion state", code: .noAudio)
            }
        }
        throw CLIError("Siri audio converter did not finish", code: .noAudio)
    }

    private func makeChunk(_ buffer: AVAudioPCMBuffer) throws -> NormalizedPCMChunk {
        guard buffer.format.commonFormat == .pcmFormatInt16,
              buffer.format.isInterleaved,
              buffer.format.sampleRate == AudioSpec.siriPCM.sampleRate,
              buffer.format.channelCount == 1,
              let pointer = buffer.audioBufferList.pointee.mBuffers.mData else {
            throw CLIError("The Siri converter returned a non-canonical PCM buffer", code: .noAudio)
        }
        let byteCount = Int(buffer.frameLength) * AudioSpec.siriPCM.bytesPerFrame
        return makeChunk(Data(bytes: pointer, count: byteCount))
    }

    private func makeChunk(_ data: Data) -> NormalizedPCMChunk {
        let frames = data.count / AudioSpec.siriPCM.bytesPerFrame
        let chunk = NormalizedPCMChunk(
            pcm: data,
            spec: .siriPCM,
            startFrame: nextFrame,
            frameCount: frames
        )
        nextFrame += frames
        return chunk
    }

    private func makeFormat(_ value: AudioStreamBasicDescription) throws -> AVAudioFormat {
        var copy = value
        guard let result = AVAudioFormat(streamDescription: &copy) else {
            throw CLIError("Siri daemon returned an unsupported audio format", code: .noAudio)
        }
        return result
    }

    private func packetDescriptions(
        _ data: Data,
        count: Int,
        byteCount: Int
    ) throws -> [AudioStreamPacketDescription] {
        let stride = MemoryLayout<AudioStreamPacketDescription>.stride
        guard count > 0, data.count == count * stride else {
            throw CLIError("Siri daemon returned truncated Opus packet descriptions", code: .noAudio)
        }
        var values: [AudioStreamPacketDescription] = []
        values.reserveCapacity(count)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for index in 0..<count {
                values.append(
                    base.advanced(by: index * stride)
                        .loadUnaligned(as: AudioStreamPacketDescription.self)
                )
            }
        }
        var previousEnd = 0
        for value in values {
            guard value.mStartOffset >= 0,
                  value.mDataByteSize > 0,
                  value.mStartOffset <= Int64(Int.max) else {
                throw CLIError("Siri daemon returned invalid Opus packet boundaries", code: .noAudio)
            }
            let start = Int(value.mStartOffset)
            let size = Int(value.mDataByteSize)
            let (end, overflow) = start.addingReportingOverflow(size)
            guard !overflow, start >= previousEnd, end <= byteCount else {
                throw CLIError("Siri daemon returned invalid Opus packet boundaries", code: .noAudio)
            }
            previousEnd = end
        }
        return values
    }

    private func isCanonicalPCM(_ value: AudioStreamBasicDescription) -> Bool {
        value.mFormatID == kAudioFormatLinearPCM &&
        value.mSampleRate == AudioSpec.siriPCM.sampleRate &&
        value.mChannelsPerFrame == 1 &&
        value.mBitsPerChannel == 16 &&
        value.mBytesPerFrame == 2 &&
        value.mFramesPerPacket == 1 &&
        value.mBytesPerPacket == 2 &&
        value.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 &&
        value.mFormatFlags & kAudioFormatFlagIsFloat == 0 &&
        value.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
        value.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }
}

private func fourCC(_ value: AudioFormatID) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
}
