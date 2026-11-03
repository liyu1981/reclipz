#!/usr/bin/env bash
# Real-network smoke test. Not part of `zig build test` (needs internet, sites may be geo/bot
# blocked from CI runners). Used by .github/workflows/nightly.yml and locally:
#
#   zig build -Dpayload-dir=none -Doptimize=ReleaseSafe
#   RECLIPZ_CACHE_DIR=/tmp/reclipz-nightly ./zig-out/bin/reclipz update
#   tests/network.sh
#
# A failure here usually means "upstream yt-dlp needs an update", not a reclipz regression —
# the script prints the engine's own error line so the two can be told apart.
set -uo pipefail

cd "$(dirname "$0")/.."
BIN="${BIN:-./zig-out/bin/reclipz}"
command -v "$BIN" >/dev/null || { echo "missing $BIN (zig build first)"; exit 2; }

urls=(
  "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  "https://vimeo.com/76979871"
  "https://soundcloud.com/forss/flickermood"
  "https://www.dailymotion.com/video/x8j8n3p"
  "https://www.reddit.com/r/aww/comments/1c0x0x/"
  "https://streamable.com/moo"
)

fail=0
for url in "${urls[@]}"; do
  if out=$("$BIN" yt-dlp --no-playlist --no-warnings -j "$url" 2>&1 >/dev/null); then
    printf '  \033[32mok\033[0m   %s\n' "$url"
  else
    printf '  \033[31mFAIL\033[0m %s\n        %s\n' "$url" "$(printf '%s' "$out" | tail -1 | head -c 200)"
    fail=1
  fi
done

if [[ "$fail" == "0" ]]; then echo "== network suite passed"; else echo "== network suite had failures (see above)"; fi
exit "$fail"
