#!/usr/bin/env bash
# Build a minimal, LGPL, static ffmpeg + ffprobe for embedding into reclipz.
#
# Deliberately small: it can remux/copy (mp4/webm/mkv), decode AAC/Opus/Vorbis/MP3/FLAC audio and
# encode MP3 (libmp3lame). That is exactly what yt-dlp's `--merge-output-format` and
# `-x --audio-format mp3` paths need. No GPL/non-free components, no video encoders.
#
# Usage:
#   tools/make_ffmpeg.sh                          # native build -> payload/
#   tools/make_ffmpeg.sh --target aarch64-linux-musl
#   tools/make_ffmpeg.sh --out /tmp/my-payload
#
# Cross builds use `zig cc` (no cross toolchain needed) and disable assembly optimisations;
# the result is stripped at link time (-s), because the host `strip` cannot touch foreign ELFs.
set -euo pipefail

cd "$(dirname "$0")/.."

out_dir="$(pwd)/payload"
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out_dir="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
LAME_VERSION="${LAME_VERSION:-3.100}"
jobs="$(nproc 2>/dev/null || echo 4)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

native=true
cross_flags=()
ff_cross=()
arch="$(uname -m)"
if [[ -n "$target" ]]; then
  native=false
  cross_flags=(
    CC="zig cc -target $target"
    CXX="zig c++ -target $target"
    AR="zig ar"
    RANLIB="zig ranlib"
  )
  case "$target" in
    x86_64*) arch="x86_64" ;;
    aarch64*) arch="aarch64" ;;
    *) arch="$(uname -m)" ;;
  esac
  ff_cross=(
    --enable-cross-compile --arch="$arch" --target-os=linux
    --cc="zig cc -target $target" --cxx="zig c++ -target $target"
    --ar="zig ar" --ranlib="zig ranlib" --nm="nm"
    --disable-asm --disable-x86asm --disable-stripping
  )
fi

echo "== building LAME $LAME_VERSION (LGPL)${target:+ for $target} =="
curl -fsSL --retry 3 -o "$work/lame.tar.gz" \
  "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
tar -C "$work" -xzf "$work/lame.tar.gz"
(
  cd "$work/lame-$LAME_VERSION"
  ./configure --prefix="$work/lame" --disable-shared --enable-static --disable-frontend \
    ${target:+--host="$target"} "${cross_flags[@]}" >/dev/null
  make -j"$jobs" >/dev/null
  make install >/dev/null
)

echo "== building FFmpeg $FFMPEG_VERSION (LGPL, static)${target:+ for $target} =="
curl -fsSL --retry 3 -o "$work/ffmpeg.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
tar -C "$work" -xf "$work/ffmpeg.tar.xz"
(
  cd "$work/ffmpeg-$FFMPEG_VERSION"
  ldflags="-L$work/lame/lib"
  if [[ "$native" == "false" ]]; then ldflags="$ldflags -s"; fi
  ./configure \
    --disable-everything --disable-doc --disable-network --disable-autodetect \
    --disable-avdevice --disable-postproc --disable-swscale --disable-swscale-alpha \
    --enable-small --enable-ffmpeg --enable-ffprobe \
    --enable-libmp3lame --enable-encoder=libmp3lame \
    --enable-demuxer=mov,matroska,mpegts,flv,mp3,aac,ogg,wav,image2 \
    --enable-muxer=mp4,ipod,mp3,matroska,image2 \
    --enable-decoder=aac,mp3,opus,vorbis,flac,ac3,eac3,alac,pcm_s16le,mjpeg,png \
    --enable-encoder=mjpeg,png \
    --enable-parser=aac,h264,hevc,vp9,opus,vorbis,flac,mpegaudio \
    --enable-protocol=file,pipe,data \
    --enable-filter=aresample,aformat,anull,anullsrc,format,null,copy,concat,trim,atrim,volume,amix,amerge,apad,asetpts,fps,setpts \
    --enable-swresample --enable-avfilter \
    "${ff_cross[@]}" \
    --extra-cflags="-I$work/lame/include" --extra-ldflags="$ldflags" \
    >/dev/null
  make -j"$jobs" >/dev/null
)

mkdir -p "$out_dir"
install -m 0755 "$work/ffmpeg-$FFMPEG_VERSION/ffmpeg" "$out_dir/ffmpeg"
install -m 0755 "$work/ffmpeg-$FFMPEG_VERSION/ffprobe" "$out_dir/ffprobe"

echo "ok: $out_dir/ffmpeg ($(stat -c%s "$out_dir/ffmpeg") bytes), $out_dir/ffprobe ($(stat -c%s "$out_dir/ffprobe") bytes)"
echo "licence: LGPL-2.1-or-later (built without --enable-gpl); ship LICENSE + sources."
