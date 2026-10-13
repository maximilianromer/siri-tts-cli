import Foundation

public struct ControlCapability: Codable, Equatable, Sendable {
    public let name: String
    public let available: Bool
    public let evidence: String
    public let values: [String]?
    public init(name: String, available: Bool, evidence: String, values: [String]? = nil) {
        self.name = name; self.available = available; self.evidence = evidence; self.values = values
    }
}
public struct VoiceCapability: Codable, Equatable, Sendable {
    public let assetKey: String
    public let name: String
    public let language: String
    public let generation: String
    public let presetCount: Int
    public let previewAvailable: Bool
    public var readiness: String
    public var detail: String?
    public init(assetKey: String, name: String, language: String, generation: String, presetCount: Int, previewAvailable: Bool, readiness: String = "unverified", detail: String? = nil) {
        self.assetKey = assetKey; self.name = name; self.language = language; self.generation = generation
        self.presetCount = presetCount; self.previewAvailable = previewAvailable; self.readiness = readiness; self.detail = detail
    }
}
public struct CapabilityReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let toolVersion: String
    public let systemVersion: String
    public let controls: [ControlCapability]
    public var voices: [VoiceCapability]
    public let expressiveClientID: String
    public var probe: SynthesisDiagnostics?
    public init(toolVersion: String, systemVersion: String, controls: [ControlCapability], voices: [VoiceCapability], expressiveClientID: String, probe: SynthesisDiagnostics? = nil) {
        self.schemaVersion = 1; self.toolVersion = toolVersion; self.systemVersion = systemVersion
        self.controls = controls; self.voices = voices; self.expressiveClientID = expressiveClientID; self.probe = probe
    }
}
