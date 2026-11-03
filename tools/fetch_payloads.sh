#!/usr/bin/env bash
# Fetch the official yt-dlp release binary for this platform into ./payload and verify it
# against the release's SHA2-256SUMS file.
#
# Usage:
#   tools/fetch_payloads.sh                 # latest release, auto-detected platform
#   tools/fetch_payloads.sh 2026.10.26      # pinned tag
#   tools/fetch_payloads.sh --list          # print the available assets
#
# The asset is chosen from the host libc: glibc hosts get `yt-dlp_linux`, musl hosts
# `yt-dlp_musllinux`. Override with YTDLP_ASSET=... if you know what you are doing.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p payload

api="https://api.github.com/repos/yt-dlp/yt-dlp/releases"
tag="${1:-latest}"
if [[ "$tag" == "--list" ]]; then
  curl -fsSL "$api/latest" | grep -o '"name": *"yt-dlp[^"]*"' | sed 's/.*"\(yt-dlp[^"]*\)"/\1/'
  exit 0
fi
if [[ "$tag" == "latest" ]]; then
  base="$api/latest"
else
  base="$api/tags/$tag"
fi

arch="$(uname -m)"
libc="glibc"
if ldd --version 2>&1 | head -1 | grep -qi musl; then libc="musl"; fi

if [[ -n "${YTDLP_ASSET:-}" ]]; then
  asset="$YTDLP_ASSET"
elif [[ "$libc" == "musl" ]]; then
  case "$arch" in
    x86_64) asset="yt-dlp_musllinux" ;;
    aarch64|arm64) asset="yt-dlp_musllinux_aarch64" ;;
    *) echo "unsupported musl arch: $arch" >&2; exit 1 ;;
  esac
else
  case "$arch" in
    x86_64) asset="yt-dlp_linux" ;;
    aarch64|arm64) asset="yt-dlp_linux_aarch64" ;;
    *) echo "unsupported arch: $arch (use YTDLP_ASSET=...)" >&2; exit 1 ;;
  esac
fi

url="$(curl -fsSL "$base" | python3 -c '
import json,sys
d=json.load(sys.stdin)
name=sys.argv[1]
for a in d["assets"]:
    if a["name"]==name:
        print(a["browser_download_url"]); break
else:
    sys.exit(f"asset not found: {name}")
' "$asset")"

echo "downloading $asset from $url"
curl -fL --retry 3 -o "payload/yt-dlp" "$url"

echo "verifying against SHA2-256SUMS"
sums_url="$(dirname "$url")/SHA2-256SUMS"
curl -fsSL -o /tmp/reclipz-SHA2-256SUMS "$sums_url"
expected="$(grep " ${asset}\$" /tmp/reclipz-SHA2-256SUMS | awk '{print $1}')"
if [[ -z "$expected" ]]; then
  echo "no checksum found for $asset" >&2
  exit 1
fi
actual="$(sha256sum "payload/yt-dlp" | awk '{print $1}')"
if [[ "$expected" != "$actual" ]]; then
  echo "checksum mismatch for $asset" >&2
  echo "  expected $expected" >&2
  echo "  actual   $actual" >&2
  exit 1
fi
chmod +x payload/yt-dlp

version="$(./payload/yt-dlp --version)"
echo "$version" > payload/yt-dlp.version
echo "ok: yt-dlp $version (sha256 $actual)"
echo
echo "Next: tools/make_ffmpeg.sh (or drop a static ffmpeg + ffprobe into payload/), then: zig build -Doptimize=ReleaseSafe"
