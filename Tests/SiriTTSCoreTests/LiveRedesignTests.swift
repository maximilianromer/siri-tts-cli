import Foundation
import XCTest
@testable import SiriTTSCore

final class LiveRedesignTests: XCTestCase {
    func requireLive() throws {
        guard ProcessInfo.processInfo.environment["SIRI_TTS_LIVE_TESTS"] == "1" else { throw XCTSkip("Set SIRI_TTS_LIVE_TESTS=1") }
    }
    func expressive(_ text: String = "A soft breeze moves across the quiet lake.") -> SynthesisOptions {
        var result = SynthesisOptions(); result.text = text; result.voice = "aaron"
        result.controls.generation = .expressive; result.controls.pace = 3; result.controls.expressivity = 3
        result.timeout = 30; return result
    }
    func testExpressivePaceChangesDurationAndVerifiesBothPresets() throws {
        try requireLive()
        let engine = SiriEngine()
        var slow = expressive(); slow.controls.pace = 1
        var fast = slow; fast.controls.pace = 5
        let a = try engine.synthesize(slow), b = try engine.synthesize(fast)
        XCTAssertEqual(a.diagnostics?.pace,"pace1"); XCTAssertEqual(b.diagnostics?.pace,"pace5")
        XCTAssertEqual(a.diagnostics?.expressivity,"expressivity3"); XCTAssertEqual(a.diagnostics?.verified,true)
        XCTAssertGreaterThan(a.pcm.count, b.pcm.count)
    }
    func testIncrementalTextCompletesWithVerifiedPCM() throws {
        try requireLive()
        let engine = SiriEngine(); let input = SpeechTextStream()
        try input.append("A soft breeze "); try input.append("moves across the quiet lake."); input.finish()
        let result = try engine.synthesize(expressive(""),textInput:input)
        XCTAssertEqual(result.diagnostics?.verified,true)
        XCTAssertFalse(result.timingsSupported)
        XCTAssertGreaterThan(result.pcm.count,48_000)
    }
    func testIdleInputStreamTimesOutAndEngineRecovers() throws {
        try requireLive()
        let engine = SiriEngine(); let input = SpeechTextStream()
        var options = expressive(""); options.timeout = 1
        let start = Date()
        XCTAssertThrowsError(try engine.synthesize(options,textInput:input))
        XCTAssertLessThan(Date().timeIntervalSince(start),5)
        XCTAssertThrowsError(try input.append("The closed stream must reject this."))
        XCTAssertEqual(try engine.synthesize(expressive()).diagnostics?.verified,true)
    }
    func testExplicitCancellationClosesWaitingInputAndRecovers() throws {
        try requireLive()
        let engine = SiriEngine(); let input = SpeechTextStream()
        let done = expectation(description:"cancelled")
        let result = LockedResult<RenderedAudio>()
        let options = expressive("")
        DispatchQueue.global().async {
            do { result.set(.success(try engine.synthesize(options,textInput:input))) }
            catch { result.set(.failure(error)) }
            done.fulfill()
        }
        Thread.sleep(forTimeInterval:0.3)
        engine.cancel()
        wait(for:[done],timeout:5)
        XCTAssertThrowsError(try result.get().get())
        XCTAssertEqual(try engine.synthesize(expressive()).diagnostics?.verified,true)
    }
    func testLongFormPreservesControlsAcrossChunks() throws {
        try requireLive()
        var options = expressive(String(repeating:"The small brown bird rests in the garden. ",count:5))
        options.chunkBytes = 80
        var bytes = 0
        let result = try LongFormSynthesis.render(options,coordinator:EngineCoordinator(),sink:{ bytes += $0.count })
        XCTAssertGreaterThan(result.diagnostics.count,1)
        XCTAssertEqual(result.bytes,bytes)
        XCTAssertTrue(result.diagnostics.allSatisfy { $0.verified && $0.pace == "pace3" && $0.expressivity == "expressivity3" })
    }
    func testExpressiveInventoryEitherMatchesOrReportsMissingResourcesExplicitly() throws {
        try requireLive()
        let engine = SiriEngine()
        let voices = try engine.voices().filter { $0.assetKey.contains(":fmvoice:") }
        XCTAssertFalse(voices.isEmpty)
        var usable = 0
        for voice in voices {
            var options = expressive("A small gold clock is standing beside the open window.")
            options.voice = voice.assetKey
            options.requestTimings = true
            do {
                let result = try engine.synthesize(options)
                let accepted = try AudioIO.validatePCM(result.pcm, spec: result.spec, text: options.text)
                XCTAssertTrue(accepted.nonSilent)
                XCTAssertEqual(result.diagnostics?.resolvedVoice,voice.assetKey)
                XCTAssertEqual(result.diagnostics?.verified,true)
                XCTAssertFalse(result.timingsSupported)
                XCTAssertTrue(result.timings.isEmpty)
                usable += 1
            } catch let error as CLIError where error.message.contains("Cannot find resource asset") {
                // Inventory membership is not readiness. Missing resources must
                // fail explicitly, never return an unrelated substitute.
                print("Expressive resource unavailable: \(voice.assetKey)")
                XCTAssertEqual(error.code,.daemonUnreachable)
            }
        }
        XCTAssertGreaterThan(usable,0)
        print("Expressive readiness census: \(usable)/\(voices.count) rendered and verified")
    }

    func testAutomaticExpressiveSelectionBoundsLongFormRequests() throws {
        try requireLive()
        var options = SynthesisOptions()
        options.voice = "aaron"
        options.text = String(repeating: "The station library keeps old maps beside the window for visitors to explore. ", count: 8)
        options.requestTimings = true
        let result = try LongFormSynthesis.render(options, coordinator: EngineCoordinator(), sink: { _ in })
        XCTAssertGreaterThan(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics.allSatisfy { $0.verified && $0.resolvedVoice?.contains(":fmvoice:") == true })
        XCTAssertFalse(result.timingsSupported)
        XCTAssertTrue(result.timings.isEmpty)
    }

    func testUtteranceTokensDecodeCachedAndFreshAudioInOneRequest() throws {
        try requireLive()
        let engine = SiriEngine()
        let cached = "The little bird sings in the garden."
        _ = try engine.synthesize(expressive(cached))
        for _ in 0..<2 {
            let input = SpeechTextStream()
            try input.appendUtterance(cached)
            try input.appendUtterance("A new message \(UUID().uuidString.prefix(4)) arrives beside the open window.")
            input.finish()
            let result = try engine.synthesize(expressive(""),textInput:input)
            XCTAssertEqual(result.diagnostics?.verified,true)
            XCTAssertGreaterThan(result.pcm.count,96_000)
        }
    }

    func testMutedNativePlaybackAcceptsOwnedPauseResumeAndAdjustments() throws {
        try requireLive()
        let engine = SiriEngine()
        var options = expressive("A muted playback request exercises rate, volume, pause and resume through the native service.")
        options.volume = 0; options.controls.allowVoiceFallback = true
        let adjusted = expectation(description: "playback controls completed")
        let failure = LockedResult<Void>()
        let result = try engine.speak(options, onStarted: {
            DispatchQueue.global().async {
                do {
                    try engine.pausePlayback()
                    try engine.adjustPlayback(rate:1.2,volume:0)
                    try engine.resumePlayback()
                    failure.set(.success(()))
                } catch { failure.set(.failure(error)); engine.cancel() }
                adjusted.fulfill()
            }
        })
        wait(for:[adjusted],timeout:5)
        try failure.get().get()
        XCTAssertEqual(result.verified,true)
        XCTAssertThrowsError(try engine.pausePlayback())
    }

}
