import Foundation
import SiriTTSProtocol

struct TextChunk: Equatable, Sendable {
    let text: String
    let utf16Location: Int
}

enum TextChunker {
    static let defaultByteLimit = 4_000

    /// Splits text at natural boundaries without changing or dropping characters.
    /// A single extended grapheme may exceed the byte target, but it is never split.
    static func chunks(
        _ text: String,
        byteLimit: Int = defaultByteLimit
    ) -> [TextChunk] {
        precondition(byteLimit > 0)
        guard !text.isEmpty else { return [] }

        var result: [TextChunk] = []
        var start = text.startIndex
        var utf16Location = 0

        while start < text.endIndex {
            var cursor = start
            var bytes = 0
            var preferredBoundary: String.Index?
            var sentenceBoundary: String.Index?
            var sentenceEnded = false

            while cursor < text.endIndex {
                let next = text.index(after: cursor)
                let character = text[cursor..<next]
                let characterBytes = character.utf8.count
                if bytes > 0, bytes + characterBytes > byteLimit { break }
                bytes += characterBytes
                cursor = next
                if character.last?.isWhitespace == true {
                    if sentenceEnded || character.last?.isNewline == true {
                        sentenceBoundary = cursor
                    }
                } else if let last = character.last, ".!?".contains(last) {
                    sentenceEnded = true
                } else if let last = character.last, !"\"'”’)]}".contains(last) {
                    sentenceEnded = false
                }
                if character.last?.isWhitespace == true ||
                    character.last.map({ ".!?;:".contains($0) }) == true {
                    preferredBoundary = cursor
                }
                if bytes >= byteLimit { break }
            }

            let boundary: String.Index
            if cursor == text.endIndex {
                boundary = cursor
            } else if let sentenceBoundary, sentenceBoundary > start {
                boundary = sentenceBoundary
            } else if let preferredBoundary, preferredBoundary > start {
                boundary = preferredBoundary
            } else {
                boundary = cursor
            }

            let value = String(text[start..<boundary])
            result.append(TextChunk(text: value, utf16Location: utf16Location))
            utf16Location += value.utf16.count
            start = boundary
        }
        return result
    }
}

struct IncrementalSynthesisResult: Sendable {
    let spec: AudioSpec
    let voice: VoiceInfo
    let timings: [RawWordTiming]
    let timingsSupported: Bool
    let engine: EngineKind
    let fallbackFrom: EngineKind?
    let elapsed: TimeInterval
    let timeToFirstAudio: TimeInterval?
    let bytes: Int
    let nonSilent: Bool
    let sampleCount: Int
    let durationSeconds: TimeInterval
    let diagnostics: [SynthesisDiagnostics]
}

enum LongFormSynthesis {
    // Longer FM requests omitted complete sentences in the chapter acceptance
    // run. Keep plain-text requests short even when callers set a larger target.
    static let expressiveChunkByteLimit = 400
    /// Renders bounded pieces sequentially and releases each piece after the sink
    /// accepts it. Memory use therefore follows chunk size instead of audio length.
    static func render(
        _ options: SynthesisOptions,
        coordinator: EngineCoordinator,
        chunkByteLimit: Int? = nil,
        onProvisionalPCMChunk: (@Sendable (Data) -> Void)? = nil,
        sink: (Data) throws -> Void
    ) throws -> IncrementalSynthesisResult {
        let started = Date()
        if options.ssml { try SSML.validate(options.text) }
        var byteLimit = chunkByteLimit ?? options.chunkBytes
        if !options.ssml, options.engine != .av, byteLimit > expressiveChunkByteLimit {
            let expressive = options.controls.requiresExpressiveVoice ||
                (try? VoiceResolver.select(options, from: coordinator.siri.voices(timeout: min(10, options.timeout))))?.assetKey.contains(":fmvoice:") == true
            if expressive { byteLimit = expressiveChunkByteLimit }
        }
        let chunks = options.ssml ? [TextChunk(text: options.text, utf16Location: 0)] : TextChunker.chunks(options.text, byteLimit: byteLimit)
        var selectedEngine: EngineKind?
        var selectedVoice: VoiceInfo?
        var selectedSpec: AudioSpec?
        var fallbackFrom: EngineKind?
        var diagnostics: [SynthesisDiagnostics] = []
        var timings: [RawWordTiming] = []
        var timingsSupported = true
        var nonSilent = false
        var byteCount = 0
        var sampleCount = 0
        var duration = 0.0
        var timeToFirstAudio: TimeInterval?

        for chunk in chunks where !chunk.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            var chunkOptions = options
            chunkOptions.text = chunk.text
            chunkOptions.inputFile = nil
            chunkOptions.output = nil
            let remaining = options.timeout - Date().timeIntervalSince(started)
            guard remaining > 0 else { throw CLIError("Long-form request timed out", code: .operationTimedOut) }
            chunkOptions.timeout = remaining
            if options.engine == .auto, let selectedEngine {
                chunkOptions.engine = selectedEngine
            }

            let rendered = try coordinator.render(
                chunkOptions,
                onPCMChunk: onProvisionalPCMChunk
            )
            if let diagnostic = rendered.audio.diagnostics { diagnostics.append(diagnostic) }
            let acceptance = try AudioIO.validatePCM(
                rendered.audio.pcm,
                spec: rendered.audio.spec,
                text: chunk.text,
                allowSilence: options.volume == 0
            )

            if let selectedSpec, selectedSpec != rendered.audio.spec {
                throw CLIError(
                    "Speech format changed between long-form chunks",
                    code: .noAudio
                )
            }
            if let selectedVoice,
               selectedVoice.assetKey != rendered.audio.voice.assetKey {
                throw CLIError(
                    "Speech voice changed between long-form chunks",
                    code: .noAudio
                )
            }

            if selectedEngine == nil {
                selectedEngine = rendered.audio.engine
                selectedVoice = rendered.audio.voice
                selectedSpec = rendered.audio.spec
                fallbackFrom = rendered.fallbackFrom
                timeToFirstAudio = rendered.audio.timeToFirstAudio
            }

            timings.append(contentsOf: rendered.audio.timings.map {
                RawWordTiming(
                    start: $0.start + duration,
                    range: NSRange(
                        location: $0.range.location + chunk.utf16Location,
                        length: $0.range.length
                    )
                )
            })
            timingsSupported = timingsSupported && rendered.audio.timingsSupported
            if onProvisionalPCMChunk == nil {
                try sink(rendered.audio.pcm)
            }
            nonSilent = nonSilent || acceptance.nonSilent
            byteCount += acceptance.bytes
            sampleCount += acceptance.sampleCount
            duration += acceptance.durationSeconds
        }

        guard let spec = selectedSpec,
              let voice = selectedVoice,
              let engine = selectedEngine,
              byteCount > 0 else {
            throw CLIError("Synthesis produced no spoken audio", code: .noAudio)
        }
        return IncrementalSynthesisResult(
            spec: spec,
            voice: voice,
            timings: timings,
            timingsSupported: timingsSupported,
            engine: engine,
            fallbackFrom: fallbackFrom,
            elapsed: Date().timeIntervalSince(started),
            timeToFirstAudio: timeToFirstAudio,
            bytes: byteCount,
            nonSilent: nonSilent,
            sampleCount: sampleCount,
            durationSeconds: duration,
            diagnostics: diagnostics
        )
    }
}
