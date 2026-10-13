import Foundation

public struct VoiceSubscriptionInfo: Codable, Equatable, Sendable {
    public let assetKey: String
    public let clientID: String
    public let accessoryID: String?
    public init(assetKey: String, clientID: String, accessoryID: String?) {
        self.assetKey = assetKey; self.clientID = clientID; self.accessoryID = accessoryID
    }
}

public struct VoicePresetReport: Codable, Equatable, Sendable {
    public let assetKey: String
    public let source: String
    public let version: String
    public let attributes: [String: String]
    public let acoustics: [String: [String: Double]]
    public let note: String
    public init(assetKey: String, source: String, version: String, attributes: [String:String], acoustics: [String:[String:Double]]) {
        self.assetKey = assetKey; self.source = source; self.version = version
        self.attributes = attributes; self.acoustics = acoustics
        self.note = "Bundled reference presets. Downloaded model assets can override these values; synthesis diagnostics report the effective acoustic tag."
    }
}
