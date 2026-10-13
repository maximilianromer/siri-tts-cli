#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
binary="${SIRI_TTS_BIN:-$repo_root/build/siri-tts}"
fixture="$repo_root/Tests/Fixtures/SiriTTSClientConsumer"
port=$((20_000 + RANDOM % 20_000))
helper_url="http://127.0.0.1:$port"
scratch=$(mktemp -d /tmp/siri-tts-client-live.XXXXXX)
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

stop_server() {
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}

wait_for_server() {
  local url="$1"
  local label="$2"
  local ready=false
  for _ in {1..50}; do
    if curl --noproxy '*' --fail --silent --globoff "$url/v1/models" >/dev/null; then
      ready=true
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [[ "$ready" != true ]]; then
    print -u2 "$label could not start the helper"
    sed -n '1,40p' "$scratch/server.stderr" >&2
    exit 1
  fi
}

# This transport check deliberately sends more than the default 1 MiB input
# limit. Configure a 2 MiB input allowance while retaining the body limit.
"$binary" serve --host 127.0.0.1 --port "$port" --max-input-bytes 2097152 \
  >"$scratch/server.stdout" 2>"$scratch/server.stderr" &
server_pid=$!
wait_for_server "$helper_url" "Swift client smoke test"

SIRI_TTS_HELPER_URL="$helper_url" swift run --package-path "$fixture"

voice="$(curl --noproxy '*' --fail --silent "$helper_url/v1/models" | plutil -extract data.0.id raw -o - -)"
request="$scratch/long-request.json"
printf '{"model":"tts-1","input":"' > "$request"
dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\0' ' ' >> "$request"
printf 'Long request smoke test.","voice":"%s","response_format":"wav"}' "$voice" >> "$request"
curl --noproxy '*' --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  --data-binary "@$request" \
  "$helper_url/v1/audio/speech" \
  -o "$scratch/long.wav"
afinfo "$scratch/long.wav" | grep -q 'audio bytes:'

stop_server
ipv6_port=$((40_001 + RANDOM % 20_000))
ipv6_url="http://[::1]:$ipv6_port"
"$binary" serve --host ::1 --port "$ipv6_port" \
  >"$scratch/server.stdout" 2>"$scratch/server.stderr" &
server_pid=$!
wait_for_server "$ipv6_url" "IPv6 smoke test"

print "client smoke: passed"
print "  Swift package client: valid WAV"
print "  request body: larger than 1 MB"
print "  IPv6 loopback: reachable"
