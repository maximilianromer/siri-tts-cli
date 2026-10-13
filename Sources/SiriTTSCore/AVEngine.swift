@preconcurrency import AVFoundation
import Foundation

public final class AVEngine: @unchecked Sendable {
    private let lifecycle = SynthesisLifecycle<AVSpeechSynthesizer>()

    public init() {}

    public func voices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .map {
                VoiceInfo(
                    name: $0.name,
                    language: $0.language,
                    assetKey: $0.identifier,
                    version: 0,
                    engine: EngineKind.av.rawValue
                )
            }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    public func synthesize(
        _ options: SynthesisOptions,
        onPCMChunk: (@Sendable (Data) -> Void)? = nil
    ) throws -> RenderedAudio {
        let token = lifecycle.acquire()
        defer { lifecycle.finish(token) }

        let voice = try selectVoice(options)
        let utterance = AVSpeechUtterance(string: options.text)
        utterance.voice = voice
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(
            AVSpeechUtteranceMaximumSpeechRate,
            AVSpeechUtteranceDefaultSpeechRate * options.rate
        ))
        utterance.pitchMultiplier = max(0.5, min(2, options.pitch))
        utterance.volume = max(0, min(1, options.volume))

        let synthesizer = AVSpeechSynthesizer()
        guard lifecycle.attach(synthesizer, to: token) else {
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }

        let started = Date()
        let accumulator = AVAccumulator()
        synthesizer.write(utterance) { buffer in
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                accumulator.fail(CLIError("AVSpeechSynthesizer returned non-PCM audio", code: .noAudio))
                accumulator.markDone()
                return
            }
            guard pcmBuffer.frameLength > 0 else {
                accumulator.markDone()
                return
            }
            do {
                let data = try AVPCMConverter.convert(pcmBuffer)
                accumulator.append(data)
                onPCMChunk?(data)
            } catch {
                accumulator.fail(error)
                accumulator.markDone()
            }
        }

        let deadline = Date(timeIntervalSinceNow: options.timeout)
        while !accumulator.isDone, Date() < deadline {
            if lifecycle.isCancelled(token) {
                throw CLIError("Synthesis cancelled", code: .cancelled)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard accumulator.isDone else {
            synthesizer.stopSpeaking(at: .immediate)
            throw CLIError("Timed out waiting for AVSpeechSynthesizer", code: .daemonUnreachable)
        }
        if let error = accumulator.snapshot().error { throw error }
        guard lifecycle.claimCompletion(token) else {
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
        let pcm = accumulator.snapshot().data
        let acceptance = try AudioIO.validatePCM(pcm, spec: .siriPCM, text: options.text, allowSilence: options.volume == 0)
        let voiceInfo = VoiceInfo(
            name: voice.name,
            language: voice.language,
            assetKey: voice.identifier,
            version: 0,
            engine: EngineKind.av.rawValue
        )
        return RenderedAudio(
            pcm: pcm,
            spec: .siriPCM,
            voice: voiceInfo,
            timings: [],
            timingsSupported: false,
            engine: .av,
            elapsed: Date().timeIntervalSince(started),
            timeToFirstAudio: accumulator.snapshot().firstAudioAt.map {
                $0.timeIntervalSince(started)
            },
            nonSilent: acceptance.nonSilent
        )
    }

    public func cancel() {
        _ = lifecycle.cancelActive()?.stopSpeaking(at: .immediate)
    }

    private func selectVoice(_ options: SynthesisOptions) throws -> AVSpeechSynthesisVoice {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            options.language == nil ||
            $0.language.caseInsensitiveCompare(options.language!) == .orderedSame
        }
        if let wanted = options.voice {
            guard let match = voices.first(where: {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame ||
                $0.identifier.caseInsensitiveCompare(wanted) == .orderedSame
            }) else {
                throw CLIError(
                    "AVSpeechSynthesizer voice '\(wanted)' was not found",
                    code: .voiceNotFound
                )
            }
            return match
        }
        if let language = options.language,
           let defaultVoice = AVSpeechSynthesisVoice(language: language) {
            return defaultVoice
        }
        guard let voice = AVSpeechSynthesisVoice(language: "en-US") ?? voices.first else {
            throw CLIError("No AVSpeechSynthesizer voice is available", code: .noCompatibleEngine)
        }
        return voice
    }
}

private enum AVPCMConverter {
    static func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw CLIError("Could not configure AV audio conversion", code: .noAudio)
        }

        let ratio = 48_000 / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CLIError("Could not allocate AV audio conversion buffer", code: .noAudio)
        }
        let source = ConverterInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            guard let buffer = source.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw CLIError(
                "AV audio conversion failed: \(conversionError?.localizedDescription ?? "unknown error")",
                code: .noAudio
            )
        }
        let bytes = Int(output.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        guard let pointer = output.audioBufferList.pointee.mBuffers.mData else {
            throw CLIError("AV audio conversion returned no data", code: .noAudio)
        }
        return Data(bytes: pointer, count: bytes)
    }
}

private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { buffer = nil }
            return buffer
        }
    }
}

private final class AVAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var error: Error?
    private var firstAudioAt: Date?
    private var done = false

    func append(_ chunk: Data) {
        lock.withLock {
            if !chunk.isEmpty, firstAudioAt == nil { firstAudioAt = Date() }
            data.append(chunk)
        }
    }

    func fail(_ error: Error) {
        lock.withLock { self.error = error }
    }

    func markDone() {
        lock.withLock { done = true }
    }

    var isDone: Bool {
        lock.withLock { done }
    }

    func snapshot() -> (data: Data, error: Error?, firstAudioAt: Date?) {
        lock.withLock { (data, error, firstAudioAt) }
    }
}
