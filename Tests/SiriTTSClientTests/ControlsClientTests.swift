import Foundation
import XCTest
@testable import SiriTTSClient
import SiriTTSProtocol

final class ControlsClientTests: XCTestCase {
    func testTypedControlsAuthenticationAndResolvedVoiceSurviveHTTP() async throws {
        var controls = SpeechControls(); controls.generation = .expressive; controls.pace = 2; controls.expressivity = 5
        let client = SiriTTSClient(configuration:.init(bearerToken:"synthetic-token"),transport: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-token")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with:request.httpBody!) as? [String:Any])
            let value = try XCTUnwrap(object["controls"] as? [String:Any])
            XCTAssertEqual(value["pace"] as? Int,2); XCTAssertEqual(value["generation"] as? String,"expressive")
            return (Data("RIFF".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"audio/wav","X-Siri-TTS-Voice":"en-US:fmvoice:male:aaron:premium:0","X-Siri-TTS-Voice-Verified":"true","X-Siri-TTS-Voice-Substituted":"false","X-Siri-TTS-Pace":"pace2"])!)
        })
        let audio = try await client.synthesize(.init(text:"Hello",voice:"aaron",controls:controls))
        XCTAssertEqual(audio.voice?.verified,true); XCTAssertEqual(audio.voice?.substituted,false)
        XCTAssertEqual(audio.voice?.pace,"pace2")
    }
    func testAnalysisUsesNativeEndpointAndAlphabet() async throws {
        let client = SiriTTSClient(configuration:.init(),transport: { request in
            XCTAssertEqual(request.url?.path,"/v1/audio/phonemes")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with:request.httpBody!) as? [String:Any])
            XCTAssertEqual(body["phonemeSystem"] as? String,"lhp")
            let result = TextAnalysisResult(operation:"phonemes",requestedVoice:"legacy",text:"Hello",phonemeSystem:.lhp,phonemes:"hElo")
            return (try JSONEncoder().encode(result),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!)
        })
        let result = try await client.phonemes(.init(text:"Hello",voice:"Aaron"),alphabet:.lhp)
        XCTAssertEqual(result.phonemes,"hElo")
    }
    func testInvalidControlsNeverReachTransport() async {
        var controls = SpeechControls(); controls.pace = 9
        let client = SiriTTSClient(configuration:.init(),transport: { _ in XCTFail("transport must not be called"); throw SiriTTSClient.ClientError.invalidResponse })
        do { _ = try await client.synthesize(.init(text:"Hello",voice:"aaron",controls:controls)); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("pace")) }
    }
}
