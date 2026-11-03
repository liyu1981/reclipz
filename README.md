# reclipz

A Zig re-implementation of [ReClip](https://github.com/averygan/reclip) — a self-hosted video/audio
downloader with the *same web UI* — packaged as a **single self-contained binary**.

No Python install, no `pip install yt-dlp`, no `apt install ffmpeg`. The official yt-dlp release
binary and a minimal static `ffmpeg`/`ffprobe` are embedded in the executable, extracted once into a
cache directory, and executed from there.

```bash
reclipz                        # web UI on http://127.0.0.1:8899 (identical to ReClip)
reclipz install-service        # run it as a user-space systemd service
reclipz update                 # refresh the embedded yt-dlp (no rebuild)
reclipz yt-dlp <args...>       # run the embedded yt-dlp
reclipz ffmpeg <args...>       # run the embedded ffmpeg
reclipz which                  # resolved engine paths / versions
reclipz selftest               # verify the embedded engine works
```

> Status: **M2 complete** — server/API/jobs, payload extraction + update channel, live progress,
> cancellation, graceful shutdown, static ffmpeg cross-builds for linux x86_64/arm64 (glibc + musl),
> `install-service`, Docker image, end-to-end tests. Windows/macOS are out of scope.

## Quick start

```bash
# 1. Engine payloads (build time only; verified against the release's SHA2-256SUMS)
tools/fetch_payloads.sh
tools/make_ffmpeg.sh

# 2. Build (single static binary, ~49 MB with the official engine payload)
zig build -Doptimize=ReleaseSmall

# 3. Run
./zig-out/bin/reclipz                 # foreground
./zig-out/bin/reclipz install-service # or: systemd --user service (see below)
```

Open <http://localhost:8899>.

### Install as a user service

```bash
./zig-out/bin/reclipz install-service --download-dir ~/Downloads/reclipz
# optional: keep running after logout
./zig-out/bin/reclipz install-service --linger --force
# inspect
systemctl --user status reclipz
journalctl --user -u reclipz -f
# remove
./zig-out/bin/reclipz uninstall-service
```

`--dry-run` prints the generated `~/.config/systemd/user/reclipz.service` without writing it. The
unit runs `reclipz serve`, restarts on failure, and ships hardening flags (`NoNewPrivileges`,
`PrivateTmp`, `ProtectSystem=full`, `ProtectKernelTunables`, …). If your user manager cannot apply
them (some containers fail with `Failed to drop capabilities`), re-run with `--no-hardening`.
`tests/service.sh` verifies the whole flow against a live user systemd.

### Keep the engine current

```bash
reclipz update --check     # compare the active payload with the latest yt-dlp release
reclipz update             # download + verify (SHA2-256SUMS) + install + repoint engine.json
reclipz update --gpg       # also verify SHA2-256SUMS.sig with gpg if available
```

Site fixes no longer need a reclipz rebuild: `reclipz update` swaps the yt-dlp payload in the cache
(versioned directories, atomic `engine.json` pointer, old versions pruned).

### Docker

```bash
tools/fetch_payloads.sh --asset yt-dlp_musllinux --out payload
tools/make_ffmpeg.sh --target x86_64-linux-musl --out payload
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
docker compose up -d
```

The image runs as uid 1000. Named volumes (as in `docker-compose.yml`) inherit the image's
ownership and work out of the box; with bind mounts, `chown -R 1000:1000` the host directories (or
pass `--user $(id -u):$(id -g)`), otherwise the engine payload cannot be extracted into `/cache`.

## Features

| | |
| --- | --- |
| UI | byte-identical upstream `templates/index.html`, served from the binary |
| `/api/info` | yt-dlp JSON → `title/thumbnail/duration/uploader/formats` (video-only, best tbr per height, `1080p` labels) |
| `/api/playlist` | `--flat-playlist -J` → `{"urls": [...]}` |
| `/api/download` | video: `<format_id>+bestaudio/best` merged to MP4; audio: `-x --audio-format mp3` |
| `/api/status` | upstream tri-state **plus** live `progress` (bytes/speed/eta/percent) |
| `/api/cancel/<id>` | cancel a running job (kills the engine process group) |
| `/api/file/<id>` | streamed attachment, RFC 5987 filename |
| engine | official yt-dlp payload: extract-once cache (atomic, hash-verified), TMPDIR/PATH isolation, process-group timeouts, last-stderr-line errors |
| ops | graceful SIGINT/SIGTERM (kills engine children), job TTL sweeper, `selftest`, `which`, `update`, `install-service` |

Measured on Linux x86_64: **49 MB** stripped binary, 47 MB one-time cache, ~0.8 s engine overhead per
invocation (PyInstaller self-extract). Builds without payloads are ~5 MB (`-Dpayload-dir=none`).

## Migrating from ReClip

ReClip needs `python3`, `flask`, `yt-dlp` and `ffmpeg`; reclipz needs none of that.

1. Build (or download) the `reclipz` binary — see *Quick start*.
2. Stop the old instance (`Ctrl-C`, or `docker compose down`).
3. Run `./reclipz` (or `./reclipz install-service`). The web UI, API, download directory layout and
   filename rules are unchanged, so existing clients/bookmarks keep working.
4. If you used a `docker-compose.yml` from upstream, the only differences are the image build
   (no Python base image) and the addition of a `/cache` volume for the engine payload.

`RECLIP_NO_UPDATE` (upstream's "skip `pip install -U yt-dlp`") is accepted but unnecessary; engine
updates are explicit: `reclipz update`.

## HTTPS / reverse proxy

reclipz speaks plain HTTP on `HOST:PORT`, exactly like upstream ReClip, and intentionally does not
implement TLS or authentication. Put it behind a reverse proxy if it is exposed beyond localhost:

```nginx
server {
  listen 443 ssl;
  server_name clip.example.com;
  client_max_body_size 1m;
  location / {
    proxy_pass http://127.0.0.1:8899;
    proxy_http_version 1.1;
    proxy_read_timeout 600s;
    proxy_buffering off;          # /api/file streams large downloads
  }
}
```

Caddy equivalent: `clip.example.com { reverse_proxy 127.0.0.1:8899 }`.
Keep `HOST=127.0.0.1` when a proxy runs on the same host; use `HOST=0.0.0.0` only inside a container
network you control.

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
| `RECLIPZ_NO_UPDATE` | – | accepted for reclip parity (no-op; updates are explicit) |
| `RECLIPZ_LOG` | `info` | `error` / `warn` / `info` / `debug` |

## Supported targets

| Target | yt-dlp payload | ffmpeg payload |
| --- | --- | --- |
| `x86_64-linux-gnu` | `yt-dlp_linux` (glibc ≥ 2.14) | `tools/make_ffmpeg.sh` |
| `x86_64-linux-musl` | `yt-dlp_musllinux` | `tools/make_ffmpeg.sh --target x86_64-linux-musl` |
| `aarch64-linux-gnu` | `yt-dlp_linux_aarch64` | `tools/make_ffmpeg.sh --target aarch64-linux-gnu` |
| `aarch64-linux-musl` | `yt-dlp_musllinux_aarch64` | `tools/make_ffmpeg.sh --target aarch64-linux-musl` |

`tools/make_ffmpeg.sh --target …` cross-compiles ffmpeg/LAME with `zig cc` (no cross toolchain
needed). CI (`.github/workflows/release.yml`) builds all four targets and publishes them with
`SHA2-256SUMS`.

## Development

```bash
tools/dev.sh                    # build (Debug) + run on 127.0.0.1:8899, using ./.dev/{cache,downloads}
tools/dev.sh --fixture          # also serve tests/fixtures; paste the printed URL into the UI
tools/dev.sh --release --log debug --reset
tools/dev.sh --port 9000 --no-build
```

The dev server keeps its engine cache and downloads in `./.dev/`, so it never touches your real
`~/.cache/reclipz` or `~/Downloads`. Ctrl-C stops it (and the `--fixture` server) cleanly.
If `payload/` is missing it falls back to a system `yt-dlp`, or run it with `--fetch` to download the
official engine automatically.

```bash
zig build test                  # unit tests (JSON mapping, progress, unit file, checksums, ...)
zig build -Doptimize=ReleaseSafe
tests/e2e.sh                    # end-to-end: UI, info, MP4, MP3, concurrency, progress, cancel, shutdown
tests/service.sh                # install-service against a live user systemd (skips if unavailable)
tests/network.sh                # real-site smoke test (nightly CI)
zig fmt src build.zig
```

Layout: `src/{main,config,payload,update,proc,engine,jobs,server,service,shutdown,fsutil,assets,log}.zig`,
`src/assets/` (upstream UI + CA bundle), `tools/` (payload fetch, ffmpeg build), `tests/`, `docs/`,
`payload/` (build-time engine binaries, gitignored).

## How it works

```
browser (upstream UI, unchanged)
        │  8 JSON endpoints
        ▼
  Zig: std.http.Server → api routes → jobs (thread pool, progress, cancel)
        │
        ▼
  engine.zig  (argv identical to reclip's yt-dlp calls)
        │  spawn, deadline, progress lines, kill process group
        ▼
  payload.zig → <cache>/reclipz/bin/{yt-dlp/<version>,ffmpeg/<hash>}/…
```

The engine is upstream yt-dlp: **1,734 sites**, and site fixes arrive via `reclipz update` rather
than a recompile. The rationale (why not rewrite yt-dlp in Zig: 247 k LOC, 1,187 extractors, weekly
churn) is in [`docs/RESEARCH.md`](docs/RESEARCH.md); the architecture, API contract and milestones are
in [`docs/PLAN.md`](docs/PLAN.md). Every number was measured; probes live in
[`docs/experiments/`](docs/experiments/).

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `the embedded engine cannot be started: FileNotFound` at startup | Wrong release flavour: the **musl** build's engine needs `/lib/ld-musl-*.so.1`, which glibc hosts do not have. Download the `-gnu` asset (or, on Alpine, the `-musl` one). |
| `AccessDenied` / engine cannot run | The cache dir is on a `noexec` mount or not writable: set `RECLIPZ_CACHE_DIR` to an exec-capable directory. |
| UI says `Engine failed to start (…)` | The server's engine probe passed at startup but a job failed to spawn it; run `reclipz selftest` and check the server log. |
| A site stopped working | `reclipz update` (the engine is upstream yt-dlp; site fixes come from there). |
| `reclipz update` cannot reach GitHub | Check `HTTPS_PROXY`/`RECLIPZ_PROXY`, or set `RECLIPZ_YTDLP` to a local build. |

`reclipz selftest` checks the whole chain (engine execution, yt-dlp version, ffmpeg) in about a
second and prints the same hints.

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md) (release notes for each version are in
[`docs/release-notes/`](docs/release-notes/)).

## Disclaimer

For personal use only. Respect copyright law and the terms of service of the platforms you download
from. Same disclaimer as upstream ReClip.

## License

MIT (upstream ReClip is MIT). The embedded `yt-dlp` payload is Unlicense; the embedded
`ffmpeg`/`ffprobe` payload is LGPL-2.1+ (built without GPL components) — see `LICENSE` and
`docs/PLAN.md` §9.4.
