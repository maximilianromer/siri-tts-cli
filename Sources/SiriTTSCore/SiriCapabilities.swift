import Foundation
import SiriTTSProtocol

enum SiriCapabilities {
    static func inspect(engine: SiriEngine, options: SynthesisOptions, probe: Bool) throws -> CapabilityReport {
        let installed = try engine.voices()
        let selected: [VoiceInfo]
        if options.voice != nil {
            selected = [try VoiceResolver.select(options, from: installed)]
        } else {
            selected = installed.filter {
                (options.language == nil || $0.language == options.language) &&
                (!options.controls.requiresExpressiveVoice || $0.assetKey.contains(":fmvoice:")) &&
                (options.controls.generation != .legacy || !$0.assetKey.contains(":fmvoice:"))
            }
        }
        let catalog = try? ExpressiveVoiceCatalog()
        let context = NSClassFromString("SiriTTSService.SynthesisContext") as? NSObject.Type
        let selectors = [
            ("forceOspreyTTS", "setForceOspreyTTS:", ["false", "true"]),
            ("optInNextGenVoice", "setOptInNextGenVoice:", ["false", "true"]),
            ("textProcessingStyle", "setTextProcessingStyle:", ["0", "1", "2", "3"]),
            ("contextInfo", "setContextInfo:", ["dictionary"]),
            ("customResourcePaths", "setCustomResourceURLs:", ["absolute local paths"]),
            ("pace", "setVoicePacePreset:", ["1", "2", "3", "4", "5"]),
            ("expressivity", "setVoiceExpressivityPreset:", ["1", "2", "3", "4", "5"]),
            ("whisper", "setWhisper:", ["false", "true"]),
            ("style", "setStyle:", SiriRuntimeControls.styles.keys.sorted()),
            ("synthesisProfile", "setSynthesisProfile:", SiriRuntimeControls.profiles.keys.sorted()),
            ("synthesisPriority", "setSynthesisPriority:", SiriRuntimeControls.priorities.keys.sorted()),
            ("prosody", "setProsodyProperties:", ["pitch", "pitchRange", "duration", "energy", "tilt"]),
            ("privacySensitive", "setPrivacySensitive:", ["false", "true"]),
            ("minimizeDeviceUsage", "setMinimizeDeviceUsage:", ["false", "true"]),
            ("disableCompactVoice", "setDisableCompactVoice:", ["false", "true"]),
            ("disableThermalFallback", "setDisableThermalFallback:", ["false", "true"]),
        ]
        var controls = selectors.map { name, selector, values in
            ControlCapability(name: name, available: context?.instancesRespond(to: NSSelectorFromString(selector)) == true, evidence: "runtime-selector; audio effect depends on selected voice", values: values)
        }
        controls.append(ControlCapability(name: "acoustics", available: SiriRuntimeControls.symbolExists("$s14SiriTTSService16SynthesisContextC22voiceAcousticsOverrideAA14AcousticValuesVSgvsTj"), evidence: "runtime-symbol", values: ["ppm", "wsola", "f0Mean", "f0Variation", "intensityMean", "intensityVariation"]))
        controls += SiriRuntimeControls.operationSymbols.keys.sorted().map { name in
            ControlCapability(name: name, available: SiriRuntimeControls.symbolExists(SiriRuntimeControls.operationSymbols[name]!), evidence: "runtime-symbol; per-voice operation support requires a live request")
        }
        var report = CapabilityReport(toolVersion: siriTTSVersion, systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, controls: controls, voices: selected.map { voice in
            VoiceCapability(assetKey: voice.assetKey, name: voice.name, language: voice.language, generation: voice.assetKey.contains(":fmvoice:") ? "expressive" : "legacy", presetCount: catalog?.entry(for: voice)?.acoustics.count ?? 0, previewAvailable: voice.assetKey.contains(":fmvoice:") ? (try? ExpressiveVoiceCatalog.previewURL(voice: voice, pace: 3, expressivity: 3)) != nil : (try? engine.previewURL(for: voice)) != nil)
        }, expressiveClientID: SiriRuntimeControls.expressiveClientID)
        if probe {
            guard options.voice != nil else { throw CLIError("--probe requires --voice to bound the synthesis readiness check", code: .usage) }
            var request = options
            request.text = "Voice readiness check \(UUID().uuidString.prefix(8)). A clear voice makes these words easy to understand."
            request.output = nil
            request.controls.allowVoiceFallback = false
            do {
                let result = try engine.synthesize(request)
                report.probe = result.diagnostics
                report.voices[0].readiness = result.diagnostics?.verified == true ? "verified" : "audio-only"
            } catch {
                report.voices[0].readiness = "failed"
                report.voices[0].detail = error.localizedDescription
            }
        }
        return report
    }
}
