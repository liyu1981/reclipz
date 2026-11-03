#!/usr/bin/env bash
# Fetch the official yt-dlp release binary for this platform into ./payload and verify it
# against the release's SHA2-256SUMS file.
#
# Usage:
#   tools/fetch_payloads.sh                          # latest release, auto-detected platform
#   tools/fetch_payloads.sh 2026.10.26               # pinned tag
#   tools/fetch_payloads.sh --asset yt-dlp_linux_aarch64 --out payload
#   tools/fetch_payloads.sh --list                   # print the available assets
#
# The asset is chosen from the host libc: glibc hosts get `yt-dlp_linux`, musl hosts
# `yt-dlp_musllinux`. Override with --asset/YTDLP_ASSET (needed for cross builds).
set -euo pipefail

cd "$(dirname "$0")/.."
out_dir="payload"
tag="latest"
asset_override=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out_dir="$2"; shift 2 ;;
    --asset) asset_override="$2"; shift 2 ;;
    --list) tag="--list"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) tag="$1"; shift ;;
  esac
done
mkdir -p "$out_dir"

api="https://api.github.com/repos/yt-dlp/yt-dlp/releases"
if [[ "$tag" == "--list" ]]; then
  curl -fsSL "$api/latest" | python3 -c 'import json,sys;print("\n".join(a["name"] for a in json.load(sys.stdin)["assets"]))'
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

if [[ -n "${asset_override:-}" ]]; then
  asset="$asset_override"
elif [[ -n "${YTDLP_ASSET:-}" ]]; then
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
curl -fL --retry 3 -o "$out_dir/yt-dlp" "$url"

echo "verifying against SHA2-256SUMS"
sums_url="$(dirname "$url")/SHA2-256SUMS"
curl -fsSL -o /tmp/reclipz-SHA2-256SUMS "$sums_url"
expected="$(grep " ${asset}\$" /tmp/reclipz-SHA2-256SUMS | awk '{print $1}')"
if [[ -z "$expected" ]]; then
  echo "no checksum found for $asset" >&2
  exit 1
fi
actual="$(sha256sum "$out_dir/yt-dlp" | awk '{print $1}')"
if [[ "$expected" != "$actual" ]]; then
  echo "checksum mismatch for $asset" >&2
  echo "  expected $expected" >&2
  echo "  actual   $actual" >&2
  exit 1
fi
chmod +x "$out_dir/yt-dlp"

version="$("$out_dir/yt-dlp" --version 2>/dev/null || true)"
if [[ -z "$version" ]]; then
  # Cross-built payloads cannot run on this host; take the tag from the API instead.
  version="$(curl -fsSL "$base" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')"
fi
echo "$version" > "$out_dir/yt-dlp.version"
echo "ok: yt-dlp $version (sha256 $actual)"
echo
echo "Next: tools/make_ffmpeg.sh --out $out_dir (or drop a static ffmpeg + ffprobe there), then:"
echo "      zig build -Doptimize=ReleaseSafe   # add -Dtarget=<target> for cross builds"
