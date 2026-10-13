import Foundation
import SiriTTSProtocol

public enum CLIParser {
    public static func parse(_ rawArguments: [String]) throws -> ParsedCommand {
        guard let first = rawArguments.first else { return .help }
        if first == "--version" || first == "-V" { return .version }
        if first == "--help" || first == "-h" || first == "help" { return .help }

        if rawArguments.dropFirst().contains("--help") || rawArguments.dropFirst().contains("-h") {
            if let help = toolkitHelp[first] { throw CLIError(help, code: .success) }
        }
        switch first {
        case "speak":
            let args = Array(rawArguments.dropFirst())
            let interactive = args.contains("--interactive")
            let options = try parseSynthesis(args.filter { $0 != "--interactive" })
            guard options.engine == .siri, options.output == nil, options.timingsPath == nil,
                  options.controls.allowVoiceFallback == true else { throw CLIError("speak uses native playback; requires --allow-voice-fallback and supports no output file or timings", code: .usage) }
            if interactive && options.text.isEmpty && options.inputFile == nil { throw CLIError("Interactive playback needs TEXT or --input-file; stdin carries control records", code: .usage) }
            return .speak(options, interactive: interactive)
        case "presets", "preview", "prewarm":
            let options = try parseSynthesis(Array(rawArguments.dropFirst()))
            guard options.voice != nil, options.text.isEmpty, options.inputFile == nil, options.output == nil else { throw CLIError("\(first) requires --voice and accepts no text or output file", code: .usage) }
            if first == "presets" { return .presets(options) }
            if first == "preview" { return .preview(options) }
            return .prewarm(options)
        case "subscriptions":
            var args = Array(rawArguments.dropFirst())
            let json = args.contains("--json"); args.removeAll { $0 == "--json" }
            if args.isEmpty { return .subscriptions(clientID: nil, json: json) }
            guard args.count == 2, args[0] == "--client-id" else { throw CLIError("subscriptions [--json] [--client-id ID]", code: .usage) }
            return .subscriptions(clientID: args[1], json: json)
        case "batch":
            let args = Array(rawArguments.dropFirst())
            let options = try parseSynthesis(args.filter { $0 != "--stop-on-error" })
            guard options.text.isEmpty && options.inputFile == nil && options.output == nil && options.timingsPath == nil else { throw CLIError("batch reads jobs from JSONL stdin; each job specifies text and output", code: .usage) }
            return .batch(options, stopOnError: args.contains("--stop-on-error"))
        case "stream":
            var options = try parseSynthesis(Array(rawArguments.dropFirst()))
            guard options.text.isEmpty && options.inputFile == nil && options.timingsPath == nil && !options.ssml && options.engine == .siri else { throw CLIError("stream reads JSONL from stdin, requires Siri, and does not support word timings", code: .usage) }
            options.requestTimings = false
            guard options.output != nil else { throw CLIError("stream requires --output PATH (or --format pcm --output -)", code: .usage) }
            return .stream(options)
        case "phonemes", "estimate":
            var args = expandLongOptions(Array(rawArguments.dropFirst()))
            var alphabet: PhonemeAlphabet? = first == "phonemes" ? .xsampa : nil
            if let index = args.firstIndex(of: "--alphabet") {
                guard first == "phonemes", index + 1 < args.count, let value = PhonemeAlphabet(rawValue: args[index + 1]) else { throw CLIError("--alphabet expects nashville, xsampa, or lhp", code: .usage) }
                alphabet = value; args.removeSubrange(index...index + 1)
            }
            let options = try parseSynthesis(args)
            guard options.output == nil && options.timingsPath == nil else { throw CLIError("Text analysis writes text or JSON to stdout; audio output options do not apply", code: .usage) }
            return .analyze(options, alphabet)
        case "capabilities":
            let args = Array(rawArguments.dropFirst())
            let probe = args.contains("--probe")
            let allowed = Set(["--json", "--voice", "-v", "--language", "-l", "--generation", "--client-id", "--timeout", "--probe"])
            for arg in args where arg.hasPrefix("-") && !allowed.contains(arg) { throw CLIError("Unsupported capabilities option '\(arg)'", code: .usage) }
            let options = try parseSynthesis(args.filter { $0 != "--probe" })
            guard options.text.isEmpty else { throw CLIError("capabilities does not accept spoken text", code: .usage) }
            if probe && options.voice == nil { throw CLIError("--probe requires --voice", code: .usage) }
            return .capabilities(options, probe: probe)
        case "voices":
            return .voices(try parseVoices(Array(rawArguments.dropFirst())))
        case "synthesize":
            return .synthesize(try parseSynthesis(Array(rawArguments.dropFirst())))
        case "doctor":
            return .doctor(try parseDoctor(Array(rawArguments.dropFirst())))
        case "serve":
            return .serve(try parseServe(Array(rawArguments.dropFirst())))
        default:
            if rawArguments.count == 2, rawArguments[0] == "-v", rawArguments[1] == "?" {
                return .voices(VoicesOptions())
            }
            return .synthesize(try parseSynthesis(rawArguments))
        }
    }

    public static func parseSynthesis(_ arguments: [String]) throws -> SynthesisOptions {
        var result = SynthesisOptions()
        var arguments = expandLongOptions(arguments)
        if let index = arguments.firstIndex(of: "--config"), index < (arguments.firstIndex(of: "--") ?? arguments.count) {
            guard index + 1 < arguments.count else { throw CLIError("--config needs a JSON file", code: .usage) }
            do { try result.apply(SpeechJSON.decodeConfiguration(Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))) }
            catch { throw CLIError("Invalid configuration: \(error.localizedDescription)", code: .usage) }
            arguments.removeSubrange(index...index + 1)
        }
        var text: [String] = []
        var index = 0
        var optionsEnded = false

        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw CLIError("Missing value for \(flag)", code: .usage)
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded {
                text.append(argument)
                index += 1
                continue
            }
            switch argument {
            case "--":
                optionsEnded = true
            case "-h", "--help":
                throw CLIError(synthesisHelp, code: .success)
            case "-v", "--voice":
                result.voice = try value(after: argument)
            case "--language", "-l":
                result.language = try value(after: argument)
            case "-o", "--output":
                result.output = try value(after: argument)
            case "-f", "--input-file":
                result.inputFile = try value(after: argument)
            case "-r":
                let raw = try value(after: argument)
                guard let wpm = Float(raw), wpm > 0, wpm <= 700 else {
                    throw CLIError("-r expects words per minute between 0 and 700", code: .usage)
                }
                result.rate = wpm / 175
            case "--rate":
                let raw = try value(after: argument)
                guard let rate = Float(raw), rate > 0, rate <= 4 else {
                    throw CLIError("--rate expects a multiplier between 0 and 4", code: .usage)
                }
                result.rate = rate
            case "--pitch":
                let raw = try value(after: argument)
                guard let pitch = Float(raw), (0.5...2).contains(pitch) else {
                    throw CLIError("--pitch expects a multiplier from 0.5 through 2.0", code: .usage)
                }
                result.pitch = pitch
            case "--volume":
                let raw = try value(after: argument)
                guard let volume = Float(raw), (0...1).contains(volume) else {
                    throw CLIError("--volume expects a value from 0 through 1", code: .usage)
                }
                result.volume = volume
            case "--ssml": result.ssml = true
            case "--chunk-bytes":
                let raw = try value(after: argument)
                guard let limit = Int(raw), (64...16000).contains(limit) else { throw CLIError("--chunk-bytes expects 64 through 16000", code: .usage) }
                result.chunkBytes = limit
            case "--generation":
                let raw = try value(after: argument)
                guard let generation = VoiceGeneration(rawValue: raw) else { throw CLIError("--generation expects automatic, legacy, or expressive", code: .usage) }
                result.controls.generation = generation
            case "--pace", "--expressivity":
                let raw = try value(after: argument)
                guard let preset = Int(raw), (1...5).contains(preset) else { throw CLIError("\(argument) expects an integer from 1 through 5", code: .usage) }
                if argument == "--pace" { result.controls.pace = preset } else { result.controls.expressivity = preset }
            case "--client-id": result.controls.clientID = try value(after: argument)
            case "--allow-voice-fallback": result.controls.allowVoiceFallback = true
            case "--strict-voice": result.controls.allowVoiceFallback = false
            case "--require-verified-controls": result.controls.requireVerifiedControls = true
            case "--whisper": result.controls.whisper = true
            case "--no-whisper": result.controls.whisper = false
            case "--style": result.controls.style = try value(after: argument)
            case "--synthesis-profile": result.controls.synthesisProfile = try value(after: argument)
            case "--priority": result.controls.synthesisPriority = try value(after: argument)
            case "--privacy-sensitive": result.controls.privacySensitive = true
            case "--log-text": result.controls.privacySensitive = false
            case "--minimize-device-usage": result.controls.minimizeDeviceUsage = true
            case "--disable-compact-voice": result.controls.disableCompactVoice = true
            case "--disable-thermal-fallback": result.controls.disableThermalFallback = true
            case "--controls-file":
                let path = try value(after: argument)
                do { result.controls = try SpeechJSON.decodeControls(Data(contentsOf: URL(fileURLWithPath: path))) }
                catch { throw CLIError("Could not read controls file: \(error.localizedDescription)", code: .usage) }
            case "--acoustics-json":
                let raw = try value(after: argument)
                do { result.controls.acoustics = try SpeechJSON.decodeControls(Data("{\"acoustics\":".utf8) + Data(raw.utf8) + Data("}".utf8)).acoustics }
                catch { throw CLIError("Invalid acoustic JSON: \(error.localizedDescription)", code: .usage) }
            case "--prosody-json":
                let raw = try value(after: argument)
                do { result.controls.prosody = try SpeechJSON.decodeControls(Data("{\"prosody\":".utf8) + Data(raw.utf8) + Data("}".utf8)).prosody }
                catch { throw CLIError("Invalid prosody JSON: \(error.localizedDescription)", code: .usage) }
            case "--engine":
                result.engine = try parseEngine(try value(after: argument))
            case "--format":
                result.format = try parseAudioFormat(try value(after: argument))
            case "--file-format":
                let format = try value(after: argument).lowercased()
                switch format {
                case "wave", "wav": result.format = .wav
                case "caff", "caf": result.format = .caf
                default:
                    throw CLIError(
                        "--file-format supports WAVE and CAF only; use --format pcm for raw PCM",
                        code: .usage
                    )
                }
            case "--data-format":
                let format = try value(after: argument).uppercased()
                guard ["LEI16@48000", "LEI16", "S16LE"].contains(format) else {
                    throw CLIError(
                        "--data-format currently supports LEI16@48000 only",
                        code: .usage
                    )
                }
            case "--quality":
                let raw = try value(after: argument)
                guard let quality = Int(raw), (0...127).contains(quality) else {
                    throw CLIError("--quality expects an integer from 0 through 127", code: .usage)
                }
                // Accepted for `say` compatibility. Lossless PCM has no encoder quality setting.
            case "--progress":
                result.progress = true
            case "--json":
                result.json = true
            case "--timings":
                result.timingsPath = try value(after: argument)
            case "--no-prewarm":
                result.prewarm = false
            case "--prewarm":
                result.prewarm = true
            case "--timeout":
                let raw = try value(after: argument)
                guard let timeout = Double(raw), (1...3_600).contains(timeout) else {
                    throw CLIError("--timeout expects seconds from 1 through 3600", code: .usage)
                }
                result.timeout = timeout
            default:
                if argument.hasPrefix("-") {
                    throw CLIError("Unsupported option '\(argument)'", code: .usage)
                }
                text.append(argument)
            }
            index += 1
        }
        result.text = text.joined(separator: " ")
        if result.output == "-", result.format != .pcm {
            throw CLIError("Streaming to stdout requires `--format pcm`", code: .usage)
        }
        if result.output == "-", result.engine == .auto {
            throw CLIError(
                "Streaming to stdout requires an explicit siri or av engine; auto fallback could mix partial streams",
                code: .usage
            )
        }
        if result.inputFile != nil, !result.text.isEmpty {
            throw CLIError("Pass either text or -f/--input-file, not both", code: .usage)
        }
        do { try result.controls.validate() } catch { throw CLIError(error.localizedDescription, code: .usage) }
        if result.engine == .av && result.controls.hasPrivateControls { throw CLIError("Siri-specific controls require the siri engine", code: .usage) }
        result.requestTimings = result.json || result.timingsPath != nil
        return result
    }

    private static func parseVoices(_ arguments: [String]) throws -> VoicesOptions {
        var result = VoicesOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": result.json = true
            case "--available": result.available = true
            case "--include-av": result.includeAV = true
            case "--install":
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing voice name for --install", code: .usage)
                }
                index += 1
                result.install = arguments[index]
            case "--purge":
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing voice name or asset key for --purge", code: .usage)
                }
                index += 1
                result.purge = arguments[index]
            case "--status":
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing voice name for --status", code: .usage)
                }
                index += 1
                result.status = arguments[index]
            case "--wait": result.wait = true
            case "--timeout":
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing seconds for --timeout", code: .usage)
                }
                index += 1
                guard let timeout = Double(arguments[index]), (1...3_600).contains(timeout) else {
                    throw CLIError("--timeout expects seconds from 1 through 3600", code: .usage)
                }
                result.timeout = timeout
            case "--manage": result.manage = true
            case "-h", "--help":
                throw CLIError(voicesHelp, code: .success)
            default:
                throw CLIError("Unsupported voices option '\(arguments[index])'", code: .usage)
            }
            index += 1
        }
        let actions = [
            result.install != nil,
            result.purge != nil,
            result.status != nil,
            result.manage,
        ].filter { $0 }.count
        if actions > 1 {
            throw CLIError(
                "Choose only one of --install, --purge, --status, or --manage",
                code: .usage
            )
        }
        if actions > 0, result.includeAV || result.available {
            throw CLIError(
                "Voice actions cannot be combined with --available or --include-av",
                code: .usage
            )
        }
        if result.wait, result.install == nil {
            throw CLIError("--wait requires --install", code: .usage)
        }
        if result.timeout != nil,
           result.install == nil,
           result.purge == nil,
           result.status == nil {
            throw CLIError("--timeout requires --install, --purge, or --status", code: .usage)
        }
        if result.timeout != nil, result.install != nil, !result.wait {
            throw CLIError("--timeout with --install requires --wait", code: .usage)
        }
        if let timeout = result.timeout, result.purge != nil, timeout > 300 {
            throw CLIError("--timeout with --purge must not exceed 300 seconds", code: .usage)
        }
        return result
    }

    private static func parseDoctor(_ arguments: [String]) throws -> DoctorOptions {
        var result = DoctorOptions()
        for argument in arguments {
            switch argument {
            case "--json": result.json = true
            case "--skip-probe": result.skipProbe = true
            case "-h", "--help":
                throw CLIError(doctorHelp, code: .success)
            default:
                throw CLIError("Unsupported doctor option '\(argument)'", code: .usage)
            }
        }
        return result
    }

    private static func parseServe(_ arguments: [String]) throws -> ServeOptions {
        var result = ServeOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next() throws -> String {
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing value for \(argument)", code: .usage)
                }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--host": result.host = try next()
            case "--port":
                let raw = try next()
                guard let port = UInt16(raw), port > 0 else {
                    throw CLIError("--port expects a number from 1 through 65535", code: .usage)
                }
                result.port = port
            case "--engine": result.engine = try parseEngine(try next())
            case "--allow-voice-management": result.allowVoiceManagement = true
            case "--auth-token-env":
                let name = try next()
                guard let token = ProcessInfo.processInfo.environment[name], !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw CLIError("Authentication environment variable must contain a nonempty token without whitespace", code: .usage) }
                result.authToken = token
            case "--max-input-bytes", "--max-body-bytes":
                let raw = try next()
                guard let bytes = Int(raw), (1024...67_108_864).contains(bytes) else { throw CLIError("Byte limits must be 1024 through 67108864", code: .usage) }
                if argument == "--max-input-bytes" { result.maximumInputBytes = bytes } else { result.maximumBodyBytes = bytes }
            case "--request-timeout":
                let raw = try next()
                guard let seconds = Double(raw), (1...3600).contains(seconds) else { throw CLIError("Request timeout must be 1 through 3600 seconds", code: .usage) }
                result.requestTimeout = seconds
            case "--socket-timeout":
                let raw = try next()
                guard let seconds = Int(raw), (1...300).contains(seconds) else { throw CLIError("Socket timeout must be 1 through 300 seconds", code: .usage) }
                result.socketTimeout = seconds
            case "--verbose": result.verbose = true
            case "-h", "--help":
                throw CLIError(serveHelp, code: .success)
            default:
                throw CLIError("Unsupported serve option '\(argument)'", code: .usage)
            }
            index += 1
        }
        return result
    }

    private static func parseEngine(_ raw: String) throws -> EngineKind {
        guard let engine = EngineKind(rawValue: raw.lowercased()) else {
            throw CLIError("--engine expects siri, av, or auto", code: .usage)
        }
        return engine
    }

    private static func parseAudioFormat(_ raw: String) throws -> AudioFormat {
        guard let format = AudioFormat(rawValue: raw.lowercased()) else {
            throw CLIError("--format expects wav, pcm, or caf", code: .usage)
        }
        return format
    }

    private static func expandLongOptions(_ arguments: [String]) -> [String] {
        arguments.flatMap { argument -> [String] in
            guard argument.hasPrefix("--"),
                  let equals = argument.firstIndex(of: "="),
                  equals > argument.index(argument.startIndex, offsetBy: 2) else {
                return [argument]
            }
            return [
                String(argument[..<equals]),
                String(argument[argument.index(after: equals)...]),
            ]
        }
    }
}

public let mainHelp = """
siri-tts \(siriTTSVersion) — neural Siri voices from the command line

USAGE
  siri-tts synthesize [options] TEXT
  siri-tts [say-compatible options] TEXT
  siri-tts voices [--json | --available | --install NAME | --purge NAME | --status NAME | --manage]
  siri-tts capabilities --voice aaron --probe --json
  siri-tts presets --voice aaron
  siri-tts preview --voice aaron --pace 3 --expressivity 3
  siri-tts phonemes --voice Aaron TEXT
  siri-tts estimate --voice aaron TEXT
  siri-tts stream --generation expressive --voice aaron -o speech.wav
  siri-tts batch --config voice.json < jobs.jsonl
  siri-tts speak --allow-voice-fallback [--interactive] TEXT
  siri-tts prewarm --voice aaron
  siri-tts subscriptions --json
  siri-tts doctor [--json]
  siri-tts serve [--port 8080]

COMMANDS
  synthesize   Render text to a file, stdout, or the default audio output
  voices       List installed Siri voices and their real asset metadata
  capabilities Inspect runtime controls; optionally probe one voice
  presets      Dump bundled expressive preset tables and metadata
  preview      Print the path to an OS-owned prerecorded preview
  phonemes     Convert text to Nashville, X-SAMPA, or LHP phonemes
  estimate     Request a heuristic duration (not measured speech)
  stream       Feed native synthesis from JSONL text fragments
  batch        Run JSONL jobs with per-job configuration and results
  speak        Native daemon playback with optional stdin controls
  prewarm      Warm a voice without playing audio
  subscriptions Inspect client voice subscriptions without changing them
  doctor       Probe this Mac and produce a compatibility report
  serve        Run the OpenAI-compatible local HTTP API

Run `siri-tts COMMAND --help` for command-specific options.
"""

public let synthesisHelp = """
USAGE
  siri-tts synthesize [options] TEXT
  echo TEXT | siri-tts synthesize [options]

OPTIONS
  -v, --voice NAME       Voice display name or asset identifier
  --language TAG         Restrict voice matching (for example en-US)
  -o, --output PATH      Output file; use - for raw PCM on stdout
  -f, --input-file PATH  Read UTF-8 input from a file
  -r WPM                 `say`-compatible words per minute (175 = 1.0x)
  --rate MULTIPLIER      Native speaking-rate hint (voice-dependent)
  --config PATH         Load a reusable JSON configuration; flags override
  --chunk-bytes N       Long-form chunk target, 64...16000 (default 4000)
                        Expressive plain-text chunks are capped at 400 bytes
  --ssml                Validate one complete speak document (max 16000 bytes)
  --generation KIND     automatic, legacy, or expressive
  --pace 1...5           Expressive speaking pace
  --expressivity 1...5   Expressive pitch/intensity preset
  --client-id ID         Override the private daemon client identity
  --allow-voice-fallback Accept a substituted voice and report it
  --strict-voice         Reject unconfirmed voice/presets
  --require-verified-controls Reject experimental settings without confirmation
  --whisper             Request whisper speech
  --style NAME          default, narration, high_intensity, mild_intensity
  --synthesis-profile P undefined, lowcost, normal
  --priority P          default, high
  --controls-file PATH  Load shared JSON controls; later flags override
  --acoustics-json JSON  Advanced ppm/wsola/F0/intensity overrides
  --prosody-json JSON    Advanced neural sentence prosody
  --privacy-sensitive   Keep request text private in daemon logging (default)
  --log-text            Allow text in daemon diagnostic logging
  --minimize-device-usage Request reduced resource use
  --disable-compact-voice Prevent compact voice selection
  --disable-thermal-fallback Request no thermal voice downgrade
  --pitch MULTIPLIER     Pitch from 0.5 through 2.0
  --volume NUMBER        Output gain from 0 through 1 (0 produces silence)
  --engine KIND          siri (default), av, or auto
  --format FORMAT        wav (default), pcm, or caf
  --timings PATH         Write versioned word timings as JSON
  --json                 Emit a versioned result object
  --progress             Report synthesis progress on stderr
  --no-prewarm           Skip Siri model prewarming
"""

public let voicesHelp = """
USAGE
  siri-tts voices [--json] [--available] [--include-av]
  siri-tts voices --install NAME [--wait] [--timeout SECONDS] [--json]
  siri-tts voices --purge NAME [--timeout SECONDS] [--json]
  siri-tts voices --status NAME [--json]
  siri-tts voices --manage [--json]

`--available` asks macOS for the full Siri catalog. `--install` explicitly asks
macOS to subscribe to one catalog voice; it never runs implicitly. `--wait`
polls for both local content and a usable daemon voice but cannot show a percentage.
`--purge` physically deletes the exact local voice asset and fails unless its
proven `AssetData` path disappears. `--manage` opens Apple's voice settings.
"""

public let doctorHelp = """
USAGE
  siri-tts doctor [--json] [--skip-probe]

The default report performs a short real synthesis probe. Use --skip-probe only
when a non-speaking diagnostic is required.
"""

public let serveHelp = """
USAGE
  siri-tts serve [--host 127.0.0.1] [--port 8080] [--engine siri|av|auto]

OPTIONS
  --auth-token-env NAME    Read a bearer token from this environment variable
  --max-input-bytes N     Maximum spoken UTF-8 input (default 1048576)
  --max-body-bytes N      Maximum HTTP body (default 2097152)
  --request-timeout SEC   Overall speech deadline (default 120)
  --socket-timeout SEC    Read/write inactivity timeout (default 10)
  --allow-voice-management Enable explicit install and purge API actions
  --verbose              Log request failures

Routes: /health, /v1/models, /v1/capabilities, /v1/subscriptions,
/v1/audio/speech, /v1/audio/phonemes, /v1/audio/estimate,
/v1/voices/presets, /v1/voices/actions. The helper serves requests serially.
Loopback is the default. Use TLS termination or an SSH tunnel for remote use.
"""

private let toolkitHelp: [String: String] = [
    "capabilities": "siri-tts capabilities [--voice ID] [--language TAG] [--generation expressive|legacy|automatic] [--probe] [--json]\n--probe renders one short sample and requires --voice. Selector presence alone is not readiness.",
    "presets": "siri-tts presets --voice ID [--generation expressive]\nPrint the bundled acoustic table and its source/version as JSON. Downloaded model values can differ.",
    "preview": "siri-tts preview --voice ID [--pace 1...5] [--expressivity 1...5] [--json]\nPrint an OS-owned prerecorded preview path. Defaults to presets 3/3; does not synthesize or copy assets.",
    "prewarm": "siri-tts prewarm --voice ID [speech options] [--json]\nWarm the selected voice and controls; successful prewarm does not prove synthesis readiness.",
    "subscriptions": "siri-tts subscriptions [--client-id ID] [--json]\nRead current subscription ownership; no assets or subscriptions are changed.",
    "phonemes": "siri-tts phonemes [--alphabet nashville|xsampa|lhp] [speech options] TEXT\nDefaults to xsampa. Supports -f and stdin. Expressive voices currently reject this operation. --json emits structured output.",
    "estimate": "siri-tts estimate [speech options] TEXT\nReturn a native heuristic duration. Render speech for measured duration and verified preset effects.",
    "stream": "siri-tts stream [speech options] -o FILE\nRead JSONL records {\"text\":\"fragment\"} or {\"utterance\":\"sentence\"}; finish at EOF or {\"end\":true}. Maximum total input 128000 UTF-8 bytes. Use --format pcm -o - for a pipe. Strict expressive output is buffered until verified; --allow-voice-fallback opts into provisional audio. No word timings or SSML mode.",
    "batch": "siri-tts batch [speech options] [--stop-on-error] < jobs.jsonl\nEach record: {\"id\":\"job-1\",\"text\":\"Hello\",\"output\":\"hello.wav\",\"config\":{...}}. One JSON result per job; errors are reported per record. Any failed job gives a nonzero exit. Files are written serially; no audio is played.",
    "speak": "siri-tts speak --allow-voice-fallback [speech options] [--interactive] TEXT\nPlay through Siri's native daemon. Sound precedes verification. Interactive stdin accepts JSONL actions pause, resume, rate, volume, cancel; rate and volume require value. Ctrl-C cancels. File synthesis verifies speech before normal playback.",
]
