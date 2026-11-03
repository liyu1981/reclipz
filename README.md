# reclipz

A Zig re-implementation of [ReClip](https://github.com/averygan/reclip) — a self-hosted video/audio
downloader with the *same web UI* — packaged as a **single self-contained binary**.

No Python install, no `pip install yt-dlp`, no `apt install ffmpeg`. The official yt-dlp release
binary and a minimal static `ffmpeg`/`ffprobe` are embedded in the executable, extracted once into a
cache directory, and executed.

```
reclipz                     # web UI on http://127.0.0.1:8899 (identical to ReClip)
reclipz yt-dlp <args...>    # run the embedded yt-dlp
reclipz ffmpeg <args...>    # run the embedded ffmpeg
reclipz ffprobe <args...>   # run the embedded ffprobe
reclipz which               # resolved engine paths / versions
reclipz selftest            # verify the embedded engine works
```

> Status: **M1 (working prototype)**. The server, API, job pipeline, payload extraction, engine
> invocation, MP4 merge and MP3 conversion work end-to-end. `reclipz update` and the release matrix
> are next (`docs/PLAN.md` M2/M3).

## Quick start

```bash
# 1. Fetch the official yt-dlp release binary for your platform (verified against SHA2-256SUMS)
tools/fetch_payloads.sh

# 2. Minimal static ffmpeg/ffprobe (LGPL, ~6 MB) — or copy your own into payload/
tools/make_ffmpeg.sh

# 3. Build and run
zig build -Doptimize=ReleaseSafe
./zig-out/bin/reclipz
```

Payloads live in `payload/` at **build** time and are compiled into the binary. They are gitignored;
`zig build` also works without them (`RECLIPZ_ENGINE=system` / `RECLIPZ_YTDLP` then use host
binaries), which is handy for development.

## What works today

| | |
| --- | --- |
| UI | byte-identical upstream `templates/index.html`, served from the binary |
| `/api/info` | real yt-dlp JSON → `title/thumbnail/duration/uploader/formats` (video-only, best tbr per height, `1080p` labels, desc) |
| `/api/playlist` | `--flat-playlist -J` → `{"urls": [...]}` |
| `/api/download` | video: `<format_id>+bestaudio/best` merged to MP4; audio: `-x --audio-format mp3` |
| `/api/status`, `/api/file` | upstream tri-state status, RFC 5987 attachment filenames, 10-hex job ids |
| engine | official yt-dlp binary embedded, extract-once cache (atomic, hash-verified), process-group timeouts, last-stderr-line errors |
| CLI | `serve` (default), `yt-dlp`, `ffmpeg`, `ffprobe`, `which`, `version`, `selftest` |

Measured on Linux x86_64: **48 MB** stripped binary (41.2 MB yt-dlp + 6 MB ffmpeg/ffprobe + ~1 MB
Zig), 46 MB one-time cache, ~0.8 s engine overhead per invocation (PyInstaller self-extract).
`reclipz selftest` → ~1 s warm.

Not yet: `reclipz update` (payload refresh), per-card progress, Windows/macOS payloads, HTTPS
serving (use a reverse proxy, same as upstream reclip).

## How it works

```
browser (upstream UI, unchanged)
        │  7 JSON endpoints
        ▼
  Zig: std.http.Server → api/routes → jobs (thread pool)
        │
        ▼
  engine.zig  (argv identical to reclip's yt-dlp calls)
        │  spawn, deadline, kill process group
        ▼
  payload.zig → <cache>/reclipz/bin/<yt-dlp-version>/{yt-dlp,ffmpeg,ffprobe}
```

The engine is upstream yt-dlp: **1,734 sites**, and site fixes arrive by swapping the payload rather
than recompiling. The full rationale (why not rewrite yt-dlp in Zig: 247 k LOC, 1,187 extractors,
weekly churn) is in [`docs/RESEARCH.md`](docs/RESEARCH.md). The architecture, API contract and
milestones are in [`docs/PLAN.md`](docs/PLAN.md). Every number was measured; probes live in
[`docs/experiments/`](docs/experiments/).

## Configuration

| Variable | Default | |
| --- | --- | --- |
| `PORT` / `HOST` | `8899` / `127.0.0.1` | same as upstream ReClip |
| `RECLIPZ_DOWNLOAD_DIR` | `./downloads` | |
| `RECLIPZ_CACHE_DIR` | `$XDG_CACHE_HOME/reclipz` | must be exec-capable |
| `RECLIPZ_MAX_CONCURRENT` | `3` | parallel engine invocations |
| `RECLIPZ_JOB_TIMEOUT` | `300` | seconds per job |
| `RECLIPZ_JOB_TTL` | `86400` | delete finished jobs after N s (`0` = keep) |
| `RECLIPZ_ENGINE` | `embedded` | `system` / `auto` |
| `RECLIPZ_YTDLP` / `RECLIPZ_FFMPEG` | – | explicit binaries |
| `RECLIPZ_COOKIES` | – | Netscape `cookies.txt` (Instagram/Facebook/X) |
| `RECLIPZ_PROXY` | – | passed to the engine |
| `RECLIPZ_YTDLP_ARGS` | – | extra engine arguments |
| `RECLIPZ_LOG` | `info` | `error` / `warn` / `info` / `debug` |

## Development

```bash
zig build test            # unit tests (JSON mapping, filename rules, job ids, ...)
zig build -Doptimize=ReleaseSafe
zig fmt src build.zig
```

Layout: `src/{main,cli-ish config,payload,proc,engine,jobs,server,fsutil,assets}.zig`,
`src/assets/` (upstream UI), `tools/` (payload fetch + ffmpeg build), `docs/`, `payload/` (build-time
engine binaries, gitignored).

## Disclaimer

For personal use only. Respect copyright law and the terms of service of the platforms you download
from. Same disclaimer as upstream ReClip.

## License

MIT (upstream ReClip is MIT). The embedded `yt-dlp` payload is Unlicense; the embedded
`ffmpeg`/`ffprobe` payload is LGPL-2.1+ (built without GPL components) — see `LICENSE` and
`docs/PLAN.md` §9.4.
