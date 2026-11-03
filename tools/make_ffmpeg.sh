#!/usr/bin/env bash
# Build a minimal, LGPL, static ffmpeg + ffprobe for embedding into reclipz.
#
# This is deliberately small: it can remux/copy (mp4/webm/mkv), decode AAC/Opus/Vorbis/MP3/FLAC
# audio and encode MP3 (libmp3lame). That is exactly what yt-dlp's `--merge-output-format` and
# `-x --audio-format mp3` paths need. No GPL/non-free components, no video encoders.
#
# Usage: tools/make_ffmpeg.sh [--prefix <dir>]
# Output: <prefix>/ffmpeg, <prefix>/ffprobe (default: ./payload)
set -euo pipefail

cd "$(dirname "$0")/.."
prefix="$(pwd)/payload"
if [[ "${1:-}" == "--prefix" ]]; then prefix="$2"; fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
LAME_VERSION="${LAME_VERSION:-3.100}"
jobs="$(nproc 2>/dev/null || echo 4)"

echo "== building LAME $LAME_VERSION (LGPL) =="
curl -fL --retry 3 -o "$work/lame.tar.gz" \
  "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
tar -C "$work" -xzf "$work/lame.tar.gz"
(
  cd "$work/lame-$LAME_VERSION"
  ./configure --prefix="$work/lame" --disable-shared --enable-static --disable-frontend >/dev/null
  make -j"$jobs" >/dev/null
  make install >/dev/null
)

echo "== building FFmpeg $FFMPEG_VERSION (LGPL, static) =="
curl -fL --retry 3 -o "$work/ffmpeg.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
tar -C "$work" -xf "$work/ffmpeg.tar.xz"
(
  cd "$work/ffmpeg-$FFMPEG_VERSION"
  ./configure \
    --disable-everything --disable-doc --disable-network --disable-autodetect \
    --disable-avdevice --disable-postproc --disable-swscale --disable-swscale-alpha \
    --disable-x86asm --enable-small --enable-ffmpeg --enable-ffprobe \
    --enable-libmp3lame --enable-encoder=libmp3lame \
    --enable-demuxer=mov,matroska,mpegts,flv,mp3,aac,ogg,wav,image2 \
    --enable-muxer=mp4,ipod,mp3,matroska,image2 \
    --enable-decoder=aac,mp3,opus,vorbis,flac,ac3,eac3,alac,pcm_s16le,mjpeg,png \
    --enable-encoder=mjpeg,png \
    --enable-parser=aac,h264,hevc,vp9,opus,vorbis,flac,mpegaudio \
    --enable-protocol=file,pipe,data \
    --enable-filter=aresample,aformat,anull,anullsrc,format,null,copy,concat,trim,atrim,volume,amix,amerge,apad,asetpts,fps,setpts \
    --enable-swresample --enable-avfilter \
    --extra-cflags="-I$work/lame/include" --extra-ldflags="-L$work/lame/lib" \
    >/dev/null
  make -j"$jobs" >/dev/null
)

mkdir -p "$prefix"
install -m 0755 "$work/ffmpeg-$FFMPEG_VERSION/ffmpeg" "$prefix/ffmpeg"
install -m 0755 "$work/ffmpeg-$FFMPEG_VERSION/ffprobe" "$prefix/ffprobe"

echo "ok: $prefix/ffmpeg ($(stat -c%s "$prefix/ffmpeg") bytes), $prefix/ffprobe ($(stat -c%s "$prefix/ffprobe") bytes)"
echo "licence: LGPL-2.1-or-later (built without --enable-gpl); ship THIRD_PARTY_LICENSES + sources."
