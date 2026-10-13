import Foundation
import XCTest
@testable import SiriTTSCore

final class LiveSystemTests: XCTestCase {
    private func requireLiveTests() throws {
        guard ProcessInfo.processInfo.environment["SIRI_TTS_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SIRI_TTS_LIVE_TESTS=1 to exercise installed voices")
        }
    }

    func testInstalledSiriVoiceProducesAcceptedAudioAndTimings() throws {
        try requireLiveTests()
        let engine = SiriEngine()
        guard let voice = try engine.voices().first(where: { $0.language == "en-US" && $0.assetKey.contains(":natural:") }) else {
            return XCTFail("Install a legacy en-US Siri voice for the English timing test")
        }
        var options = SynthesisOptions()
        options.text = "The quiet river flows beside the old stone bridge."
        options.voice = voice.assetKey
        options.controls.generation = .legacy
        options.requestTimings = true
        let rendered = try engine.synthesize(options)
        let accepted = try AudioIO.validatePCM(rendered.pcm, spec: rendered.spec, text: options.text)
        XCTAssertGreaterThan(accepted.durationSeconds, 0.1)
        XCTAssertTrue(accepted.nonSilent)
        XCTAssertEqual(rendered.engine, .siri)
        XCTAssertTrue(rendered.timingsSupported)
        XCTAssertFalse(rendered.timings.isEmpty, "Legacy synthesis must return requested word timings: \(voice.assetKey), \(String(describing: rendered.diagnostics))")
        let mapped = try WordTimingMapper.map(
            rendered.timings,
            in: options.text,
            duration: accepted.durationSeconds
        )
        XCTAssertTrue(mapped.allSatisfy { $0.start <= $0.end })
    }

    func testUnicodeTimingRangesRemainInBounds() throws {
        try requireLiveTests()
        let engine = SiriEngine()
        guard let voice = try engine.voices().first(where: { $0.language == "en-US" && $0.assetKey.contains(":natural:") }) else {
            throw XCTSkip("No installed legacy en-US Siri voice")
        }
        var options = SynthesisOptions()
        // Use text the selected English frontend can pronounce. Synthetic
        // emoji/CJK ranges are covered independently in WordTimingTests.
        options.text = "Welcome to the café. A naïve visitor reads a résumé."
        options.voice = voice.assetKey
        options.controls.generation = .legacy
        options.requestTimings = true
        let rendered = try engine.synthesize(options)
        let accepted = try AudioIO.validatePCM(rendered.pcm, spec: rendered.spec, text: options.text)
        XCTAssertTrue(rendered.timingsSupported)
        XCTAssertFalse(rendered.timings.isEmpty, "Legacy Unicode synthesis must return requested word timings")
        let mapped = try WordTimingMapper.map(
            rendered.timings,
            in: options.text,
            duration: accepted.durationSeconds
        )
        XCTAssertTrue(mapped.allSatisfy {
            $0.utf16Location + $0.utf16Length <= options.text.utf16.count
        })
    }

    func testLegacyParagraphTimingsMatchOriginalWordsAcrossChunks() throws {
        try requireLiveTests()
        guard let voice = try SiriEngine().voices().first(where: { $0.language == "en-US" && $0.assetKey.contains(":natural:") }) else {
            return XCTFail("Install a legacy en-US Siri voice for the English timing test")
        }
        var options = SynthesisOptions()
        options.text = "  The quiet river flows beside the old stone bridge.\n\nMara   opens the library before the morning train arrives.\r\n\r\nOliver\tbrings a wooden cabinet with narrow drawers and bright handles.\n\nTogether they place the maps on the table for everyone to see.  "
        options.voice = voice.assetKey
        options.controls.generation = .legacy
        options.requestTimings = true
        options.chunkBytes = 100
        let result = try LongFormSynthesis.render(options, coordinator: EngineCoordinator(), sink: { _ in })
        XCTAssertGreaterThan(result.diagnostics.count, 1)
        XCTAssertTrue(result.timingsSupported)
        let mapped = try WordTimingMapper.map(result.timings, in: options.text, duration: result.durationSeconds)
        let expected = options.text.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }
        // The native frontend sometimes groups adjacent words into one range.
        let actual = mapped.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }.map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(result.diagnostics.allSatisfy { $0.verified && $0.resolvedVoice == voice.assetKey })
    }

    func testPublicAVFallbackEngineProducesAcceptedAudio() throws {
        try requireLiveTests()
        var options = SynthesisOptions()
        options.text = "Public engine live test \(UUID().uuidString.prefix(8))."
        options.engine = .av
        options.language = "en-US"
        let rendered = try AVEngine().synthesize(options)
        let accepted = try AudioIO.validatePCM(rendered.pcm, spec: rendered.spec, text: options.text)
        XCTAssertGreaterThan(accepted.durationSeconds, 0.1)
        XCTAssertEqual(rendered.spec, .siriPCM)
        XCTAssertFalse(rendered.timingsSupported)
    }

    func testAVFallbackSerializesCancellationAndRecovers() throws {
        try requireLiveTests()
        let engine = AVEngine()
        var first = SynthesisOptions()
        first.engine = .av
        first.language = "en-US"
        first.text = String(
            repeating: "The first fallback request remains active until cancelled. ",
            count: 200
        )
        var second = SynthesisOptions()
        second.engine = .av
        second.language = "en-US"
        second.text = "The queued fallback request completes normally."
        let firstOptions = first
        let secondOptions = second

        let firstAudio = expectation(description: "first AV request produced audio")
        let firstFinished = expectation(description: "first AV request returned")
        let secondAttempted = expectation(description: "second AV request attempted")
        let secondFinished = expectation(description: "second AV request returned")
        let state = AVConcurrencyState(firstAudio: firstAudio)

        DispatchQueue.global().async {
            defer { firstFinished.fulfill() }
            do {
                _ = try engine.synthesize(firstOptions, onPCMChunk: state.recordFirstAudio)
                state.setFirst(nil)
            } catch let error as CLIError {
                state.setFirst(error.code)
            } catch {
                state.setFirst(.internalFailure)
            }
        }
        wait(for: [firstAudio], timeout: 10)

        DispatchQueue.global().async {
            secondAttempted.fulfill()
            defer { secondFinished.fulfill() }
            do {
                let rendered = try engine.synthesize(secondOptions, onPCMChunk: state.recordSecondAudio)
                _ = try AudioIO.validatePCM(
                    rendered.pcm,
                    spec: rendered.spec,
                    text: secondOptions.text
                )
                state.setSecond(nil)
            } catch let error as CLIError {
                state.setSecond(error.code)
            } catch {
                state.setSecond(.internalFailure)
            }
        }
        wait(for: [secondAttempted], timeout: 2)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(state.secondProducedAudio)

        engine.cancel()
        wait(for: [firstFinished, secondFinished], timeout: 15)
        XCTAssertEqual(state.firstExitCode, .cancelled)
        XCTAssertNil(state.secondExitCode)
        XCTAssertTrue(state.secondProducedAudio)
    }

    func testLongFormRendererCombinesBoundedChunks() throws {
        try requireLiveTests()
        var options = SynthesisOptions()
        options.engine = .av
        options.language = "en-US"
        options.text = "First bounded sentence. Second bounded sentence. Third bounded sentence."
        XCTAssertGreaterThan(TextChunker.chunks(options.text, byteLimit: 30).count, 1)

        var pcm = Data()
        let rendered = try LongFormSynthesis.render(
            options,
            coordinator: EngineCoordinator(),
            chunkByteLimit: 30,
            sink: { pcm.append($0) }
        )

        XCTAssertEqual(rendered.bytes, pcm.count)
        XCTAssertEqual(rendered.engine, .av)
        _ = try AudioIO.validatePCM(pcm, spec: rendered.spec, text: options.text)
    }

    func testOpenAIEndpointProducesReadableWAV() throws {
        try requireLiveTests()
        let coordinator = EngineCoordinator()
        guard let voice = try coordinator.siri.voices().first(where: { !$0.assetKey.contains(":fmvoice:") }) else {
            return XCTFail("No installed Siri voice")
        }
        var serverOptions = ServeOptions()
        serverOptions.engine = .siri
        let server = SpeechServer(options: serverOptions, coordinator: coordinator)
        let body = try JSONEncoder().encode(SpeechAPIRequest(
            model: "tts-1",
            input: "Endpoint test \(UUID().uuidString.prefix(8)).",
            voice: voice.name,
            responseFormat: "wav",
            speed: 1
        ))
        let response = try server.route(HTTPRequest(
            method: "POST",
            path: "/v1/audio/speech",
            headers: ["content-type": "application/json"],
            body: body
        ))
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
            return XCTFail("Missing HTTP header delimiter")
        }
        let header = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        let wav = Data(response[separator.upperBound...])
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertGreaterThan(wav.count, 44)
    }

    func testInstalledInventoryRefreshAndIdleCancelAreSafe() throws {
        try requireLiveTests()
        let engine = SiriEngine(keepActive: true)
        let initial = try engine.voices()
        XCTAssertFalse(initial.isEmpty)
        engine.cancel() // An idle cancel must not poison the next operation.
        let refreshed = try engine.refreshInstalledVoices()
        XCTAssertEqual(
            Set(refreshed.map(\.assetKey)),
            Set(initial.map(\.assetKey))
        )
        engine.invalidateVoiceCache()
        XCTAssertEqual(
            Set(try engine.voices().map(\.assetKey)),
            Set(refreshed.map(\.assetKey))
        )

        let selected = try engine.prewarm(voice: refreshed[0].assetKey)
        XCTAssertEqual(selected.assetKey, refreshed[0].assetKey)
    }

    func testStableDownloadableIdentityMapsAcrossInstalledOperations() throws {
        try requireLiveTests()
        let engine = SiriEngine()
        let catalog = try engine.availableVoices()
        guard let voice = catalog.first(where: {
            $0.installed && $0.assetKey.hasPrefix("com.apple.speech.synthesis.voice.")
        }) else {
            return XCTFail("No installed voice was mapped into the downloadable catalog")
        }

        let status = try engine.installationStatus(for: voice.assetKey)
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.assetKey, voice.assetKey)
        XCTAssertEqual(status.voice?.assetKey, voice.assetKey)

        let waited = try engine.waitForVoiceInstallation(
            assetKey: voice.assetKey,
            timeout: 1,
            pollInterval: 0.1
        )
        XCTAssertEqual(waited.state, .installed)
        XCTAssertEqual(waited.voice?.assetKey, voice.assetKey)

        let prewarmed = try engine.prewarm(voice: voice.assetKey)
        XCTAssertEqual(prewarmed.assetKey, voice.assetKey)

        if let notInstalled = catalog.first(where: { !$0.installed }) {
            let missingStatus = try engine.installationStatus(for: notInstalled.assetKey)
            XCTAssertEqual(missingStatus.state, .notInstalled)
            XCTAssertEqual(missingStatus.assetKey, notInstalled.assetKey)
            XCTAssertNil(missingStatus.voice)
        }
    }

    func testEveryDownloadableCatalogVoiceConstructsSubscriptionIdentity() throws {
        try requireLiveTests()
        let catalog = try SiriDownloadableVoiceCatalog.voices()
        XCTAssertFalse(catalog.isEmpty)

        for voice in catalog {
            let native = try voice.makeSynthesisVoice()
            XCTAssertEqual(native.assetKey, voice.nativeAssetKey, voice.catalogAssetKey)
        }
    }

    func testEveryInstalledLegacySiriVoiceProducesCanonicalStreamEvents() throws {
        try requireLiveTests()
        let engine = SiriEngine(keepActive: true)
        let voices = try engine.refreshInstalledVoices().filter { !$0.assetKey.contains(":fmvoice:") }
        XCTAssertFalse(voices.isEmpty)

        for voice in voices {
            var options = SynthesisOptions()
            options.text = "Canonical stream test for \(voice.name), \(UUID().uuidString.prefix(6))."
            options.voice = voice.assetKey
            options.requestTimings = true
            let capture = LockedStreamCapture()
            let rendered = try engine.synthesize(options, onEvent: capture.append)
            let events = capture.events
            let audioChunks = events.compactMap {
                if case .audio(let chunk) = $0 { return chunk }
                return nil
            }
            XCTAssertFalse(audioChunks.isEmpty, voice.assetKey)
            XCTAssertTrue(audioChunks.allSatisfy {
                $0.spec == .siriPCM &&
                $0.pcm.count == $0.frameCount * AudioSpec.siriPCM.bytesPerFrame
            }, voice.assetKey)
            XCTAssertEqual(
                audioChunks.reduce(into: Data()) { $0.append($1.pcm) },
                rendered.pcm,
                voice.assetKey
            )
            XCTAssertEqual(rendered.spec, .siriPCM, voice.assetKey)
            XCTAssertEqual(
                events.filter {
                    if case .completed = $0 { return true }
                    return false
                }.count,
                1,
                voice.assetKey
            )
            _ = try AudioIO.validatePCM(
                rendered.pcm,
                spec: rendered.spec,
                text: options.text
            )
        }
    }

    func testActiveCancellationDoesNotLeakIntoNextRender() throws {
        try requireLiveTests()
        let engine = SiriEngine(keepActive: true)
        guard let voice = try engine.voices().first(where: { !$0.assetKey.contains(":fmvoice:") }) else {
            return XCTFail("No installed Siri voice")
        }
        var longOptions = SynthesisOptions()
        longOptions.text = String(
            repeating: "This deliberately long sentence keeps the native request active. ",
            count: 300
        )
        longOptions.voice = voice.assetKey
        longOptions.prewarm = false
        let cancellationOptions = longOptions
        let firstAudio = expectation(description: "received first normalized audio")
        let finished = expectation(description: "cancelled request returned")
        let state = LiveCancellationState(firstAudio: firstAudio)

        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try engine.synthesize(cancellationOptions, onEvent: state.record)
                state.complete(with: nil)
            } catch let error as CLIError {
                state.complete(with: error.code)
            } catch {
                state.complete(with: .internalFailure)
            }
        }
        wait(for: [firstAudio], timeout: 20)
        engine.cancel()
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(state.exitCode, .cancelled)

        var next = SynthesisOptions()
        next.text = "Cancellation recovery \(UUID().uuidString.prefix(6))."
        next.voice = voice.assetKey
        let rendered = try engine.synthesize(next)
        _ = try AudioIO.validatePCM(rendered.pcm, spec: rendered.spec, text: next.text)
    }
}

private final class LockedStreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SynthesisStreamEvent] = []

    var events: [SynthesisStreamEvent] {
        lock.withLock { storage }
    }

    func append(_ event: SynthesisStreamEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class LiveCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private let firstAudio: XCTestExpectation
    private var sawAudio = false
    private var storedExitCode: ExitCode?

    init(firstAudio: XCTestExpectation) {
        self.firstAudio = firstAudio
    }

    var exitCode: ExitCode? {
        lock.withLock { storedExitCode }
    }

    func record(_ event: SynthesisStreamEvent) {
        lock.withLock {
            guard case .audio = event, !sawAudio else { return }
            sawAudio = true
            firstAudio.fulfill()
        }
    }

    func complete(with code: ExitCode?) {
        lock.withLock { storedExitCode = code }
    }
}

private final class AVConcurrencyState: @unchecked Sendable {
    private let lock = NSLock()
    private let firstAudio: XCTestExpectation
    private var sawFirstAudio = false
    private var sawSecondAudio = false
    private var storedFirstExitCode: ExitCode?
    private var storedSecondExitCode: ExitCode?

    init(firstAudio: XCTestExpectation) {
        self.firstAudio = firstAudio
    }

    var firstExitCode: ExitCode? { lock.withLock { storedFirstExitCode } }
    var secondExitCode: ExitCode? { lock.withLock { storedSecondExitCode } }
    var secondProducedAudio: Bool { lock.withLock { sawSecondAudio } }

    func recordFirstAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            guard !sawFirstAudio else { return }
            sawFirstAudio = true
            firstAudio.fulfill()
        }
    }

    func recordSecondAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { sawSecondAudio = true }
    }

    func setFirst(_ code: ExitCode?) {
        lock.withLock { storedFirstExitCode = code }
    }

    func setSecond(_ code: ExitCode?) {
        lock.withLock { storedSecondExitCode = code }
    }
}
