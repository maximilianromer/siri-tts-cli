import Darwin
import Foundation
internal import SiriTTSService
import SiriTTSProtocol

/// All optional private controls are checked before dispatch. No KVC key supplied
/// by a caller is ever forwarded to an arbitrary system object.
enum SiriRuntimeControls {
    static let operationSymbols = [
        "phonemes": "$s14SiriTTSService13DaemonSessionC13textToPhoneme7request9didFinishyAA0G7RequestC_ySSSg_s5Error_pSgtctFTj",
        "estimate": "$s14SiriTTSService13DaemonSessionC16estimateDuration7request9didFinishyAA16SynthesisRequestC_ySd_s5Error_pSgtctFTj",
        "subscriptions": "$s14SiriTTSService13DaemonSessionC16subscribedVoices8clientId5replyySSSg_ySayAA26SynthesisVoiceSubscriptionCGctFTj",
        "speak": "$s14SiriTTSService13DaemonSessionC5speak13speechRequest9didFinishyAA06SpeechG0C_ys5Error_pSgctFTj",
        "textStream": "$s14SiriTTSService13DaemonSessionC6stream16synthesisRequest12inputHandler9didFinishyAA09SynthesisG0C_yAC0L11InputStreamVcys5Error_pSgctFTj",
    ]
    static func requireOperation(_ operation: String) throws {
        guard let symbol = operationSymbols[operation], symbolExists(symbol) else { throw unsupported(operation) }
    }
    static let expressiveClientID = "com.apple.siritts-tool"
    static let styles = ["default": 0, "narration": 1, "high_intensity": 2, "mild_intensity": 3]
    static let profiles = ["undefined": 0, "lowcost": 1, "normal": 2]
    static let priorities = ["default": 0, "high": 1]

    static func symbolExists(_ name: String) -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService", RTLD_LAZY | RTLD_LOCAL) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, name) != nil
    }

    static func configureSession(_ session: DaemonSession, controls: SpeechControls, expressive: Bool) throws -> String? {
        let identity = controls.clientID ?? (expressive ? expressiveClientID : nil)
        // Reset a reused session as well, so one caller cannot leak its identity
        // into the following ordinary synthesis or voice-management request.
        let setter = "$s14SiriTTSService13DaemonSessionC9_clientIdSSSgvsTj"
        guard symbolExists(setter) else {
            if identity != nil { throw unsupported("client identity selection") }
            return nil
        }
        session._clientId = identity
        return identity
    }

    static func apply(_ controls: SpeechControls, to context: SynthesisContext) throws {
        do { try controls.validate() } catch { throw CLIError(error.localizedDescription, code: .usage) }
        if let value = controls.pace { try set(value, key: "voicePacePreset", on: context) }
        if let value = controls.expressivity { try set(value, key: "voiceExpressivityPreset", on: context) }
        for (key, value) in [
            ("whisper", controls.whisper), ("forceOspreyTTS", controls.forceOspreyTTS), ("optInNextGenVoice", controls.optInNextGenVoice), ("privacySensitive", controls.privacySensitive),
            ("minimizeDeviceUsage", controls.minimizeDeviceUsage),
            ("disableCompactVoice", controls.disableCompactVoice),
            ("disableThermalFallback", controls.disableThermalFallback),
        ] {
            if let value { try set(value, key: key, on: context) }
        }
        for (key, value, accepted) in [
            ("style", controls.style, styles),
            ("synthesisProfile", controls.synthesisProfile, profiles),
            ("synthesisPriority", controls.synthesisPriority, priorities),
        ] {
            if let value {
                guard let raw = accepted[value] else {
                    throw CLIError("Invalid \(key) '\(value)'; choose \(accepted.keys.sorted().joined(separator: ", "))", code: .usage)
                }
                try set(raw, key: key, on: context)
            }
        }
        if let value = controls.textProcessingStyle { try set(value, key: "textProcessingStyle", on: context) }
        if let value = controls.contextInfo { try set(value, key: "contextInfo", on: context) }
        if let paths = controls.customResourcePaths {
            for path in paths { guard FileManager.default.isReadableFile(atPath: path) else { throw CLIError("Custom resource is not readable: \(path)", code: .usage) } }
            try set(paths.map { URL(fileURLWithPath: $0) }, key: "customResourceURLs", on: context)
        }
        if let prosody = controls.prosody {
            guard context.responds(to: NSSelectorFromString("prosodyProperties")),
                  let properties = context.value(forKey: "prosodyProperties") as? NSObject else { throw unsupported("prosody") }
            for (key, value) in [
                ("neuralSentencePitch", prosody.pitch), ("neuralSentencePitchRange", prosody.pitchRange),
                ("neuralSentenceDuration", prosody.duration), ("neuralSentenceEnergy", prosody.energy),
                ("neuralSentenceTilt", prosody.tilt),
            ] {
                if let value { try set(value, key: key, on: properties) }
            }
        }
        if let acoustics = controls.acoustics {
            guard #available(macOS 27, *), symbolExists("$s14SiriTTSService16SynthesisContextC22voiceAcousticsOverrideAA14AcousticValuesVSgvsTj") else { throw unsupported("acoustic overrides") }
            context.voiceAcousticsOverride = AcousticValues(
                ppm: acoustics.ppm, wsola: acoustics.wsola, f0Mean: acoustics.f0Mean,
                f0Var: acoustics.f0Variation, intensityMean: acoustics.intensityMean,
                intensityVar: acoustics.intensityVariation
            )
        }
    }

    private static func set(_ value: Any, key: String, on object: NSObject) throws {
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard object.responds(to: NSSelectorFromString(setter)) else { throw unsupported(key) }
        object.setValue(value, forKey: key)
    }

    private static func unsupported(_ name: String) -> CLIError {
        CLIError("This macOS build does not expose \(name)", code: .noCompatibleEngine)
    }
}

final class SiriInstrumentation: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var observations: [String: Set<String>] = [:]

    func attach(to request: BaseRequest) -> Bool {
        guard request.responds(to: NSSelectorFromString("setDidReportInstrument:")) else { return false }
        let callback: @convention(block) (NSObject) -> Void = { [self] object in
            var captured: [String: String] = [:]
            for key in ["voiceAssetKey", "voicePacePreset", "voiceExpressivityPreset", "acousticsTag", "afmAdapterBundleId", "dynamicPromptStyle", "dynamicPromptVoice"] {
                if object.responds(to: NSSelectorFromString(key)), let value = object.value(forKey: key) as? String {
                    captured[key] = value
                }
            }
            lock.withLock {
                values.merge(captured) { _, new in new }
                for (key, value) in captured { observations[key, default: []].insert(value) }
            }
        }
        request.setValue(callback, forKey: "didReportInstrument")
        return true
    }

    func result(requestedVoice: String, clientID: String?, controls: SpeechControls) throws -> SynthesisDiagnostics {
        let (snapshot, history) = lock.withLock { (values, observations) }
        var result = try Self.evaluate(snapshot, requestedVoice: requestedVoice, clientID: clientID, controls: controls)
        // Streaming utterances can report more than one metrics object. Never
        // let a matching final utterance hide an earlier substituted voice.
        for key in ["voiceAssetKey", "voicePacePreset", "voiceExpressivityPreset", "acousticsTag"] {
            for value in history[key] ?? [] {
                let observed = try Self.evaluate(snapshot.merging([key: value]) { _, new in new }, requestedVoice: requestedVoice, clientID: clientID, controls: controls)
                result.voiceSubstituted = result.voiceSubstituted || observed.voiceSubstituted
                result.warnings = Array(Set(result.warnings + observed.warnings)).sorted()
            }
        }
        return result
    }

    static func evaluate(_ values: [String: String], requestedVoice: String, clientID: String?, controls: SpeechControls) throws -> SynthesisDiagnostics {
        var result = SynthesisDiagnostics(requestedVoice: requestedVoice)
        result.clientID = clientID
        result.resolvedVoice = values["voiceAssetKey"]
        result.pace = values["voicePacePreset"]
        result.expressivity = values["voiceExpressivityPreset"]
        result.acoustics = values["acousticsTag"]
        result.adapter = values["afmAdapterBundleId"]
        result.verified = result.resolvedVoice != nil
        result.voiceSubstituted = result.resolvedVoice.map { $0 != requestedVoice } ?? false
        if result.voiceSubstituted {
            result.warnings.append("macOS substituted \(result.resolvedVoice!) for \(requestedVoice)")
        }
        if let pace = controls.pace, result.pace != "pace\(pace)" {
            result.warnings.append("Requested Pace \(pace) was not confirmed by macOS")
        }
        if let expressivity = controls.expressivity, result.expressivity != "expressivity\(expressivity)" {
            result.warnings.append("Requested Expressivity \(expressivity) was not confirmed by macOS")
        }
        if requestedVoice.contains(":fmvoice:"), result.resolvedVoice?.contains(":fmvoice:") != true {
            result.warnings.append("Expressive voice generation was not confirmed by macOS")
        }
        result.unverifiedControls = [
            ("whisper", controls.whisper != nil), ("style", controls.style != nil),
            ("prosody", controls.prosody != nil), ("synthesisProfile", controls.synthesisProfile != nil),
            ("synthesisPriority", controls.synthesisPriority != nil), ("privacySensitive", controls.privacySensitive != nil),
            ("minimizeDeviceUsage", controls.minimizeDeviceUsage != nil), ("disableCompactVoice", controls.disableCompactVoice != nil),
            ("disableThermalFallback", controls.disableThermalFallback != nil), ("forceOspreyTTS", controls.forceOspreyTTS != nil),
            ("optInNextGenVoice", controls.optInNextGenVoice != nil), ("textProcessingStyle", controls.textProcessingStyle != nil),
            ("contextInfo", controls.contextInfo != nil), ("customResourcePaths", controls.customResourcePaths != nil),
            ("acoustics.wsola", controls.acoustics?.wsola != nil),
        ].filter { $0.1 }.map { $0.0 }
        if controls.allowVoiceFallback == false && result.resolvedVoice == nil {
            result.warnings.append("Strict voice verification requested but macOS did not report the resolved voice")
        }
        if let acoustics = controls.acoustics, let tag = result.acoustics {
            for (key, value) in [("ppm",acoustics.ppm), ("mean_f0_hertz_log",acoustics.f0Mean), ("std_f0_hertz_log",acoustics.f0Variation), ("mean_intensity_db",acoustics.intensityMean), ("std_intensity_db",acoustics.intensityVariation)] {
                guard let value else { continue }
                let pattern = "(?:^|[ <])" + key + "=([-+0-9.eE]+)"
                let regex = try NSRegularExpression(pattern: pattern)
                let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
                let actual = match.flatMap { Range($0.range(at: 1), in: tag) }.flatMap { Double(tag[$0]) }
                if actual == nil || abs(actual! - value) > 0.001 { result.warnings.append("Requested acoustic \(key)=\(value) was not confirmed by macOS") }
            }
        }
        if controls.acoustics != nil, result.acoustics == nil {
            result.warnings.append("Acoustic overrides were not confirmed by macOS")
        }
        if controls.allowVoiceFallback != true, !result.warnings.isEmpty {
            throw CLIError(result.warnings.joined(separator: "; ") + ". Use --allow-voice-fallback only if substitution is acceptable.", code: .noCompatibleEngine)
        }
        if controls.requireVerifiedControls == true, let unverified = result.unverifiedControls, !unverified.isEmpty {
            throw CLIError("These requested controls cannot be verified: " + unverified.joined(separator: ", "), code: .noCompatibleEngine)
        }
        return result
    }
}
