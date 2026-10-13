# siri-tts-cli

`siri-tts` is a set of tools to access the high-quality Siri speech models programmatically on your Mac. You can access it three ways: a CLI, an OpenAI-compatible HTTP API, and a Swift SDK. It reaches neural Siri voices that Apple's public speech APIs exclude and can write WAV, CAF, or raw PCM; stream audio; and return native word timings.

## Choose your path

| Audience                          | Start here                                                | Interface                                                     |
| --------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------- |
| Command-line users and automation | [Command-line users](#command-line-users)                 | Versioned CLI with stable flags, exit codes, and JSON schemas |
| Applications in any language      | [OpenAI-compatible HTTP API](#openai-compatible-http-api) | Local JSON API for voice discovery and speech synthesis       |
| Swift app developers              | [Swift SDK](#swift-sdk)                                   | Swift Package Manager library built on the local HTTP API     |

The CLI, HTTP API, and Swift SDK are the supported integration surfaces.

```console
$ siri-tts voices
NAME    LANGUAGE  VERSION  ENGINE  INSTALLED  ASSET KEY
Aaron   en-US     5030     siri    yes        en-US:natural:male:Aaron:premium:5030

$ siri-tts -v Aaron -o hello.wav "The good voice, from the terminal."
✓ Aaron · 2.91s · 48000 Hz · /path/to/hello.wav
```

## Requirements

- macOS 15.6 or newer
- Apple silicon
- Xcode 26 or newer
- At least one Siri voice installed by macOS

Version 2 is currently verified on macOS 27.0.1 (26A434); older releases have not been re-tested with this version.

## macOS 27 update

Version 2 adds the new expressive Siri voices on macOS 27, with controls for speaking pace and expressivity. The older voices are still available, including their word timings.

```sh
# Render with the new Aaron voice. Pace and expressivity each range from 1 to 5.
siri-tts --generation expressive --voice aaron --pace 3 --expressivity 3 \
  -o speech.wav "The good voice, with a little more expression."

# Use the older Aaron voice with word timings.
siri-tts --generation legacy --voice Aaron --timings timings.json \
  -o speech.wav "Highlight these words as they are spoken."

# Check a voice and see its available presets.
siri-tts capabilities --voice aaron --generation expressive --probe
siri-tts presets --voice aaron
```

`Aaron` selects the older voice and `aaron` selects the expressive one; `--generation` makes the choice explicit. Expressive voices do not return word timings. Long text is split into smaller chunks automatically.

If a British expressive voice is missing its language resources, run `siri-tts voices --install Arthur --wait` to download them. Installation and purging apply to the older voice bundles; the expressive voices share their model resources.

Version 2 also adds reusable [JSON configurations](examples/configs/expressive-narration.json), JSONL batch jobs, incremental text input through `stream`, and additional speech controls. Use `siri-tts COMMAND --help` for each command's options. The HTTP API and Swift SDK accept pace, expressivity, and generation through `controls` too; for example, `"controls": {"generation": "expressive", "pace": 3, "expressivity": 3}` in an HTTP speech request.

## Command-line users

The CLI is the recommended starting point for people, scripts, and non-Swift applications.

### Install with Homebrew

```sh
brew tap maximilianromer/siri-tts-cli https://github.com/maximilianromer/siri-tts-cli.git
brew install maximilianromer/siri-tts-cli/siri-tts-cli
```

Open a new terminal and verify the installation with:

```sh
siri-tts doctor
siri-tts voices
```

### Render a file

```sh
# Generate "Hello." in Aaron's voice and save it as speech.wav
siri-tts synthesize --voice Aaron --language en-US -o speech.wav "Hello."
# Generate the text currently in the clipboard as article.wav
pbpaste | siri-tts synthesize -o article.wav
# Generate the text of chapter.txt and save it as chapter.caf
siri-tts -f chapter.txt --format caf -o chapter.caf
```

WAV is the default file format. Raw PCM is signed little-endian 16-bit audio; Siri currently returns 48 kHz mono.

### Use it like `say`

The common `say` surface is accepted, so existing scripts can often change only the command name:

```sh
alias say=siri-tts
siri-tts -v Aaron -r 210 -o faster.wav "Two hundred ten words per minute."
```

`-v`, `-o`, `-f`, `-r`, `--file-format`, `--data-format`, `--quality`, and `--progress` are supported. As with `say`, `-r` means words per minute; 175 WPM maps to the native `--rate 1.0`. `--rate` itself remains a multiplier. Lossless PCM has no encoder-quality setting, so valid `--quality` values are accepted only for command compatibility. Unsupported flags fail clearly instead of being ignored.

### Stream audio

```sh
siri-tts synthesize --format pcm -o - "Audio starts before the sentence is finished." \
  | your-audio-consumer
```

### Word timings

```sh
siri-tts synthesize \
  --voice Aaron \
  --timings timings.json \
  --json \
  -o narration.wav \
  "Highlight these words as they are spoken."
```

For legacy voices, the daemon supplies word start times and an `NSRange` into the source text. The JSON identifies offsets as UTF-16. Native timings can occasionally group words or leave gaps. End times are explicitly marked `endDerived: true`: they are derived from the next word's start, and the final word ends at the measured audio duration. If a voice does not support native timings, the tool returns an empty list and `timingsSupported: false`. Timings are available through regular CLI synthesis; the `stream` command, HTTP API, and Swift SDK return audio without timing metadata.

### Discover and install voices

```sh
siri-tts voices
siri-tts voices --json
siri-tts voices --include-av
siri-tts voices --available
siri-tts voices --install "Siri Voice Name"
siri-tts voices --install "Siri Voice Name" --wait
siri-tts voices --purge "Siri Voice Name"
siri-tts voices --status "Siri Voice Name"
siri-tts voices --manage
```

- --available lists downloadable premium Siri voices from Apple’s TTS catalog. If the catalog is unavailable, JSON is labeled installed-fallback and only installed voices are returned.
- --install adds a subscription to a voice.
- --wait polls until both the local UAF bundle and daemon voice exist; a timeout does not cancel the request.
- --status reports the current install status of a voice.
- --purge deletes the selected voice’s local asset. It does not change voice subscriptions, so macOS may download the voice again if an app or system service still subscribes to it.

## OpenAI-compatible HTTP API

Start the local HTTP API server with:

```sh
siri-tts serve --port 8080
```

It implements:

- `GET /v1/models` — installed voices
- `POST /v1/audio/speech` — `model`, `input`, `voice`, `response_format`, and `speed`

```sh
curl http://127.0.0.1:8080/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "tts-1",
    "input": "A local neural voice.",
    "voice": "Aaron",
    "response_format": "wav",
    "speed": 1.0
  }' \
  --output speech.wav
```

`wav` and `pcm` are the supported response formats.

## Diagnostics

```sh
siri-tts doctor
siri-tts doctor --json
```

The report includes the macOS product version and build, architecture, framework and daemon status, engine availability, installed voice assets, ANE compilation state, observed audio format, and a short real non-silent synthesis probe. `doctor --json` is the right attachment for a compatibility report.

## CLI reference

This section covers the original CLI commands and options. For the additions in version 2, see [macOS 27 update](#macos-27-update) and `siri-tts COMMAND --help`. Option names are case-sensitive; values such as engine and format names are case-insensitive where noted.

### Global invocations

| Invocation                                        | Behavior                                                                                                                              |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `siri-tts`                                        | Print top-level help. To synthesize from standard input, invoke `siri-tts synthesize` or include at least one synthesis option.       |
| `siri-tts TEXT`                                   | Synthesize positional text without writing the `synthesize` command explicitly. Multiple positional arguments are joined with spaces. |
| `siri-tts synthesize [OPTIONS] [TEXT]`            | Synthesize positional text, a UTF-8 input file, or UTF-8 standard input.                                                              |
| `siri-tts voices [OPTIONS]`                       | List, discover, install, inspect, or manage voices.                                                                                   |
| `siri-tts doctor [OPTIONS]`                       | Produce a compatibility report.                                                                                                       |
| `siri-tts serve [OPTIONS]`                        | Start the local HTTP server.                                                                                                          |
| `siri-tts -h`, `siri-tts --help`, `siri-tts help` | Print top-level help and exit successfully.                                                                                           |
| `siri-tts COMMAND -h`, `siri-tts COMMAND --help`  | Print command-specific help and exit successfully.                                                                                    |
| `siri-tts -V`, `siri-tts --version`               | Print the tool version and exit successfully.                                                                                         |
| `siri-tts -v ?`                                   | `say`-compatible shortcut for listing installed Siri voices.                                                                          |

### `synthesize`

```text
siri-tts synthesize [OPTIONS] [TEXT...]
siri-tts [OPTIONS] TEXT...
echo TEXT | siri-tts synthesize [OPTIONS]
```

Positional text, `-f`/`--input-file`, and standard input are the three input modes. `--` ends option parsing so text beginning with a hyphen can be spoken. Long synthesis options that take a value also accept `--option=value` as an alternative to `--option value`; the other commands require the separated form.

| Option                         | Accepted value and default                                       | Behavior                                                                                                                                                                                                                                                                            |
| ------------------------------ | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-v NAME`, `--voice NAME`      | Display name or asset identifier; default: engine-selected voice | Exact names take precedence; case-insensitive matches must be unambiguous. A catalog identifier is mapped to its installed version when possible. Without an explicit voice, Siri prefers a legacy voice in the current locale unless expressive controls are requested; AV uses the platform default for the requested language, or `en-US` when no language is given. |
| `-l TAG`, `--language TAG`     | Language tag such as `en-US`; default: no restriction            | Restrict voice selection to an exact, case-insensitive language match.                                                                                                                                                                                                              |
| `-o PATH`, `--output PATH`     | File path, `-`, or omitted                                       | Write a file, stream raw PCM to standard output with `-`, or play through the default audio output when omitted.                                                                                                                                                                    |
| `-f PATH`, `--input-file PATH` | UTF-8 text-file path                                             | Read the complete synthesis input from a file. Cannot be combined with positional text.                                                                                                                                                                                             |
| `-r WPM`                       | Greater than 0 through 700; default: 175                         | `say`-compatible words per minute. The CLI maps 175 WPM to native rate `1.0`.                                                                                                                                                                                                       |
| `--rate MULTIPLIER`            | Greater than 0 through 4; default: `1.0`                         | Set the native speaking-rate multiplier directly. If both rate forms are supplied, the last one wins.                                                                                                                                                                               |
| `--pitch MULTIPLIER`           | `0.5` through `2.0`; default: `1.0`                              | Set native pitch.                                                                                                                                                                                                                                                                   |
| `--volume NUMBER`              | `0` through `1`; default: `1.0`                                  | Set output volume.                                                                                                                                                                                                                                                                  |
| `--engine KIND`                | `siri`, `av`, or `auto`; default: `siri`                         | Use the private Siri engine, the public AV engine, or visible Siri-to-AV fallback. Values are case-insensitive.                                                                                                                                                                     |
| `--format FORMAT`              | `wav`, `pcm`, or `caf`; default: `wav`                           | Select the output container. Values are case-insensitive. Raw PCM is signed little-endian 16-bit, 48 kHz, mono.                                                                                                                                                                     |
| `--file-format FORMAT`         | `WAVE`/`WAV` or `CAFF`/`CAF`                                     | `say`-compatible alias for selecting WAV or CAF. Use `--format pcm` for raw PCM. Values are case-insensitive.                                                                                                                                                                       |
| `--data-format FORMAT`         | `LEI16@48000`, `LEI16`, or `S16LE`                               | Accept a `say`-compatible spelling for the fixed raw PCM representation. It does not change the 48 kHz mono Int16 output. Values are case-insensitive.                                                                                                                              |
| `--quality NUMBER`             | Integer `0` through `127`                                        | Accepted for `say` compatibility. Output is lossless PCM, so the value is validated and otherwise ignored.                                                                                                                                                                          |
| `--timings PATH`               | JSON-file path                                                   | Atomically write native word timings to a separate JSON file. This requests timings even without `--json`.                                                                                                                                                                          |
| `--json`                       | No value                                                         | Emit the synthesis result as JSON and request native word timings.                                                                                                                                                                                                                  |
| `--progress`                   | No value                                                         | Write start and completion messages to standard error.                                                                                                                                                                                                                              |
| `--prewarm`                    | No value; default                                                | Explicitly enable Siri model prewarming before synthesis.                                                                                                                                                                                                                           |
| `--no-prewarm`                 | No value                                                         | Skip Siri model prewarming.                                                                                                                                                                                                                                                         |
| `--timeout SECONDS`            | `1` through `3600`; default: `120`                               | Set the overall synthesis timeout.                                                                                                                                                                                                                           |
| `-h`, `--help`                 | No value                                                         | Print synthesis help and exit successfully.                                                                                                                                                                                                                                         |
| `--`                           | No value                                                         | Treat all remaining arguments as positional text, including values beginning with `-`.                                                                                                                                                                                              |

Output rules:

- With no `-o`/`--output`, synthesis is rendered to a temporary WAV file, played through the default audio device, and then removed.
- `-o -` requires `--format pcm`. The engine must resolve to `siri` or `av`; omitting `--engine` uses the default `siri`, while `auto` is rejected because fallback after partial streaming could mix engines.
- When PCM owns standard output, audio bytes go to standard output and JSON, progress, warnings, and errors go to standard error.
- `auto` falls back only for daemon, engine, or audio failures. A missing requested voice and other permanent errors do not silently fall back.
- Long input is split at natural boundaries into bounded sequential renders. Each piece must preserve the same audio format, voice, and selected engine.
- WAV has an approximately 4 GB container limit. Use raw PCM for larger output.

### `voices`

```text
siri-tts voices [--json] [--available] [--include-av]
siri-tts voices --install NAME [--wait] [--timeout SECONDS] [--json]
siri-tts voices --status NAME [--timeout SECONDS] [--json]
siri-tts voices --manage [--json]
```

| Option              | Accepted value and default                                                 | Behavior                                                                                                                                                           |
| ------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--json`            | No value                                                                   | Emit the selected voice operation as JSON instead of the human-readable table or status.                                                                           |
| `--available`       | No value                                                                   | List the complete downloadable Siri catalog when available. If the catalog is incompatible, warn and return installed Siri voices with scope `installed-fallback`. |
| `--include-av`      | No value                                                                   | Add public `AVSpeechSynthesizer` voices to a normal or available voice listing.                                                                                    |
| `--install NAME`    | Display name or catalog/native asset key                                   | Ask macOS to subscribe to one catalog voice. An acknowledgement means `requested`, not installed.                                                                  |
| `--status NAME`     | Display name or catalog/native asset key                                   | Refresh installed inventory and report `installed` or `not-installed`. Absence does not prove that cached files were physically deleted.                           |
| `--wait`            | No value                                                                   | With `--install`, poll installed inventory until the voice appears or the wait times out. This does not expose fabricated percentage progress.                     |
| `--timeout SECONDS` | `1` through `3600`; default: `300` for install waiting and `10` for status | Bound `--install --wait` polling or the `--status` inventory request. With `--install`, `--timeout` requires `--wait`.                                             |
| `--manage`          | No value                                                                   | Open Accessibility → Read & Speak in System Settings for macOS-managed voice removal.                                                                              |
| `-h`, `--help`      | No value                                                                   | Print voice help and exit successfully.                                                                                                                            |

`--install`, `--status`, and `--manage` are mutually exclusive actions. None can be combined with `--available` or `--include-av`. `--wait` requires `--install`; `--timeout` requires either `--status` or `--install --wait`. `--available` and `--include-av` may be combined when listing.

### `doctor`

```text
siri-tts doctor [--json] [--skip-probe]
```

| Option         | Default | Behavior                                                                                                                                                                       |
| -------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--json`       | Off     | Emit the complete doctor report as JSON.                                                                                                                                       |
| `--skip-probe` | Off     | Skip only the real audio synthesis probe. Framework, daemon, engine, installed-voice, and ANE compilation checks still run. A skipped probe leaves compatibility `unverified`. |
| `-h`, `--help` | —       | Print doctor help and exit successfully.                                                                                                                                       |

Without `--skip-probe`, doctor synthesizes unique text with Siri when reachable and otherwise uses AV, then validates that the result is non-silent and structurally plausible. A failed probe is recorded in the report; it does not make the `doctor` command itself exit unsuccessfully.

### `serve`

```text
siri-tts serve [--host ADDRESS] [--port NUMBER] [--engine KIND] [--verbose]
```

| Option           | Accepted value and default                                 | Behavior                                                                                                                                          |
| ---------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--host ADDRESS` | IPv4 or IPv6 literal, or `localhost`; default: `127.0.0.1` | Select the bind address. Non-loopback addresses expose the endpoint and print a warning. IPv6 addresses are displayed in brackets. |
| `--port NUMBER`  | `1` through `65535`; default: `8080`                       | Select the listening port.                                                                                                                        |
| `--engine KIND`  | `siri`, `av`, or `auto`; default: `siri`                   | Select the engine used for both model listing and synthesis. Values are case-insensitive.                                                         |
| `--verbose`      | Off                                                        | Log request failures to standard error in addition to returning their JSON HTTP error response.                                                   |
| `-h`, `--help`   | —                                                          | Print server help and exit successfully.                                                                                                          |

The server handles one synthesis request at a time and always prints its listening URL to standard error. It supports bearer authentication through `--auth-token-env NAME`, has no TLS, and should normally remain bound to loopback.

`GET /v1/models` returns an OpenAI-style model list. Each installed voice is represented as a model with `id`, `object: "model"`, and `owned_by: "local-macos"`. The selected server engine controls whether the list comes from Siri, AV, or Siri-with-AV-fallback.

`POST /v1/audio/speech` requires `Content-Type: application/json` and these fields:

| JSON field        | Required | Accepted value and default                                                                               |
| ----------------- | -------- | -------------------------------------------------------------------------------------------------------- |
| `model`           | Yes      | String accepted for OpenAI request compatibility; engine selection comes from `siri-tts serve --engine`. |
| `input`           | Yes      | Non-whitespace text.                                                                                     |
| `voice`           | Yes      | Voice display name or asset identifier.                                                                  |
| `response_format` | No       | `wav` or `pcm`; default: `wav`.                                                                          |
| `speed`           | No       | `0.25` through `4.0`; default: `1.0`.                                                                    |

A successful speech response is `audio/wav` or `application/octet-stream` and carries `X-Siri-TTS-Engine: siri|av`. Errors use `{"error":{"message":"..."}}` with an appropriate HTTP status. Unknown routes return `404`.

### JSON and timing payloads

CLI JSON is pretty-printed with sorted keys. The principal payloads are:

| Command                               | JSON payload                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `synthesize --json`                   | `schemaVersion`, selected `engine`, optional `fallbackFrom`, `voice`, `audio`, `timings`, `timingsSupported`, `elapsedSeconds`, and optional `timeToFirstAudioSeconds`. `voice` contains `name`, `language`, `assetKey`, `version`, `engine`, and `installed`. `audio` contains `format`, `output`, sample format, byte/sample counts, duration, and `nonSilent`. |
| `synthesize --timings PATH`           | `schemaVersion`, `sourceRangeEncoding: "utf16"`, `endTimes: "derived"`, and `timings`. Each timing contains `text`, `start`, derived `end`, `utf16Location`, `utf16Length`, and `endDerived`.                                                                                                                                                                     |
| `voices --json`                       | `schemaVersion`, `catalogScope` (`installed`, `available`, or `installed-fallback`), and `voices`.                                                                                                                                                                                                                                                                |
| `voices --install NAME --json`        | `schemaVersion`, `requestedVoice`, `assetKey`, and `status: "requested"`.                                                                                                                                                                                                                                                                                         |
| `voices --status NAME --json`         | Installation result containing `identifier`, optional `assetKey`, `state`, optional `voice`, and `elapsedSeconds`. This payload is currently unversioned.                                                                                                                                                                                                         |
| `voices --install NAME --wait --json` | The same currently unversioned installation result; the final `state` is `installed` or `timed-out`. A timed-out wait emits the result and then exits with code 7.                                                                                                                                                                                                |
| `voices --manage --json`              | `schemaVersion`, `status: "opened-system-settings"`, `removalScope: "managed-by-macos"`, and `settingsURL`.                                                                                                                                                                                                                                                       |
| `doctor --json`                       | `schemaVersion`, `toolVersion`, `generatedAt`, system version/build/architecture, framework and daemon status, engine reports, Siri voices with optional ANE state, optional live-probe results, and `compatibility`.                                                                                                                                             |

Most versioned CLI payloads currently use `schemaVersion: 1`. The installation result returned by `voices --status --json` and `voices --install --wait --json` is the explicit unversioned exception. JSON normally goes to standard output; during raw PCM streaming, synthesis JSON goes to standard error so the audio stream remains clean.

## Swift SDK

`SiriTTSClient` is the supported Swift SDK for listing voices and requesting WAV or PCM audio from a separately running `siri-tts` helper. The application imports a standard Swift package; the helper process owns the private macOS framework and can fail or restart without taking the host app down.

```text
Your Swift app → SiriTTSClient → localhost → siri-tts serve → macOS voice service
```

### Add the package

In Xcode, add this repository as a package dependency and select the `SiriTTSClient` product. The equivalent `Package.swift` entry is:

```swift
dependencies: [
    .package(
        url: "https://github.com/maximilianromer/siri-tts-cli.git",
        from: "2.0.0"
    ),
]
```

Then add `.product(name: "SiriTTSClient", package: "siri-tts-cli")` to the application target. The SDK is intentionally independent of `SiriTTSCore`, so a consuming app does not need Apple's private Swift interface in its build.

### Start and configure the helper

Install the CLI on the same Mac, then start its loopback-only server:

```sh
siri-tts serve --host 127.0.0.1 --port 8080
```

The SDK connects to that address by default. A different helper port can be configured explicitly:

```swift
import Foundation
import SiriTTSClient

let client = SiriTTSClient(configuration: .init(
    baseURL: URL(string: "http://127.0.0.1:9090")!
))
```

`SiriTTSClient` connects to an existing local helper. The host application starts and supervises the `siri-tts serve` process.

### List voices and synthesize speech

```swift
import Foundation
import SiriTTSClient

let client = SiriTTSClient()
let voices = try await client.voices()

let audio = try await client.synthesize(.init(
    text: "A local neural voice from a Swift app.",
    voice: voices.first?.id ?? "Aaron",
    format: .wav,
    speed: 1.0
))

try audio.data.write(
    to: URL(fileURLWithPath: "speech.wav"),
    options: .atomic
)
```

For long articles or books, save the response directly to a file so the complete audio does not have to fit in the app's memory:

```swift
let output = URL(fileURLWithPath: "book.wav")
let audioFile = try await client.synthesize(.init(
    text: bookText,
    voice: voices.first?.id ?? "Aaron"
), to: output)
```

The helper breaks long input into manageable pieces and writes each piece to disk as it finishes. The HTTP helper defaults to a 1 MiB text limit and a 2 MiB request-body limit; raise these with `--max-input-bytes` and `--max-body-bytes` for larger inputs. WAV itself has a roughly 4 GB file-size ceiling; use raw PCM for output beyond that format limit.

The response reports whether the helper used the `siri` or public `av` engine. Server errors, including a missing voice or unavailable engine, arrive as typed Swift errors.

## Exit codes

The version 2 interfaces cover the documented CLI behavior and HTTP routes used by the Swift SDK. Most versioned CLI JSON payloads carry `schemaVersion: 1`; the installation-status payload exception is documented in [JSON and timing payloads](#json-and-timing-payloads). Stable CLI exit codes:

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| 0    | Success                                                          |
| 2    | Invalid invocation                                               |
| 3    | No compatible engine                                             |
| 4    | Voice not found                                                  |
| 5    | Daemon or engine unreachable                                     |
| 6    | Empty, silent, malformed, or implausibly short audio             |
| 7    | Timed out waiting for a requested operation to become observable |
| 70   | Unexpected internal failure                                      |
| 130  | Cancelled                                                        |

## Testing and performance

```sh
make test       # unit tests plus a clean external Swift-client package build
make smoke      # real installed Siri voice, WAV, timing, and doctor checks
make live-test  # Siri, AV, Unicode timing, and HTTP integration tests
make benchmark  # time-to-first-audio and total-time CSV
```

The unit suite covers CLI validation and `say` translation, WAV headers, silence and frame validation, HTTP parsing and OpenAI request shapes, and UTF-16 timing ranges. Live tests check audio, voice selection, and legacy word timings rather than treating a build or file write as proof. No test fuzzes Apple's daemon.

## Acknowledgements

- Made with [OpenAI Codex](https://github.com/openai/codex) using GPT-5.6 Sol
- Project wouldn’t be possible without Apple’s excellent on-device Siri voice models
