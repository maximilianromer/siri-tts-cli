#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SIRI_TTS_BIN="${SIRI_TTS_BIN:-$PROJECT_DIR/build/siri-tts}"
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/siri-tts-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR"' EXIT

if [[ ! -x "$SIRI_TTS_BIN" ]]; then
  print -u2 "smoke: binary not found: $SIRI_TTS_BIN"
  exit 1
fi

"$SIRI_TTS_BIN" --version
"$SIRI_TTS_BIN" voices --json > "$SMOKE_DIR/voices.json"
VOICE=""
voice_index=0
while candidate="$(plutil -extract "voices.$voice_index.assetKey" raw -o - "$SMOKE_DIR/voices.json" 2>/dev/null)"; do
  if [[ "$candidate" == en-US:natural:* || "$candidate" == en-GB:natural:* ]]; then
    VOICE="$candidate"
    break
  fi
  (( voice_index += 1 ))
done
if [[ -z "$VOICE" ]]; then
  print -u2 "smoke: install a legacy English Siri voice for the English timing check"
  exit 1
fi

TEXT="The quiet river flows beside the old stone bridge."
"$SIRI_TTS_BIN" synthesize \
  --voice "$VOICE" \
  --generation legacy \
  --timings "$SMOKE_DIR/timings.json" \
  --json \
  -o "$SMOKE_DIR/output.wav" \
  "$TEXT" > "$SMOKE_DIR/result.json"

afinfo "$SMOKE_DIR/output.wav" > "$SMOKE_DIR/afinfo.txt"
grep -q "audio bytes:" "$SMOKE_DIR/afinfo.txt"
grep -q "source bit depth: I16" "$SMOKE_DIR/afinfo.txt"

DURATION="$(plutil -extract audio.durationSeconds raw -o - "$SMOKE_DIR/result.json")"
NON_SILENT="$(plutil -extract audio.nonSilent raw -o - "$SMOKE_DIR/result.json")"
TIMING_COUNT="$(plutil -extract timings json -o - "$SMOKE_DIR/timings.json" | awk '{ count += gsub(/utf16Location/, "&") } END { print count + 0 }')"
TIMINGS_SUPPORTED="$(plutil -extract timingsSupported raw -o - "$SMOKE_DIR/result.json")"
if [[ "$TIMINGS_SUPPORTED" != "true" ]] || (( TIMING_COUNT == 0 )); then
  print -u2 "smoke: legacy word timings are missing or unsupported"
  exit 1
fi
if (( $(awk "BEGIN { print ($DURATION <= 0.05) }") )) || [[ "$NON_SILENT" != "true" ]]; then
  print -u2 "smoke: audio acceptance failed"
  exit 1
fi

"$SIRI_TTS_BIN" doctor --skip-probe --json > "$SMOKE_DIR/doctor.json"
plutil -extract daemonReachable raw -o - "$SMOKE_DIR/doctor.json" | grep -q true

print "smoke: passed"
print "  voice: $VOICE"
print "  duration: ${DURATION}s"
print "  timings: $TIMING_COUNT"
