import Foundation
import XCTest
@testable import SiriTTSCore
import SiriTTSProtocol

final class WorkflowTests: XCTestCase {
    func testSavedConfigurationFlagsOverrideEvenIfConfigAppearsLast() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"voice":"aaron","rate":1.2,"chunkBytes":512,"controls":{"generation":"expressive","pace":2,"expressivity":4}}"#.utf8).write(to:file)
        let result = try CLIParser.parseSynthesis(["--pace","5","--config",file.path,"Hello"])
        XCTAssertEqual(result.controls.pace,5); XCTAssertEqual(result.controls.expressivity,4)
        XCTAssertEqual(result.chunkBytes,512); XCTAssertEqual(result.rate,1.2)
    }
    func testConfigurationRejectsMisspelledOrInvalidNestedOptions() {
        for value in [#"{"controls":{"pcae":2}}"#, #"{"controls":{"acoustics":{"pmm":900}}}"#, #"{"chunkBytes":0}"#, #"{"controls":{"style":"shouting"}}"#] {
            XCTAssertThrowsError(try SpeechJSON.decodeConfiguration(Data(value.utf8)))
        }
    }
    func testJSONLReaderHandlesBlankLinesFragmentedAndFinalRecord() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("\n  \r\n{\"text\":\"Hello\"}\n{\"end\":true}".utf8).write(to:file)
        let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        var reader = JSONLineReader(handle:handle,maximumLineBytes:32)
        XCTAssertEqual(try reader.next(),Data(#"{"text":"Hello"}"#.utf8))
        XCTAssertEqual(try reader.next(),Data(#"{"end":true}"#.utf8))
        XCTAssertNil(try reader.next())
    }
    func testTextStreamBoundsEndAndCancellation() throws {
        let input = SpeechTextStream(maximumTextBytes:5)
        try input.append("Hello")
        XCTAssertThrowsError(try input.append("!"))
        input.finish()
        XCTAssertEqual(try input.next(cancelled: { false }),.text("Hello"))
        XCTAssertNil(try input.next(cancelled: { false }))
        XCTAssertThrowsError(try input.append(""))
        let cancelled = SpeechTextStream(); cancelled.cancel()
        XCTAssertThrowsError(try cancelled.next(cancelled: { false }))
    }
    func testServerAuthenticatesBeforeNativeWorkAndEnforcesBodyLimit() throws {
        var options = ServeOptions(); options.authToken = "synthetic-test-token"; options.maximumBodyBytes = 8
        let server = SpeechServer(options:options,coordinator:EngineCoordinator())
        func get(_ headers: [String:String], body: Data = Data()) throws -> String {
            String(decoding:try server.route(HTTPRequest(method:"GET",path:"/health",headers:headers,body:body)),as:UTF8.self)
        }
        XCTAssertTrue(try get([:]).hasPrefix("HTTP/1.1 401"))
        XCTAssertTrue(try get(["authorization":"Bearer wrong"]).hasPrefix("HTTP/1.1 401"))
        let headers = ["authorization":"Bearer synthetic-test-token"]
        XCTAssertTrue(try get(headers).hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(try get(headers,body:Data(repeating:0,count:9)).hasPrefix("HTTP/1.1 413"))
    }
    func testRejectsUnsupportedHTTPTransferFraming() {
        XCTAssertThrowsError(try HTTPParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8)))
    }
    func testTextToolAndStreamParsingRejectsConflictingOutput() throws {
        guard case .analyze(let options, let alphabet) = try CLIParser.parse(["phonemes","--alphabet","lhp","Hello"]) else { return XCTFail() }
        XCTAssertEqual(options.text,"Hello"); XCTAssertEqual(alphabet,.lhp)
        XCTAssertThrowsError(try CLIParser.parse(["estimate","-o","bad.wav","Hello"]))
        XCTAssertThrowsError(try CLIParser.parse(["stream","--engine","av","-o","a.wav"]))
        guard case .stream(let stream) = try CLIParser.parse(["stream","--json","-o","a.wav"]) else { return XCTFail() }
        XCTAssertFalse(stream.requestTimings)
    }
    func testSSMLRequiresOneBoundedDocumentAndRejectsEntities() throws {
        XCTAssertNoThrow(try SSML.validate("<speak>Alpha<break time=\"500ms\"/>beta.</speak>"))
        for text in ["<speak>Unclosed", "<html>Hello</html>", "<!DOCTYPE speak [<!ENTITY x SYSTEM 'file:///tmp/anything'>]><speak>&x;</speak>", "<speak>" + String(repeating:"x",count:16000) + "</speak>"] { XCTAssertThrowsError(try SSML.validate(text)) }
    }
    func testOutputGainCanMuteWithoutMisreportingSilentAudio() throws {
        var samples: [Int16] = [1000,-1000,Int16.max,Int16.min]
        let pcm = samples.withUnsafeMutableBytes { Data($0) }
        let quiet = AudioIO.applyingVolume(0.5,to:pcm)
        let expected: [Int16] = [500,-500,16384,-16384]
        XCTAssertEqual(quiet, expected.withUnsafeBytes { Data($0) })
        let silent = AudioIO.applyingVolume(0,to:Data(repeating:7,count:9600))
        XCTAssertTrue(silent.allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try AudioIO.validatePCM(silent,spec:.siriPCM,text:"Hi"))
        XCTAssertFalse(try AudioIO.validatePCM(silent,spec:.siriPCM,text:"Hi",allowSilence:true).nonSilent)
    }
    func testManagementMutationsRequireServerOptInBeforeContactingDaemon() throws {
        let server = SpeechServer(options:ServeOptions(),coordinator:EngineCoordinator())
        let request = HTTPRequest(method:"POST",path:"/v1/voices/actions",headers:["content-type":"application/json"],body:Data(#"{"action":"purge","voice":"some-voice"}"#.utf8))
        XCTAssertTrue(String(decoding:try server.route(request),as:UTF8.self).hasPrefix("HTTP/1.1 403"))
    }

}
