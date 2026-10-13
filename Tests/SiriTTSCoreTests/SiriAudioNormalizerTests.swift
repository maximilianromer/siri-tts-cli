@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudioTypes
import Foundation
import XCTest
@testable import SiriTTSCore

final class SiriAudioNormalizerTests: XCTestCase {
    func testCanonicalPCMStreamsWithStableFrameOffsets() throws {
        let normalizer = SiriAudioNormalizer()
        let first = pcmFixture(frames: 480)
        let second = pcmFixture(frames: 960)

        let firstOutput = try normalizer.append(source(first, samples: 480))
        let secondOutput = try normalizer.append(source(second, samples: 960))
        XCTAssertEqual(firstOutput.count, 1)
        XCTAssertEqual(firstOutput[0].pcm, first)
        XCTAssertEqual(firstOutput[0].spec, .siriPCM)
        XCTAssertEqual(firstOutput[0].startFrame, 0)
        XCTAssertEqual(firstOutput[0].frameCount, 480)
        XCTAssertEqual(secondOutput[0].startFrame, 480)
        XCTAssertEqual(secondOutput[0].frameCount, 960)
        XCTAssertEqual(try normalizer.finish(), [])
    }

    func testCanonicalPCMDoesNotTreatFrameCountAsOpusPacketCount() throws {
        // sirittsd may put the LPCM frame count in the packet-count callback
        // argument. A perfectly ordinary callback can therefore exceed the
        // encoded-audio packet limit even though its PCM payload is small.
        let frames = 40_000
        let pcm = pcmFixture(frames: frames)
        let output = try SiriAudioNormalizer().append(SiriSourceAudioChunk(
            audioData: pcm,
            format: AudioSpec.siriPCM.asbd,
            packetDescriptions: Data(),
            packetCount: frames,
            reportedSampleCount: frames
        ))

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].pcm, pcm)
        XCTAssertEqual(output[0].frameCount, frames)
    }

    func testCanonicalPCMBuffersSplitFrames() throws {
        let normalizer = SiriAudioNormalizer()
        let pcm = pcmFixture(frames: 3)
        let first = try normalizer.append(source(Data(pcm.prefix(1)), samples: 0))
        let second = try normalizer.append(source(Data(pcm.dropFirst(1)), samples: 2))

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].pcm, pcm)
        XCTAssertEqual(second[0].frameCount, 3)
        XCTAssertNoThrow(try normalizer.finish())
    }

    func testStereoFloatPCMIsDownmixedAndResampled() throws {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 2,
            interleaved: true
        ) else {
            throw XCTSkip("Could not create the PCM conversion fixture")
        }
        let frames = 4_800
        var samples: [Float] = []
        samples.reserveCapacity(frames * 2)
        for index in 0..<frames {
            let value = sin(Float(index) * 2 * .pi * 220 / 24_000) * 0.25
            samples.append(value)
            samples.append(value * 0.5)
        }
        let data = samples.withUnsafeBytes { Data($0) }
        let normalizer = SiriAudioNormalizer()
        let chunks = try normalizer.append(SiriSourceAudioChunk(
            audioData: data,
            format: sourceFormat.streamDescription.pointee,
            packetDescriptions: Data(),
            packetCount: 0,
            reportedSampleCount: frames
        )) + normalizer.finish()
        let pcm = chunks.reduce(into: Data()) { $0.append($1.pcm) }
        let accepted = try AudioIO.validatePCM(
            pcm,
            spec: .siriPCM,
            text: "stereo float fixture"
        )
        XCTAssertEqual(accepted.durationSeconds, 0.2, accuracy: 0.005)
        XCTAssertTrue(chunks.allSatisfy { $0.spec == .siriPCM })
    }

    func testTerminalPartialPCMFrameFails() throws {
        let normalizer = SiriAudioNormalizer()
        XCTAssertEqual(
            try normalizer.append(source(Data([0x01]), samples: 0)),
            []
        )
        XCTAssertThrowsError(try normalizer.finish())
    }

    func testEmptyPlaceholderDoesNotLockFormat() throws {
        let normalizer = SiriAudioNormalizer()
        var placeholder = AudioStreamBasicDescription()
        placeholder.mFormatID = kAudioFormatOpus
        XCTAssertEqual(try normalizer.append(SiriSourceAudioChunk(
            audioData: Data(),
            format: placeholder,
            packetDescriptions: Data(),
            packetCount: 0,
            reportedSampleCount: 0
        )), [])

        let pcm = pcmFixture(frames: 48)
        XCTAssertEqual(
            try normalizer.append(source(pcm, samples: 48)).first?.pcm,
            pcm
        )
    }

    func testRejectsChangedNonemptyFormat() throws {
        let normalizer = SiriAudioNormalizer()
        _ = try normalizer.append(source(pcmFixture(frames: 48), samples: 48))
        var changed = AudioSpec.siriPCM.asbd
        changed.mSampleRate = 24_000
        XCTAssertThrowsError(try normalizer.append(SiriSourceAudioChunk(
            audioData: pcmFixture(frames: 48),
            format: changed,
            packetDescriptions: Data(),
            packetCount: 0,
            reportedSampleCount: 48
        )))
    }

    func testRejectsMalformedOpusPacketDescriptions() {
        let normalizer = SiriAudioNormalizer()
        var opus = AudioStreamBasicDescription()
        opus.mSampleRate = 48_000
        opus.mFormatID = kAudioFormatOpus
        opus.mFramesPerPacket = 960
        opus.mChannelsPerFrame = 1
        XCTAssertThrowsError(try normalizer.append(SiriSourceAudioChunk(
            audioData: Data(repeating: 1, count: 32),
            format: opus,
            packetDescriptions: Data(repeating: 0, count: 3),
            packetCount: 1,
            reportedSampleCount: 0
        )))
    }

    func testRejectsUnsupportedEncodedFormat() {
        let normalizer = SiriAudioNormalizer()
        var format = AudioStreamBasicDescription()
        format.mSampleRate = 48_000
        format.mFormatID = kAudioFormatMPEGLayer3
        format.mChannelsPerFrame = 1
        XCTAssertThrowsError(try normalizer.append(SiriSourceAudioChunk(
            audioData: Data(repeating: 1, count: 32),
            format: format,
            packetDescriptions: Data(),
            packetCount: 1,
            reportedSampleCount: 0
        )))
    }

    func testPacketizedOpusDecodesIncrementallyToCanonicalPCM() throws {
        let encoded = try makeOpusFixture(frames: 24_000)
        XCTAssertGreaterThan(encoded.packetCount, 1)
        let normalizer = SiriAudioNormalizer()
        let chunks = try normalizer.append(encoded) + normalizer.finish()
        let pcm = chunks.reduce(into: Data()) { $0.append($1.pcm) }

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy {
            $0.spec == .siriPCM &&
            $0.pcm.count == $0.frameCount * AudioSpec.siriPCM.bytesPerFrame
        })
        XCTAssertEqual(
            chunks.map(\.startFrame),
            chunks.dropLast().reduce(into: [0]) { offsets, chunk in
                offsets.append((offsets.last ?? 0) + chunk.frameCount)
            }
        )
        let accepted = try AudioIO.validatePCM(pcm, spec: .siriPCM, text: "Opus fixture")
        XCTAssertGreaterThan(accepted.durationSeconds, 0.40)
        XCTAssertLessThan(accepted.durationSeconds, 0.55)
    }

    func testNativeTextStreamCanTransitionBetweenPCMAndCachedOpus() throws {
        let encoded = try makeOpusFixture(frames: 24000)
        let normalizer = SiriAudioNormalizer(allowFormatChanges: true)
        let pcm = pcmFixture(frames:4800)
        let chunks = try normalizer.append(source(pcm,samples:4800)) + normalizer.append(encoded) + normalizer.append(source(pcm,samples:4800)) + normalizer.finish()
        var nextFrame = 0
        for chunk in chunks { XCTAssertEqual(chunk.startFrame,nextFrame); nextFrame += chunk.frameCount }
        XCTAssertGreaterThan(nextFrame,28000)
        let strict = SiriAudioNormalizer()
        _ = try strict.append(source(pcm,samples:4800))
        XCTAssertThrowsError(try strict.append(encoded))
    }

    func testOpusPacketOffsetOutsidePayloadFails() throws {
        var encoded = try makeOpusFixture(frames: 4_800)
        var descriptions = encoded.packetDescriptions
        descriptions.withUnsafeMutableBytes {
            $0.baseAddress!.storeBytes(
                of: AudioStreamPacketDescription(
                    mStartOffset: Int64(encoded.audioData.count + 1),
                    mVariableFramesInPacket: 0,
                    mDataByteSize: 8
                ),
                as: AudioStreamPacketDescription.self
            )
        }
        encoded = SiriSourceAudioChunk(
            audioData: encoded.audioData,
            format: encoded.format,
            packetDescriptions: descriptions,
            packetCount: encoded.packetCount,
            reportedSampleCount: 0
        )
        XCTAssertThrowsError(try SiriAudioNormalizer().append(encoded))
    }

    private func source(_ data: Data, samples: Int) -> SiriSourceAudioChunk {
        SiriSourceAudioChunk(
            audioData: data,
            format: AudioSpec.siriPCM.asbd,
            packetDescriptions: Data(),
            packetCount: 0,
            reportedSampleCount: samples
        )
    }

    private func pcmFixture(frames: Int) -> Data {
        var result = Data(capacity: frames * 2)
        for index in 0..<frames {
            var sample = Int16(sin(Double(index) / 10) * 12_000).littleEndian
            withUnsafeBytes(of: &sample) { result.append(contentsOf: $0) }
        }
        return result
    }

    private func makeOpusFixture(frames: Int) throws -> SiriSourceAudioChunk {
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ), let pcm = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else {
            throw XCTSkip("This macOS build does not expose the Opus converter")
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard let base = UnsafeMutableAudioBufferListPointer(
            pcm.mutableAudioBufferList
        )[0].mData else {
            throw XCTSkip("Could not allocate the Opus fixture buffer")
        }
        let samples = base.bindMemory(to: Int16.self, capacity: frames)
        for index in 0..<frames {
            let phase = index % 240
            let triangle = phase < 120 ? phase : 240 - phase
            samples[index] = Int16((triangle - 60) * 300)
        }
        var opusASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let opusFormat = AVAudioFormat(streamDescription: &opusASBD),
              let converter = AVAudioConverter(from: pcmFormat, to: opusFormat),
              converter.maximumOutputPacketSize > 0 else {
            throw XCTSkip("This macOS build does not expose the Opus converter")
        }

        let provider = TestAudioInput(pcm)
        var aggregate = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        for _ in 0..<64 {
            let output = AVAudioCompressedBuffer(
                format: opusFormat,
                packetCapacity: 32,
                maximumPacketSize: converter.maximumOutputPacketSize
            )
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                provider.next(status: inputStatus)
            }
            if let conversionError { throw conversionError }
            if output.packetCount > 0 {
                let base = aggregate.count
                aggregate.append(Data(bytes: output.data, count: Int(output.byteLength)))
                guard let sourceDescriptions = output.packetDescriptions else {
                    throw XCTSkip("Opus encoder omitted packet descriptions")
                }
                for index in 0..<Int(output.packetCount) {
                    var value = sourceDescriptions[index]
                    value.mStartOffset += Int64(base)
                    descriptions.append(value)
                }
            }
            if status == .error {
                throw NSError(
                    domain: "SiriAudioNormalizerTests.OpusEncoder",
                    code: 1
                )
            }
            if status == .endOfStream {
                var descriptionData = Data()
                for var value in descriptions {
                    withUnsafeBytes(of: &value) {
                        descriptionData.append(contentsOf: $0)
                    }
                }
                return SiriSourceAudioChunk(
                    audioData: aggregate,
                    format: opusASBD,
                    packetDescriptions: descriptionData,
                    packetCount: descriptions.count,
                    reportedSampleCount: 0
                )
            }
        }
        throw NSError(domain: "SiriAudioNormalizerTests.OpusEncoder", code: 2)
    }
}

private final class TestAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioBuffer?

    init(_ buffer: AVAudioBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard let buffer else {
                status.pointee = .endOfStream
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}
