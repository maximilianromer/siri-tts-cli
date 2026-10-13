import Foundation
import SiriTTSProtocol

struct ExpressiveVoiceCatalog {
    static let resources = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SiriTTSService.framework/Resources")
    let presets: [PresetVoice]
    let version: String
    let source: URL
    struct PresetVoice: Decodable {
        let id: String
        let language: String
        let accent: String?
        let gender: String?
        let age: String?
        let adapterBundleId: String?
        let adapterUseCaseId: String?
        let acoustics: [String: [String: Double]]
    }
    private struct Presets: Decodable { let voices: [PresetVoice]; let version: String }
    init(resources: URL = Self.resources) throws {
        source = resources.appendingPathComponent("VoicePresets.plist")
        let decoded = try PropertyListDecoder().decode(Presets.self, from: Data(contentsOf: source))
        presets = decoded.voices; version = decoded.version
    }
    func entry(for voice: VoiceInfo) -> PresetVoice? {
        guard voice.assetKey.contains(":fmvoice:") else { return nil }
        return presets.first { $0.id == voice.name && $0.language == voice.language }
    }
    func report(for voice: VoiceInfo) throws -> VoicePresetReport {
        guard let entry = entry(for: voice) else { throw CLIError("No expressive preset table for this voice", code: .voiceNotFound) }
        let attributes = ["accent":entry.accent, "gender":entry.gender, "age":entry.age, "adapterBundleID":entry.adapterBundleId, "adapterUseCaseID":entry.adapterUseCaseId].compactMapValues { $0 }
        return VoicePresetReport(assetKey: voice.assetKey, source: source.path, version: version, attributes: attributes, acoustics: entry.acoustics)
    }
    static func previewURL(voice: VoiceInfo, pace: Int, expressivity: Int, resources: URL = resources) throws -> URL {
        guard (1...5).contains(pace), (1...5).contains(expressivity) else { throw CLIError("Preview presets must be from 1 through 5", code: .usage) }
        // Names come from a trusted OS catalog, but reject path components anyway.
        guard !voice.name.contains("/"), !voice.language.contains("/"), !voice.name.contains(".."), !voice.language.contains("..") else { throw CLIError("Invalid voice identifier", code: .usage) }
        let name = "\(voice.language)_\(voice.name)_pace\(pace)_expressivity\(expressivity).caf"
        let url = resources.appendingPathComponent("InteractiveVoicePreviews").appendingPathComponent(name)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw CLIError("This voice/preset preview is not installed", code: .noAudio) }
        return url
    }
}
