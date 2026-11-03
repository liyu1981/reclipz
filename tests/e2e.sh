#!/usr/bin/env bash
# End-to-end test: exercises the built binary against local fixture servers.
#
#   zig build -Doptimize=ReleaseSafe
#   tests/e2e.sh
#
# Covers: UI byte-identity, /api/info, video download (MP4/h264+aac), audio download (MP3),
# status/filename contract, error-string parity, progress reporting, cancellation, graceful
# shutdown (no orphan engine processes).
set -euo pipefail

cd "$(dirname "$0")/.."
BIN="${BIN:-./zig-out/bin/reclipz}"
FIXTURES="$(pwd)/tests/fixtures"
WORK="$(mktemp -d)"
PORT=8893
PORT_SLOW=8949
PORT_HTTP=8947

HTTP_PID=""
SLOW_PID=""
SRV_PID=""
cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true
  [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null || true
  [[ -n "$SLOW_PID" ]] && kill "$SLOW_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }

json() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

echo "== reclipz e2e ($($BIN version 2>&1 | head -1))"

python3 -m http.server "$PORT_HTTP" --bind 127.0.0.1 --directory "$FIXTURES" >/dev/null 2>&1 &
HTTP_PID=$!
python3 tests/slow_server.py "$PORT_SLOW" >/dev/null 2>&1 &
SLOW_PID=$!
sleep 1

$BIN serve --port "$PORT" --host 127.0.0.1 --cache-dir "$WORK/cache" --download-dir "$WORK/dl" \
  >"$WORK/server.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.25
done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/" || { cat "$WORK/server.log"; fail "server did not start"; }
pass "server started (pid $SRV_PID)"

# --- UI byte-identity -----------------------------------------------------------------------
curl -sf "http://127.0.0.1:$PORT/" -o "$WORK/index.html"
cmp -s "$WORK/index.html" src/assets/index.html || fail "index.html differs from upstream"
pass "GET / is byte-identical to upstream index.html"

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/static/favicon.svg")
[[ "$code" == "200" ]] || fail "favicon status $code"
pass "GET /static/favicon.svg"

# --- /api/info ------------------------------------------------------------------------------
info=$(curl -sf -X POST -H 'content-type: application/json' \
  -d "{\"url\":\"http://127.0.0.1:$PORT_HTTP/sample.mp4\"}" "http://127.0.0.1:$PORT/api/info")
[[ "$(echo "$info" | json 'd["title"]')" == "sample" ]] || fail "info title: $info"
pass "POST /api/info -> $(echo "$info" | head -c 80)…"

# --- error parity (the UI matches these substrings) -----------------------------------------
body=$(curl -s -X POST -H 'content-type: application/json' \
  -d '{"url":"https://example.com/definitely-not-a-video"}' "http://127.0.0.1:$PORT/api/info")
echo "$body" | grep -q "HTTP Error 404" || fail "error text lacks 'HTTP Error 404': $body"
pass "error text matches the UI's friendlyError() mapping"

# --- video download -------------------------------------------------------------------------
jid=$(curl -sf -X POST -H 'content-type: application/json' \
  -d "{\"url\":\"http://127.0.0.1:$PORT_HTTP/sample.mp4\",\"format\":\"video\",\"title\":\"E2E / Video: 1\"}" \
  "http://127.0.0.1:$PORT/api/download" | json 'd["job_id"]')
[[ ${#jid} -eq 10 ]] || fail "job id shape: $jid"
for _ in $(seq 1 60); do
  st=$(curl -sf "http://127.0.0.1:$PORT/api/status/$jid")
  echo "$st" | grep -q '"status":"done"\|"status":"error"' && break
  sleep 0.5
done
echo "$st" | grep -q '"done"' || fail "video job: $st"
[[ "$(echo "$st" | json 'd["filename"]')" == "E2E  Video 1.mp4" ]] || fail "filename: $st"
curl -sf "http://127.0.0.1:$PORT/api/file/$jid" -o "$WORK/video.mp4"
codecs=$("$BIN" ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$WORK/video.mp4" | sort | tr '\n' ' ')
[[ "$codecs" == *h264* && "$codecs" == *aac* ]] || fail "video is not h264+aac: $codecs"
pass "video download -> MP4 (h264+aac), sanitized filename, attachment"

# --- audio download -------------------------------------------------------------------------
jid=$(curl -sf -X POST -H 'content-type: application/json' \
  -d "{\"url\":\"http://127.0.0.1:$PORT_HTTP/sample.mp4\",\"format\":\"audio\",\"title\":\"E2E Audio\"}" \
  "http://127.0.0.1:$PORT/api/download" | json 'd["job_id"]')
for _ in $(seq 1 60); do
  st=$(curl -sf "http://127.0.0.1:$PORT/api/status/$jid")
  echo "$st" | grep -q '"status":"done"\|"status":"error"' && break
  sleep 0.5
done
echo "$st" | grep -q '"done"' || fail "audio job: $st"
curl -sf "http://127.0.0.1:$PORT/api/file/$jid" -o "$WORK/audio.mp3"
"$BIN" ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$WORK/audio.mp3" | grep -q mp3 \
  || fail "audio is not mp3"
pass "audio download -> MP3"

# --- concurrency: several jobs at once ------------------------------------------------------
jids=()
for i in 1 2 3 4 5 6; do
  jid=$(curl -sf -X POST -H 'content-type: application/json' \
    -d "{\"url\":\"http://127.0.0.1:$PORT_HTTP/sample.mp4\",\"format\":\"video\",\"title\":\"Par $i\"}" \
    "http://127.0.0.1:$PORT/api/download" | json 'd["job_id"]')
  jids+=("$jid")
done
done_count=0
for _ in $(seq 1 180); do
  done_count=0
  for jid in "${jids[@]}"; do
    st=$(curl -sf "http://127.0.0.1:$PORT/api/status/$jid")
    echo "$st" | grep -q '"status":"done"' && done_count=$((done_count + 1))
  done
  [[ "$done_count" -eq "${#jids[@]}" ]] && break
  sleep 0.5
done
[[ "$done_count" -eq "${#jids[@]}" ]] || fail "concurrency: $done_count/${#jids[@]} jobs finished"
pass "${#jids[@]} concurrent downloads"

# --- progress + cancellation ----------------------------------------------------------------
jid=$(curl -sf -X POST -H 'content-type: application/json' \
  -d "{\"url\":\"http://127.0.0.1:$PORT_SLOW/slow.mp4\",\"format\":\"video\",\"title\":\"Slow\"}" \
  "http://127.0.0.1:$PORT/api/download" | json 'd["job_id"]')
saw_progress=0
for _ in $(seq 1 40); do
  st=$(curl -sf "http://127.0.0.1:$PORT/api/status/$jid")
  echo "$st" | grep -q '"downloaded_bytes":[0-9]' && saw_progress=1 && break
  sleep 0.5
done
[[ "$saw_progress" == "1" ]] || fail "no progress reported: $st"
pass "status exposes live progress"
curl -sf -X POST "http://127.0.0.1:$PORT/api/cancel/$jid" >/dev/null || fail "cancel request failed"
cancelled=0
for _ in $(seq 1 20); do
  st=$(curl -sf "http://127.0.0.1:$PORT/api/status/$jid")
  echo "$st" | grep -q '"error":"Download cancelled"' && cancelled=1 && break
  sleep 0.5
done
[[ "$cancelled" == "1" ]] || fail "job was not cancelled: $st"
pass "job cancellation"

# --- graceful shutdown: no orphan engine processes ------------------------------------------
jid=$(curl -sf -X POST -H 'content-type: application/json' \
  -d "{\"url\":\"http://127.0.0.1:$PORT_SLOW/slow.mp4\",\"format\":\"video\",\"title\":\"Slow2\"}" \
  "http://127.0.0.1:$PORT/api/download" | json 'd["job_id"]')
sleep 2
engine_pids=$(ps -eo pid,cmd | grep "$WORK/cache/bin" | grep -v grep | awk '{print $1}' | tr '\n' ' ')
kill -TERM "$SRV_PID"
wait "$SRV_PID" 2>/dev/null && exit_code=0 || exit_code=$?
SRV_PID=""
[[ "$exit_code" == "0" ]] || fail "server exit code $exit_code on SIGTERM"
sleep 1
for pid in $engine_pids; do
  if kill -0 "$pid" 2>/dev/null; then fail "orphan engine process $pid after shutdown"; fi
done
pass "graceful shutdown killed engine process groups (${engine_pids:-none running})"

echo "== all e2e checks passed"
