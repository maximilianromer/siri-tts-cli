import Foundation

public enum VoiceGeneration: String, Codable, CaseIterable, Sendable {
    case automatic, legacy, expressive
}

/// Request-local controls. Nil leaves the engine's default in effect.
/// This contract does not import or link any Apple private framework.
public struct SpeechControls: Codable, Equatable, Sendable {
    public var generation: VoiceGeneration?
    public var pace: Int?
    public var expressivity: Int?
    public var clientID: String?
    public var allowVoiceFallback: Bool?
    public var requireVerifiedControls: Bool?
    public var whisper: Bool?
    public var style: String?
    public var synthesisProfile: String?
    public var synthesisPriority: String?
    public var privacySensitive: Bool?
    public var minimizeDeviceUsage: Bool?
    public var disableCompactVoice: Bool?
    public var disableThermalFallback: Bool?
    public var acoustics: AcousticControls?
    public var prosody: ProsodyControls?
    public var forceOspreyTTS: Bool?
    public var optInNextGenVoice: Bool?
    /// Native raw values 0...3 are accepted; semantic names are undocumented.
    public var textProcessingStyle: Int?
    public var contextInfo: [String: String]?
    public var customResourcePaths: [String]?

    public init() {}

    public var requiresExpressiveVoice: Bool {
        generation == .expressive || pace != nil || expressivity != nil || acoustics != nil
    }

    public var hasPrivateControls: Bool {
        self != SpeechControls()
    }

    public func validate() throws {
        for (name, value) in [("pace", pace), ("expressivity", expressivity)] {
            if let value, !(1...5).contains(value) { throw ControlValidationError("\(name) must be an integer from 1 through 5") }
        }
        if generation == .legacy && requiresExpressiveVoice {
            throw ControlValidationError("Pace, expressivity and acoustic controls require expressive generation")
        }
        if let clientID, clientID.isEmpty || clientID.utf8.count > 255 || clientID.contains(where: { $0.isWhitespace || $0.isNewline }) {
            throw ControlValidationError("clientID must be a nonempty identifier without whitespace, at most 255 bytes")
        }
        for (name, value, accepted) in [
            ("style", style, ["default", "narration", "high_intensity", "mild_intensity"]),
            ("synthesisProfile", synthesisProfile, ["undefined", "lowcost", "normal"]),
            ("synthesisPriority", synthesisPriority, ["default", "high"]),
        ] {
            if let value, !accepted.contains(value) { throw ControlValidationError("Invalid \(name); choose \(accepted.joined(separator: ", "))") }
        }
        if let textProcessingStyle, !(0...3).contains(textProcessingStyle) { throw ControlValidationError("textProcessingStyle must be from 0 through 3") }
        if let contextInfo, contextInfo.count > 32 || contextInfo.contains(where: { $0.key.utf8.count > 256 || $0.value.utf8.count > 4096 }) { throw ControlValidationError("contextInfo exceeds its field limits") }
        if let customResourcePaths, customResourcePaths.count > 16 || customResourcePaths.contains(where: { !$0.hasPrefix("/") || $0.utf8.count > 4096 }) { throw ControlValidationError("customResourcePaths requires at most 16 absolute local paths") }
        try acoustics?.validate()
        try prosody?.validate()
    }
}

public struct AcousticControls: Codable, Equatable, Sendable {
    public var ppm: Double?
    public var wsola: Double?
    public var f0Mean: Double?
    public var f0Variation: Double?
    public var intensityMean: Double?
    public var intensityVariation: Double?
    public init() {}
    public func validate() throws {
        let values = [ppm, wsola, f0Mean, f0Variation, intensityMean, intensityVariation].compactMap { $0 }
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw ControlValidationError("Acoustic overrides require at least one finite numeric value")
        }
        // Conservative operational bounds, not assertions about undocumented Apple model limits.
        if let ppm, !(100...2_000).contains(ppm) { throw ControlValidationError("ppm must be from 100 through 2000") }
        if let wsola, !(0.25...4).contains(wsola) { throw ControlValidationError("wsola must be from 0.25 through 4") }
        for value in [f0Mean, f0Variation, intensityMean, intensityVariation].compactMap({ $0 }) {
            guard (0...30).contains(value) else { throw ControlValidationError("Acoustic pitch/intensity parameters must be from 0 through 30") }
        }
    }
}

public struct ProsodyControls: Codable, Equatable, Sendable {
    public var pitch: Float?
    public var pitchRange: Float?
    public var duration: Float?
    public var energy: Float?
    public var tilt: Float?
    public init() {}
    public func validate() throws {
        let values = [pitch, pitchRange, duration, energy, tilt].compactMap { $0 }
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && (-10...10).contains($0) }) else {
            throw ControlValidationError("Prosody overrides require finite values from -10 through 10")
        }
    }
}

public struct ControlValidationError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SynthesisDiagnostics: Codable, Equatable, Sendable {
    public var requestedVoice: String
    public var resolvedVoice: String?
    public var clientID: String?
    public var pace: String?
    public var expressivity: String?
    public var acoustics: String?
    public var adapter: String?
    public var voiceSubstituted: Bool
    public var verified: Bool
    public var unverifiedControls: [String]?
    public var warnings: [String]
    public init(requestedVoice: String) {
        self.requestedVoice = requestedVoice
        self.voiceSubstituted = false
        self.verified = false
        self.warnings = []
    }
}
