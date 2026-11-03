# Experiments

Each file here is a throw-away probe that back the numbers in `../RESEARCH.md`.
They are kept (rather than deleted) so the plan's assumptions stay checkable.

Toolchain used: `zig 0.17.0`, `ffmpeg 7.1` (source build), `lame 3.100` (source build),
`quickjs-ng 0.18.0`.

---

## 1. `std.http.Client` + TLS — `fetch.zig`

```bash
zig build-exe fetch.zig -O ReleaseSafe --name fetch
./fetch https://example.com
```

Findings:

```
https://example.com            -> 200,    577 B
https://www.tiktok.com/        -> 200, 451,945 B
https://api.github.com/...     -> 200,   6,119 B
https://www.google.com/...     -> HANG (IPv6 blackhole, see RESEARCH.md §3.2)
```

Note: `main` must be `pub fn main(init: std.process.Init)` — in Zig 0.17 the `Io`
implementation comes from `init.io`. Using `std.Options.debug_threaded_io` from a
zero-arg `main` deadlocks.

---

## 2. `std.http.Server` + embedded reclip UI — `srvtest.zig`

`index.html` here is a byte-identical copy of upstream `templates/index.html`.

```bash
zig build-exe srvtest.zig -O ReleaseSafe --name srv
./srv & curl -s localhost:8899/ | cmp - index.html && echo identical
```

Findings: `GET /` → 200 with 21419 bytes (identical), `GET /api/ping` → JSON.
`ReleaseSafe` 4,128,088 B → stripped 657,256 B.

---

## 3. Minimal static FFmpeg — `remux.c` / `tomp3.c`

```bash
# FFmpeg (LGPL build, no GPL/nonfree, no x86 asm to avoid nasm)
curl -LO https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz && tar xf ffmpeg-7.1.tar.xz
cd ffmpeg-7.1
./configure --prefix=/tmp/ff --disable-everything --disable-programs --disable-doc \
  --disable-network --disable-autodetect --disable-avdevice --disable-avfilter \
  --disable-postproc --disable-swscale --disable-x86asm --enable-small \
  --enable-libmp3lame --enable-encoder=libmp3lame \
  --enable-demuxer=mov,matroska,mpegts,flv,mp3,aac,ogg,wav,hls \
  --enable-muxer=mp4,ipod,mp3,matroska \
  --enable-decoder=aac,mp3,opus,vorbis,flac,ac3,eac3,alac,pcm_s16le \
  --enable-parser=aac,h264,hevc,vp9,opus,vorbis,flac,mpegaudio \
  --enable-protocol=file,pipe,data --enable-swresample \
  --extra-cflags=-I/path/to/lame/include --extra-ldflags=-L/path/to/lame/lib
make -j$(nproc) && make install

# LAME (LGPL, static)
curl -LO https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
tar xf lame-3.100.tar.gz && cd lame-3.100
./configure --prefix=/tmp/lame --disable-shared --enable-static --disable-frontend
make -j$(nproc) && make install
```

Linking (note `--gc-sections`: the static archives are 23.7 MB, the reachable subset is ~3.5 MB):

```bash
zig cc -O2 -static -o remux remux.o \
  /tmp/ff/lib/libavformat.a /tmp/ff/lib/libavcodec.a \
  /tmp/ff/lib/libswresample.a /tmp/ff/lib/libavutil.a \
  -lm -lpthread -Wl,--gc-sections

zig cc -O2 -static -o tomp3 tomp3.o \
  /tmp/ff/lib/libavformat.a /tmp/ff/lib/libavcodec.a \
  /tmp/ff/lib/libswresample.a /tmp/ff/lib/libavutil.a \
  /tmp/lame/lib/libmp3lame.a -lm -lpthread -Wl,--gc-sections
```

Measured: `remux` 11.1 MB → 3.05 MB stripped; `tomp3` → 3.47 MB stripped.
Both verified on a 3 s H.264/AAC test clip (`ffprobe` shows h264+aac in the remuxed MP4,
`mp3 192 kb/s` for the converted audio).

`tomp3.c` is deliberately crude (it ignores encoder frame_size and floods a warning);
the production wrapper must buffer partial frames. It is only a size/feasibility probe.

---

## 4. yt-dlp's JS solver under QuickJS — `gen_solver_harness.py`

```bash
python3 gen_solver_harness.py --fake run_solver.js
qjs --script run_solver.js        # or quickjs-ng build/qjs
```

Output (synthetic player without n/sig functions, so "no solutions" is the correct result):

```json
{"type":"result","responses":[{"type":"error","error":"no solutions: "},{"type":"error","error":"no solutions: "}],"preprocessed_player":"..."}
```

This is the exact harness yt-dlp builds internally
(`extractor/youtube/jsc/_builtin/ejs.py::_construct_stdin`), proving the Unlicense solver
(`yt-dlp-ejs` wheel, 151 KB lib + 7 KB core) can be embedded and driven from a Zig host that
links quickjs-ng. Synthetic-case runtime: 19 ms.

---

## 5. Embedded engine payloads — `payload.zig`

```bash
curl -L -o payload-ytdlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux
cp /tmp/ff/out3/ffmpeg payload-ffmpeg      # or any static ffmpeg (see §3)
cp /tmp/ff/out3/ffprobe payload-ffprobe
chmod +x payload-*
zig build-exe payload.zig -O ReleaseSafe -femit-bin=reclipz-demo
./reclipz-demo --version                    # -> 2026.10.26 (payload extracted once to ~/.cache)
./reclipz-demo -x --audio-format mp3 --ffmpeg-location ~/.cache/reclipz-demo/<ver> -o out.%(ext)s <url>
```

Measured: 51.2 MB binary, 0.87 s cold / 0.83 s warm `--version` (PyInstaller re-extracts 41 MB per
run), 46 MB cache. `yt-dlp_musllinux` does **not** run on a glibc host (needs `/lib/ld-musl-*.so.1`).
