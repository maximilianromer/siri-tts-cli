import Foundation
import SiriTTSProtocol

enum VoiceResolver {
    static func select(_ options: SynthesisOptions, from voices: [VoiceInfo]) throws -> VoiceInfo {
        do { try options.controls.validate() } catch { throw CLIError(error.localizedDescription, code: .usage) }
        let expressive = options.controls.requiresExpressiveVoice
        let candidates = voices.filter {
            (options.language == nil || $0.language.caseInsensitiveCompare(options.language!) == .orderedSame) &&
            (!expressive || $0.assetKey.contains(":fmvoice:")) &&
            (options.controls.generation != .legacy || !$0.assetKey.contains(":fmvoice:"))
            && $0.installed
        }
        if let wanted = options.voice {
            if let exact = candidates.first(where: { $0.assetKey == wanted }) { return exact }
            let exactNames = candidates.filter { $0.name == wanted }
            if exactNames.count == 1 { return exactNames[0] }
            let folded = candidates.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
            if folded.count == 1 { return folded[0] }
            if folded.count > 1 {
                throw CLIError("Voice '\(wanted)' is ambiguous; select --language, --generation, or an exact asset key: \(folded.map(\.assetKey).joined(separator: ", "))", code: .usage)
            }
            throw CLIError("No installed voice matches '\(wanted)' and the requested generation/language. Run `siri-tts voices --json`.", code: .voiceNotFound)
        }
        // Preserve ordinary speech defaults without accidentally selecting an
        // enumerated FM voice whose dependent resources are missing.
        let locale = Locale.preferredLanguages.first ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let localeCandidates = candidates.filter { $0.language.caseInsensitiveCompare(locale) == .orderedSame }
        let defaultCandidates = localeCandidates.isEmpty ? candidates : localeCandidates
        let preferred = expressive ? defaultCandidates.first : defaultCandidates.first { !$0.assetKey.contains(":fmvoice:") } ?? defaultCandidates.first
        guard let selected = preferred else { throw CLIError("No installed voice matches the requested generation/language", code: .voiceNotFound) }
        return selected
    }
}
