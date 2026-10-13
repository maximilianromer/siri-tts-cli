import Foundation

public enum VoiceAction: String, Codable, Sendable { case status, install, wait, purge }
public struct VoiceActionRequest: Codable, Equatable, Sendable {
    public var action: VoiceAction
    public var voice: String
    public var timeout: Double?
    public init(action: VoiceAction, voice: String, timeout: Double? = nil) { self.action = action; self.voice = voice; self.timeout = timeout }
}
public struct VoiceActionResult: Codable, Equatable, Sendable {
    public let action: VoiceAction
    public let voice: String
    public let assetKey: String?
    public let status: String
    public let detail: String?
    public init(action: VoiceAction, voice: String, assetKey: String?, status: String, detail: String? = nil) {
        self.action = action; self.voice = voice; self.assetKey = assetKey; self.status = status; self.detail = detail
    }
}
