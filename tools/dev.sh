#!/usr/bin/env bash
# Dev server: build reclipz, start it in the foreground with a throwaway cache/download dir.
#
#   tools/dev.sh                       # http://127.0.0.1:8899, ./.dev/{cache,downloads}
#   tools/dev.sh --fixture             # also serve tests/fixtures and print a test URL
#   tools/dev.sh --release --log debug
#   tools/dev.sh --port 9000 --reset
#
# Ctrl-C stops the server (and the fixture server, if any).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

port="${PORT:-8899}"
host="${RECLIPZ_DEV_HOST:-127.0.0.1}"
download_dir="$ROOT/.dev/downloads"
cache_dir="$ROOT/.dev/cache"
log_level="info"
mode="debug"
build=1
fixture=0
reset=0
fetch=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --port <n>          listen port                        (default 8899, env PORT)
  --host <addr>       bind address                       (default 127.0.0.1, env HOST)
  --download-dir <p>  where downloads are written        (default ./.dev/downloads)
  --cache-dir <p>     engine payload cache               (default ./.dev/cache)
  --log <level>       error | warn | info | debug        (default info)
  --release           build with ReleaseSafe instead of Debug
  --no-build          use the existing zig-out/bin/reclipz
  --fixture           serve tests/fixtures over HTTP and print a test URL
  --reset             delete ./.dev before starting
  --fetch             run tools/fetch_payloads.sh / tools/make_ffmpeg.sh when payloads are missing
  -h, --help          show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) port="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    --download-dir) download_dir="$2"; shift 2 ;;
    --cache-dir) cache_dir="$2"; shift 2 ;;
    --log) log_level="$2"; shift 2 ;;
    --release) mode="release"; shift ;;
    --no-build) build=0; shift ;;
    --fixture) fixture=1; shift ;;
    --reset) reset=1; shift ;;
    --fetch) fetch=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v zig >/dev/null || { echo "error: zig is not installed" >&2; exit 1; }

if [[ "$reset" == "1" ]]; then
  echo "== resetting $ROOT/.dev"
  rm -rf "$ROOT/.dev"
fi
mkdir -p "$download_dir" "$cache_dir"

# --- payloads -------------------------------------------------------------------------------
have_payload=0
[[ -s payload/yt-dlp ]] && have_payload=1

if [[ "$have_payload" == "0" ]]; then
  if [[ "$fetch" == "1" ]]; then
    echo "== fetching engine payloads (this downloads the official yt-dlp release)"
    tools/fetch_payloads.sh
    tools/make_ffmpeg.sh || echo "warn: ffmpeg build failed; MP4 merging/MP3 conversion will not work"
    have_payload=1
  elif command -v yt-dlp >/dev/null; then
    echo "warn: no payload/yt-dlp; falling back to the system yt-dlp on PATH (RECLIPZ_ENGINE=system)"
    export RECLIPZ_ENGINE=system
    build_payload_dir="none"
  else
    cat >&2 <<'EOF'
error: no engine payloads found in ./payload and no system yt-dlp on PATH.

  tools/fetch_payloads.sh      # official yt-dlp release (verified against SHA2-256SUMS)
  tools/make_ffmpeg.sh         # minimal static ffmpeg/ffprobe (~3 min)

  ...or re-run this script with --fetch.
EOF
    exit 1
  fi
fi
build_payload_dir="${build_payload_dir:-payload}"

# --- build ----------------------------------------------------------------------------------
if [[ "$build" == "1" ]]; then
  optimize="Debug"
  [[ "$mode" == "release" ]] && optimize="ReleaseSafe"
  echo "== building ($optimize)"
  zig build -Doptimize="$optimize" -Dpayload-dir="$build_payload_dir"
fi
BIN="$ROOT/zig-out/bin/reclipz"
[[ -x "$BIN" ]] || { echo "error: $BIN missing (run without --no-build)" >&2; exit 1; }

# --- process management ---------------------------------------------------------------------
srv_pid=""
fix_pid=""
cleanup() {
  [[ -n "$srv_pid" ]] && kill "$srv_pid" 2>/dev/null || true
  [[ -n "$fix_pid" ]] && kill "$fix_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

free_port() {
  python3 - "$1" <<'PY'
import socket, sys
start = int(sys.argv[1])
for port in range(start, start + 30):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", port))
        print(port)
        break
    except OSError:
        continue
    finally:
        s.close()
PY
}

if [[ "$fixture" == "1" ]]; then
  if command -v python3 >/dev/null; then
    fixture_port="$(free_port "${FIXTURE_PORT:-8947}")"
    python3 -m http.server "$fixture_port" --bind 127.0.0.1 --directory tests/fixtures >/dev/null 2>&1 &
    fix_pid=$!
    sleep 0.5
  else
    echo "warn: --fixture needs python3" >&2
  fi
fi

export RECLIPZ_DOWNLOAD_DIR="$download_dir"
export RECLIPZ_CACHE_DIR="$cache_dir"
export RECLIPZ_LOG="$log_level"

log_file="$ROOT/.dev/server.log"
echo
echo "  reclipz dev"
echo "    ui:        http://$host:$port"
echo "    download:  $download_dir"
echo "    cache:     $cache_dir"
echo "    logs:      $log_file  (or the console below)"
if [[ "$fixture" == "1" ]]; then
  echo "    test url:  http://127.0.0.1:$fixture_port/sample.mp4   (paste into the UI)"
fi
echo

# tee the log while keeping the server's pid (so Ctrl-C and cleanup reach the server itself)
"$BIN" serve --host "$host" --port "$port" > >(tee "$log_file") 2>&1 &
srv_pid=$!
wait "$srv_pid" || true
