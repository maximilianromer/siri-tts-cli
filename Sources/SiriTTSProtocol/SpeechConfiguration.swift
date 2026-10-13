import Foundation

/// Portable saved configuration. No hidden per-user state; command flags override this file.
public struct SpeechConfiguration: Codable, Equatable, Sendable {
    public var voice: String?
    public var language: String?
    public var engine: String?
    public var format: String?
    public var rate: Float?
    public var pitch: Float?
    public var volume: Float?
    public var prewarm: Bool?
    public var ssml: Bool?
    public var timeout: Double?
    public var chunkBytes: Int?
    public var controls: SpeechControls?
    public init() {}
    public func validate() throws {
        if let engine, !["siri", "av", "auto"].contains(engine) { throw ControlValidationError("Unknown engine") }
        if let format, !["wav", "pcm", "caf"].contains(format) { throw ControlValidationError("Unknown audio format") }
        for (name, value, range) in [("rate",rate,Float(0.01)...4), ("pitch",pitch,Float(0.5)...2), ("volume",volume,Float(0)...1)] {
            if let value, !value.isFinite || !range.contains(value) { throw ControlValidationError("Invalid \(name)") }
        }
        if let timeout, !timeout.isFinite || !(1...3600).contains(timeout) { throw ControlValidationError("timeout must be from 1 through 3600 seconds") }
        if let chunkBytes, !(64...16000).contains(chunkBytes) { throw ControlValidationError("chunkBytes must be from 64 through 16000") }
        try controls?.validate()
        if engine == "av" && controls?.hasPrivateControls == true { throw ControlValidationError("Private speech controls require Siri") }
    }
}

/// Reject misspelled settings at user-controlled JSON boundaries. Codable itself
/// deliberately ignores unknown fields for forward-compatible response decoding.
public enum SpeechJSON {
    public static func decodeControls(_ data: Data) throws -> SpeechControls {
        let object = try object(data)
        try checkControls(object)
        let result = try JSONDecoder().decode(SpeechControls.self, from: data)
        try result.validate(); return result
    }
    public static func decodeConfiguration(_ data: Data) throws -> SpeechConfiguration {
        let object = try object(data)
        try check(object, allowed: ["voice","language","engine","format","rate","pitch","volume","prewarm","ssml","timeout","chunkBytes","controls"])
        if let controls = object["controls"] as? [String: Any] { try checkControls(controls) }
        let result = try JSONDecoder().decode(SpeechConfiguration.self, from: data)
        try result.validate(); return result
    }
    public static func checkControls(_ object: [String: Any]) throws {
        try check(object, allowed: ["generation","pace","expressivity","clientID","allowVoiceFallback","requireVerifiedControls","whisper","style","synthesisProfile","synthesisPriority","privacySensitive","minimizeDeviceUsage","disableCompactVoice","disableThermalFallback","acoustics","prosody","forceOspreyTTS","optInNextGenVoice","textProcessingStyle","contextInfo","customResourcePaths"])
        if let value = object["acoustics"] as? [String: Any] { try check(value, allowed: ["ppm","wsola","f0Mean","f0Variation","intensityMean","intensityVariation"]) }
        if let value = object["prosody"] as? [String: Any] { try check(value, allowed: ["pitch","pitchRange","duration","energy","tilt"]) }
    }
    public static func check(_ object: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        if !unknown.isEmpty { throw ControlValidationError("Unknown JSON setting(s): \(unknown.sorted().joined(separator: ", "))") }
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ControlValidationError("Expected a JSON object") }
        return object
    }
}
