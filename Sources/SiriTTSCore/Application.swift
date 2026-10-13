import AVFoundation
import Foundation
import SiriTTSProtocol

public final class SiriTTSApplication: @unchecked Sendable {
    public let coordinator: EngineCoordinator
    private let stateLock = NSLock()
    private var activeServer: SpeechServer?

    public init(coordinator: EngineCoordinator = EngineCoordinator()) {
        self.coordinator = coordinator
    }

    public func run(arguments: [String]) throws {
        switch try CLIParser.parse(arguments) {
        case .help:
            print(mainHelp)
        case .version:
            print(siriTTSVersion)
        case .speak(var options, let interactive):
            try collectText(into: &options)
            let engine = coordinator.siri
            let started: @Sendable () -> Void = {
                writeStderr("Native playback started.\n")
                guard interactive else { return }
                DispatchQueue(label: "SiriTTSCore.playback-input").async {
                    do {
                        var reader = JSONLineReader(handle: .standardInput, maximumLineBytes: 4096)
                        while let data = try reader.next() {
                            struct Control: Decodable { let action: String; let value: Float?; let rampTime: Double? }
                            let control = try JSONDecoder().decode(Control.self, from: data)
                            switch control.action {
                            case "pause": try engine.pausePlayback()
                            case "resume": try engine.resumePlayback()
                            case "rate": guard let value = control.value else { throw CLIError("rate needs value", code: .usage) }; try engine.adjustPlayback(rate: value)
                            case "volume": guard let value = control.value else { throw CLIError("volume needs value", code: .usage) }; try engine.adjustPlayback(volume: value, rampTime: control.rampTime ?? 0)
                            case "cancel": engine.cancel(); return
                            default: throw CLIError("Unknown playback action", code: .usage)
                            }
                            writeStderr("Playback control accepted: \(control.action)\n")
                        }
                    } catch { writeStderr("Playback control error: \(error.localizedDescription)\n"); engine.cancel() }
                }
            }
            let result = try engine.speak(options, onStarted: started)
            if options.json { printJSON(result) }
            else { print("Playback completed · \(result.resolvedVoice ?? result.requestedVoice)") }
        case .presets(let options):
            printJSON(try coordinator.siri.presets(options))
        case .preview(let options):
            let url = try coordinator.siri.previewURL(options)
            if options.json { printJSON(["url": url.absoluteString, "kind": "bundled-preview", "readiness": "not-a-synthesis-probe"]) }
            else { print(url.path) }
        case .prewarm(let options):
            let voice = try coordinator.siri.prewarm(voice: options.voice, language: options.language, timeout: options.timeout, controls: options.controls)
            if options.json { printJSON(voice) } else { print("Prewarmed \(voice.assetKey); readiness still requires a synthesis probe.") }
        case .subscriptions(let clientID, let json):
            let values = try coordinator.siri.subscriptions(clientID: clientID)
            if json { printJSON(values) }
            else { for value in values { print("\(value.clientID) · \(value.assetKey)") } }
        case .batch(let options, let stopOnError):
            var reader = JSONLineReader(handle: .standardInput)
            var failures = 0
            var index = 0
            while let line = try reader.next() {
                index += 1
                var id = String(index)
                do {
                    struct Job: Decodable { let id: String?; let text: String; let output: String; let config: SpeechConfiguration? }
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CLIError("Expected a batch JSON object", code: .usage) }
                    if let suppliedID = object["id"] as? String { id = suppliedID }
                    try SpeechJSON.check(object, allowed: ["id", "text", "output", "config"])
                    if let config = object["config"] { _ = try SpeechJSON.decodeConfiguration(JSONSerialization.data(withJSONObject: config)) }
                    let job = try JSONDecoder().decode(Job.self, from: line)
                    var request = options
                    if let config = job.config { try request.apply(config) }
                    guard job.output != "-" && !job.output.isEmpty else { throw CLIError("Batch jobs require an output file", code: .usage) }
                    guard !job.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError("Batch text is empty", code: .usage) }
                    request.text = job.text; request.output = job.output; request.json = true; request.requestTimings = true
                    let result = try runSynthesis(request, emitResult: false)
                    struct Success: Encodable { let id: String; let result: SynthesisResult }
                    printJSONLine(Success(id: id, result: result))
                } catch {
                    failures += 1
                    struct Failure: Encodable { let id: String; let error: String; let exitCode: Int32 }
                    printJSONLine(Failure(id: id, error: error.localizedDescription, exitCode: (error as? CLIError)?.code.rawValue ?? 70))
                    if stopOnError { break }
                }
            }
            if failures > 0 { throw CLIError("\(failures) batch job(s) failed; see JSONL results", code: .internalFailure) }
        case .stream(let options):
            let input = SpeechTextStream()
            DispatchQueue(label: "SiriTTSCore.stdin").async {
                do {
                    var reader = JSONLineReader(handle: .standardInput, maximumLineBytes: 128_000)
                    while let line = try reader.next() {
                        struct Record: Decodable { let text: String?; let utterance: String?; let end: Bool? }
                        let record = try JSONDecoder().decode(Record.self, from: line)
                        guard [record.text != nil, record.utterance != nil, record.end == true].filter({ $0 }).count == 1 else { throw CLIError("Each stream record needs exactly one of text, utterance, or end:true", code: .usage) }
                        if let text = record.text { try input.append(text) }
                        else if let utterance = record.utterance { try input.appendUtterance(utterance) }
                        else { break }
                    }
                    input.finish()
                } catch { input.fail(error) }
            }
            try runSynthesis(options, textInput: input)
        case .analyze(var options, let alphabet):
            try collectText(into: &options)
            let result = try coordinator.siri.analyze(options, phonemeSystem: alphabet)
            if options.json { printJSON(result) }
            else if let phonemes = result.phonemes { print(phonemes) }
            else if let seconds = result.estimatedSeconds { print(String(format: "%.3f", seconds)) }
            for warning in result.warnings { writeStderr("warning: \(warning)\n") }
        case .capabilities(let options, let probe):
            let report = try SiriCapabilities.inspect(engine: coordinator.siri, options: options, probe: probe)
            if options.json { printJSON(report) }
            else {
                print("Siri voice capabilities · \(report.systemVersion)")
                for voice in report.voices { print("\(voice.name) · \(voice.language) · \(voice.generation) · presets \(voice.presetCount) · \(voice.readiness)\(voice.detail.map { ": " + $0 } ?? "")") }
                print("Expressive mode uses private client identity \(report.expressiveClientID).")
                print("Presence is not synthesis readiness; use --voice ID --probe to verify.")
            }
        case .voices(let options):
            try runVoices(options)
        case .synthesize(var options):
            try collectText(into: &options)
            try runSynthesis(options)
        case .doctor(let options):
            runDoctor(options)
        case .serve(let options):
            let server = SpeechServer(options: options, coordinator: coordinator)
            stateLock.withLock { activeServer = server }
            defer { stateLock.withLock { activeServer = nil } }
            try server.run()
        }
    }

    public func cancel() {
        coordinator.cancel()
        stateLock.withLock { activeServer }?.stop()
    }

    private func runVoices(_ options: VoicesOptions) throws {
        if options.manage {
            try SystemVoiceSettings.open()
            if options.json {
                struct ManagePayload: Encodable {
                    let schemaVersion = siriTTSSchemaVersion
                    let status = "opened-system-settings"
                    let removalScope = "managed-by-macos"
                    let settingsURL: String
                }
                printJSON(ManagePayload(settingsURL: SystemVoiceSettings.url.absoluteString))
            } else {
                print("Opened System Settings. Choose System Voice > Manage Voices to remove a macOS-managed voice.")
            }
            return
        }

        if let identifier = options.status {
            let result = try coordinator.siri.installationStatus(
                for: identifier,
                timeout: options.timeout ?? 10
            )
            if options.json {
                printJSON(result)
            } else if let voice = result.voice {
                print("installed · \(voice.name) · \(voice.language) · \(voice.assetKey)")
            } else {
                print("not-installed · \(identifier)")
                writeStderr(
                    "This voice is not currently usable as an installed Siri voice.\n"
                )
            }
            return
        }

        if let identifier = options.purge {
            let result = try coordinator.siri.purgeVoice(
                identifier: identifier,
                timeout: options.timeout ?? 30
            )
            if options.json {
                struct PurgePayload: Encodable {
                    let schemaVersion = siriTTSSchemaVersion
                    let result: VoicePurgeResult
                }
                printJSON(PurgePayload(result: result))
            }
            guard !result.localAssetAvailableAfterPurge else {
                throw CLIError(
                    "macOS left '\(result.name)' locally available; it was not purged",
                    code: .noCompatibleEngine
                )
            }
            if !options.json {
                print("purged · \(result.name) · \(result.nativeAssetKey)")
            }
            return
        }

        if let name = options.install {
            let acknowledgement = try coordinator.siri.installVoice(named: name)
            if !options.wait {
                if options.json {
                    struct InstallPayload: Encodable {
                        let schemaVersion = siriTTSSchemaVersion
                        let requestedVoice: String
                        let assetKey: String
                        let status = "requested"
                    }
                    printJSON(InstallPayload(
                        requestedVoice: name,
                        assetKey: acknowledgement.assetKey
                    ))
                } else {
                    writeStderr(
                        "macOS acknowledged installation of '\(name)' (\(acknowledgement.assetKey)); completion is still pending.\n"
                    )
                }
                return
            }

            writeStderr("macOS acknowledged the request; waiting for installed inventory…\n")
            let waitTimeout = options.timeout ?? 300
            let result = try coordinator.siri.waitForVoiceInstallation(
                assetKey: acknowledgement.assetKey,
                identifier: name,
                timeout: waitTimeout
            )
            if options.json {
                printJSON(result)
            } else if let voice = result.voice {
                print("installed · \(voice.name) · \(voice.language) · \(voice.assetKey)")
            }
            if result.state == .timedOut {
                throw CLIError(
                    "macOS has not reported '\(name)' as installed after \(Int(waitTimeout)) seconds; the request may still finish later",
                    code: .operationTimedOut
                )
            }
            return
        }

        let catalogScope: String
        var voices: [VoiceInfo]
        if options.available {
            do {
                voices = try coordinator.siri.availableVoices()
                catalogScope = "available"
            } catch {
                writeStderr(
                    "warning: macOS did not expose the full Siri voice catalog; showing installed voices only: \(error.localizedDescription)\n"
                )
                voices = try coordinator.siri.voices()
                catalogScope = "installed-fallback"
            }
        } else {
            voices = try coordinator.siri.voices()
            catalogScope = "installed"
        }
        if options.includeAV {
            voices.append(contentsOf: coordinator.av.voices())
        }
        voices.sort { ($0.engine, $0.language, $0.name) < ($1.engine, $1.language, $1.name) }
        if options.json {
            struct Payload: Encodable {
                let schemaVersion = siriTTSSchemaVersion
                let catalogScope: String
                let voices: [VoiceInfo]
            }
            printJSON(Payload(catalogScope: catalogScope, voices: voices))
        } else {
            printVoiceTable(voices)
        }
    }

    @discardableResult
    private func runSynthesis(_ options: SynthesisOptions, textInput: SpeechTextStream? = nil, emitResult: Bool = true) throws -> SynthesisResult {
        if options.progress {
            writeStderr("Synthesizing with \(options.engine.rawValue)…\n")
        }
        let streaming = options.output == "-"
        let spoolDirectory = options.output.map {
            URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent()
        } ?? FileManager.default.temporaryDirectory
        let spool = streaming ? nil : try PCMSpool(directory: spoolDirectory)
        let rendered: IncrementalSynthesisResult
        if let textInput {
            let audio = try coordinator.siri.synthesize(options, onPCMChunk: streaming ? writeStdoutChunk : nil, textInput: textInput)
            if !streaming { try spool?.append(audio.pcm) }
            let samples = audio.pcm.count / audio.spec.bytesPerFrame
            rendered = IncrementalSynthesisResult(spec: audio.spec, voice: audio.voice, timings: [], timingsSupported: false,
                engine: audio.engine, fallbackFrom: nil, elapsed: audio.elapsed, timeToFirstAudio: audio.timeToFirstAudio,
                bytes: audio.pcm.count, nonSilent: audio.nonSilent, sampleCount: samples, durationSeconds: Double(samples) / audio.spec.sampleRate,
                diagnostics: audio.diagnostics.map { [$0] } ?? [])
        } else {
            rendered = try LongFormSynthesis.render(options, coordinator: coordinator,
                onProvisionalPCMChunk: streaming ? writeStdoutChunk : nil, sink: { try spool?.append($0) })
        }
        if let fallback = rendered.fallbackFrom {
            writeStderr(
                "warning: \(fallback.rawValue) engine failed; visibly falling back to \(rendered.engine.rawValue)\n"
            )
        }

        let mappedTimings = try WordTimingMapper.map(
            rendered.timings,
            in: options.text,
            duration: rendered.durationSeconds
        )

        let outputDescription: String
        if streaming {
            outputDescription = "stdout"
        } else if let path = options.output {
            let outputURL = URL(fileURLWithPath: path).standardizedFileURL
            try spool?.materialize(
                format: options.format,
                spec: rendered.spec,
                at: outputURL
            )
            outputDescription = outputURL.path
        } else {
            let playbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("siri-tts-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: playbackURL) }
            try spool?.materialize(format: .wav, spec: rendered.spec, at: playbackURL)
            try play(playbackURL)
            outputDescription = "default-audio-output"
        }

        if let timingsPath = options.timingsPath {
            struct TimingPayload: Encodable {
                let schemaVersion = siriTTSSchemaVersion
                let sourceRangeEncoding = "utf16"
                let endTimes = "derived"
                let timings: [WordTiming]
            }
            try encodedJSON(TimingPayload(timings: mappedTimings))
                .write(to: URL(fileURLWithPath: timingsPath), options: .atomic)
        }

        let audioResult = AudioResult(
            format: options.format.rawValue,
            output: outputDescription,
            sampleRate: rendered.spec.sampleRate,
            channels: rendered.spec.channels,
            bitsPerChannel: rendered.spec.bitsPerChannel,
            bytes: rendered.bytes,
            sampleCount: rendered.sampleCount,
            durationSeconds: rendered.durationSeconds,
            nonSilent: rendered.nonSilent
        )
        let result = SynthesisResult(
            engine: rendered.engine.rawValue,
            fallbackFrom: rendered.fallbackFrom?.rawValue,
            voice: rendered.voice,
            audio: audioResult,
            timings: mappedTimings,
            timingsSupported: rendered.timingsSupported,
            elapsedSeconds: rendered.elapsed,
            timeToFirstAudioSeconds: rendered.timeToFirstAudio,
            diagnostics: rendered.diagnostics.isEmpty ? nil : rendered.diagnostics
        )

        for diagnostic in rendered.diagnostics {
            for warning in diagnostic.warnings { writeStderr("warning: \(warning)\n") }
        }
        if emitResult && options.json {
            let data = encodedJSON(result)
            if streaming {
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data("\n".utf8))
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } else if emitResult && !streaming {
            print(
                "✓ \(rendered.voice.name) · \(String(format: "%.2f", rendered.durationSeconds))s · " +
                "\(Int(rendered.spec.sampleRate)) Hz · \(outputDescription)"
            )
        }
        if options.progress {
            writeStderr("Complete in \(String(format: "%.2f", rendered.elapsed))s.\n")
        }
        return result
    }

    private func runDoctor(_ options: DoctorOptions) {
        let report = Doctor.run(options: options, coordinator: coordinator)
        if options.json {
            printJSON(report)
            return
        }
        print("siri-tts doctor")
        print("  macOS       \(report.system.productVersion) (\(report.system.buildVersion))")
        print("  Architecture \(report.system.architecture)")
        print("  Framework   \(report.frameworkAvailable ? "available" : "missing")")
        print("  Daemon      \(report.daemonReachable ? "reachable" : "unreachable")")
        for engine in report.engines {
            print("  \(engine.name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(engine.available ? "ready" : "unavailable") — \(engine.detail)")
        }
        print("  Siri voices \(report.siriVoices.count)")
        if let probe = report.probe {
            if probe.succeeded {
                print(
                    "  Live probe   passed — \(probe.voice ?? "unknown"), " +
                    "\(Int(probe.sampleRate ?? 0)) Hz, \(String(format: "%.2f", probe.durationSeconds ?? 0))s"
                )
            } else {
                print("  Live probe   failed — \(probe.error ?? "unknown error")")
            }
        }
        print("  Status       \(report.compatibility)")
    }

    private func collectText(into options: inout SynthesisOptions) throws {
        if let inputFile = options.inputFile {
            do {
                options.text = try String(
                    contentsOf: URL(fileURLWithPath: inputFile),
                    encoding: .utf8
                )
            } catch {
                throw CLIError("Could not read input file: \(error.localizedDescription)", code: .usage)
            }
        } else if options.text.isEmpty, isatty(STDIN_FILENO) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIError("Standard input is not valid UTF-8", code: .usage)
            }
            options.text = text
        }
        guard !options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("No text provided\n\n\(synthesisHelp)", code: .usage)
        }
    }

    private func play(_ url: URL) throws {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            throw CLIError("Could not open the default audio output: \(error.localizedDescription)", code: .noAudio)
        }
        guard player.play() else {
            throw CLIError("Could not start audio playback", code: .noAudio)
        }
        while player.isPlaying {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func printVoiceTable(_ voices: [VoiceInfo]) {
        guard !voices.isEmpty else {
            print("No voices found.")
            return
        }
        let nameWidth = min(26, max(5, voices.map(\.name.count).max() ?? 5))
        let languageWidth = max(8, voices.map(\.language.count).max() ?? 8)
        print(
            "NAME".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  " +
            "LANGUAGE".padding(toLength: languageWidth, withPad: " ", startingAt: 0) +
            "  VERSION  ENGINE  INSTALLED  ASSET KEY"
        )
        for voice in voices {
            print(
                String(voice.name.prefix(nameWidth))
                    .padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  " +
                voice.language.padding(toLength: languageWidth, withPad: " ", startingAt: 0) + "  " +
                String(voice.version).padding(toLength: 7, withPad: " ", startingAt: 0) + "  " +
                voice.engine.padding(toLength: 6, withPad: " ", startingAt: 0) + "  " +
                (voice.installed ? "yes" : "no").padding(toLength: 9, withPad: " ", startingAt: 0) + "  " +
                voice.assetKey
            )
        }
    }
}

public func encodedJSON<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)) ?? Data("{}".utf8)
}

private func printJSON<T: Encodable>(_ value: T) {
    FileHandle.standardOutput.write(encodedJSON(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

public func writeStderr(_ value: String) {
    FileHandle.standardError.write(Data(value.utf8))
}

private func writeStdoutChunk(_ data: Data) {
    do {
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch {
        // A downstream pipe closing is a normal streaming termination condition.
    }
}

private func printJSONLine<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
}
