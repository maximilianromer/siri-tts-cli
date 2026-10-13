import XCTest
@testable import SiriTTSCore
import SiriTTSProtocol

final class ExpressiveControlsTests: XCTestCase {
    let legacy = VoiceInfo(name: "Aaron", language: "en-US", assetKey: "en-US:natural:male:Aaron:premium:5030", version: 5030, engine: "siri")
    let expressive = VoiceInfo(name: "aaron", language: "en-US", assetKey: "en-US:fmvoice:male:aaron:premium:0", version: 0, engine: "siri")

    func testPresetsSelectExpressiveInsteadOfCaseInsensitiveLegacyMatch() throws {
        let options = try CLIParser.parseSynthesis(["--voice", "Aaron", "--pace", "2", "--expressivity", "5", "Hello"])
        XCTAssertEqual(try VoiceResolver.select(options, from: [legacy, expressive]).assetKey, expressive.assetKey)
    }
    func testExactLegacyKeyCannotBeUsedWithExpressiveControls() throws {
        let options = try CLIParser.parseSynthesis(["--voice", legacy.assetKey, "--pace", "2", "Hello"])
        XCTAssertThrowsError(try VoiceResolver.select(options, from: [legacy, expressive]))
    }
    func testExactNamesDisambiguateGenerations() throws {
        for voice in [legacy, expressive] {
            var options = SynthesisOptions(); options.voice = voice.name
            XCTAssertEqual(try VoiceResolver.select(options, from: [legacy, expressive]), voice)
        }
        var options = SynthesisOptions(); options.voice = "AARON"
        XCTAssertThrowsError(try VoiceResolver.select(options, from: [legacy, expressive]))
    }
    func testInvalidControlsFailBeforeCallingDaemon() {
        for args in [["--pace","0"], ["--expressivity","6"], ["--generation","legacy","--pace","3"], ["--engine","av","--whisper"], ["--client-id",""]] {
            XCTAssertThrowsError(try CLIParser.parseSynthesis(args + ["Hello"]))
        }
    }
    func testSilentLegacySubstitutionIsRejectedEvenWithNonSilentAudio() {
        var controls = SpeechControls(); controls.pace = 3
        XCTAssertThrowsError(try SiriInstrumentation.evaluate(["voiceAssetKey":legacy.assetKey], requestedVoice: expressive.assetKey, clientID: nil, controls: controls))
    }
    func testExplicitFallbackReportsActualVoiceAndMissingPresets() throws {
        var controls = SpeechControls(); controls.pace = 3; controls.allowVoiceFallback = true
        let result = try SiriInstrumentation.evaluate(["voiceAssetKey":legacy.assetKey], requestedVoice: expressive.assetKey, clientID: nil, controls: controls)
        XCTAssertTrue(result.voiceSubstituted)
        XCTAssertEqual(result.resolvedVoice, legacy.assetKey)
        XCTAssertFalse(result.warnings.isEmpty)
    }
    func testCacheHitDoesNotRequireAdapterButMustConfirmVoiceAndPresets() throws {
        var controls = SpeechControls(); controls.pace = 5; controls.expressivity = 1
        let values = ["voiceAssetKey":expressive.assetKey,"voicePacePreset":"pace5","voiceExpressivityPreset":"expressivity1"]
        let result = try SiriInstrumentation.evaluate(values, requestedVoice: expressive.assetKey, clientID: "com.apple.siritts-tool", controls: controls)
        XCTAssertTrue(result.verified)
        XCTAssertNil(result.adapter)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertThrowsError(try SiriInstrumentation.evaluate(values.merging(["voicePacePreset":"pace3"]) { _, b in b }, requestedVoice: expressive.assetKey, clientID: nil, controls: controls))
    }
    func testControlWireRoundTripPreservesOptionalFalseAndCustomAcoustics() throws {
        var controls = SpeechControls(); controls.whisper = false; controls.generation = .expressive
        var acoustics = AcousticControls(); acoustics.ppm = 820; acoustics.f0Variation = 12
        controls.acoustics = acoustics
        let data = try JSONEncoder().encode(controls)
        XCTAssertEqual(try JSONDecoder().decode(SpeechControls.self, from: data), controls)
        XCTAssertNoThrow(try controls.validate())
        acoustics.ppm = .infinity; controls.acoustics = acoustics
        XCTAssertThrowsError(try controls.validate())
    }
    func testAcousticOverrideMustMatchReportedValues() throws {
        var controls = SpeechControls(); var acoustics = AcousticControls(); acoustics.ppm = 820; controls.acoustics = acoustics
        let values = ["voiceAssetKey": expressive.assetKey, "acousticsTag": "<acoustics ppm=900/>"]
        XCTAssertThrowsError(try SiriInstrumentation.evaluate(values, requestedVoice: expressive.assetKey, clientID: nil, controls: controls))
    }
    func testVerifiedControlsRejectsHintsWithoutClaimingVoiceFailure() throws {
        var controls = SpeechControls(); controls.whisper = true; controls.requireVerifiedControls = true
        XCTAssertThrowsError(try SiriInstrumentation.evaluate(["voiceAssetKey":expressive.assetKey], requestedVoice: expressive.assetKey, clientID: nil, controls: controls))
        controls.requireVerifiedControls = false
        let result = try SiriInstrumentation.evaluate(["voiceAssetKey":expressive.assetKey], requestedVoice: expressive.assetKey, clientID: nil, controls: controls)
        XCTAssertTrue(result.verified); XCTAssertEqual(result.unverifiedControls,["whisper"])
    }

}
