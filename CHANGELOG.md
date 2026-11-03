# Changelog

All notable changes to reclipz are documented here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] — 2026-11-03

### Added

- `reclipz cache info [--json]` and `reclipz cache clean [--tmp|--engines|--downloads|--all]
  [--dry-run]` to inspect and reclaim disk space (engine versions, leaked temp entries,
  finished downloads).
- `RECLIPZ_TMP_TTL` (default 3600 s; `0` disables) and `RECLIPZ_KEEP_PARTIAL` for controlling
  temp-file cleanup.
- `tools/dev.sh`: build and run a throwaway dev server (`./.dev/{cache,downloads}`), with
  `--fixture` for a local test URL, `--release`, `--no-build`, `--reset`, `--fetch`.

### Changed

- Job/TTL sweeper runs every 60 s (was 300 s); stale temp entries are swept at startup and every
  60 s, and obsolete yt-dlp/ffmpeg payload versions are pruned at startup (not only after
  `reclipz update`).
- `HOST` / `--host` placeholders are normalised (`auto`/`localhost` → `127.0.0.1`,
  `any`/`*`/`all` → `0.0.0.0`) so a polluted environment cannot break the bind.

### Fixed

- Fail fast with an actionable message when the embedded engine cannot execute (for example the
  `-musl` release on a glibc host: `FileNotFound` because `/lib/ld-musl-*.so.1` is missing).
  The server now probes `<engine> --version` at startup, and `selftest`/`reclipz yt-dlp` print the
  same hints. The API error is now `Engine failed to start (…) — run `reclipz selftest``.
- `-Dpayload-dir=none` builds failed to compile (`error.AccessDenied` was not in the inferred error
  set of `payload.resolve`); the hint now compares `@errorName`.
- Partial files of failed/cancelled/timed-out jobs are deleted (`downloads/.tmp/<job>/`); previously
  they were left behind.
- Docs: release-asset choice (gnu vs musl), checksum verification, troubleshooting table,
  "Disk usage and cleanup" section.

## [0.1.0] — 2026-11-03

First public release. `reclipz` is a Zig re-implementation of
[ReClip](https://github.com/averygan/reclip): the same web UI and API, packaged as a single
self-contained binary with the official yt-dlp engine and a minimal static ffmpeg embedded.

### Highlights

- **One binary, no runtime dependencies.** The official `yt-dlp` release binary and a minimal
  LGPL `ffmpeg`/`ffprobe` are compiled into the executable, extracted once into a versioned,
  hash-verified cache directory and executed from there. No Python, no `pip install`,
  no `apt install ffmpeg`.
- **Byte-identical frontend.** Upstream `templates/index.html` is embedded verbatim; the 7 API
  endpoints, status codes, error strings, format labels and filename rules match ReClip, so the UI
  needs no changes.
- **Updatable engine.** `reclipz update` downloads the latest official yt-dlp asset, verifies it
  against the release's `SHA2-256SUMS` (optionally its GPG signature), installs it into a versioned
  cache directory and atomically repoints `engine.json`. Site fixes no longer require a rebuild.
  `--check`, `--version <tag>`, `--force`, `--allow-unverified` are supported.
- **systemd user service.** `reclipz install-service` writes a hardened
  `~/.config/systemd/user/reclipz.service`, enables and starts it, and waits for it to become
  active; `--dry-run`, `--force`, `--no-enable`, `--linger`, `--no-hardening` (containers) are
  available. `uninstall-service` and `service-status` complete the lifecycle.
- **Real download pipeline.** Format selection identical to ReClip (`<format_id>+bestaudio/best`,
  `--merge-output-format mp4`), MP3 extraction via LAME, per-job temp directories with atomic
  finalisation, process-group timeouts, and no orphaned engine processes on shutdown.
- **Live progress and cancellation.** `/api/status` now also returns
  `progress {downloaded_bytes,total_bytes,speed,eta,percent,…}`, and `POST /api/cancel/<id>` stops a
  job (additive; the upstream UI ignores both).
- **Linux release matrix.** x86_64 and aarch64, glibc and musl, built from a single
  `tools/make_ffmpeg.sh --target …` cross-compilation recipe (zig cc, no cross toolchain).
- **Docker.** Multi-stage-free Alpine/musl image running as uid 1000, with `/downloads` and `/cache`
  volumes.

### Measured

| | |
| --- | --- |
| x86_64 release binary | 57 MB raw · **49 MB stripped** |
| Engine-less build (`-Dpayload-dir=none`) | 5.4 MB |
| One-time cache after first run | ~47 MB |
| Engine overhead per invocation | ~0.8 s (PyInstaller self-extract) |
| `reclipz selftest` (warm) | ~1 s |
| `reclipz update` (41 MB asset, verify + install) | ~2.5 s |

### Quick start

```bash
# download the binary for your platform (and verify it), then
sha256sum -c --ignore-missing SHA2-256SUMS
chmod +x reclipz-x86_64-linux-gnu
./reclipz-x86_64-linux-gnu                    # web UI on http://127.0.0.1:8899
./reclipz-x86_64-linux-gnu install-service    # optional: user systemd service
./reclipz-x86_64-linux-gnu update             # keep the engine current
```

Release assets: `reclipz-{x86_64,aarch64}-linux-{gnu,musl}`, verified by `SHA2-256SUMS`.

Building from source:

```bash
tools/fetch_payloads.sh && tools/make_ffmpeg.sh
zig build -Doptimize=ReleaseSmall
```

### Supported targets

| Target | yt-dlp payload |
| --- | --- |
| `x86_64-linux-gnu` | `yt-dlp_linux` (glibc ≥ 2.14) |
| `x86_64-linux-musl` | `yt-dlp_musllinux` |
| `aarch64-linux-gnu` | `yt-dlp_linux_aarch64` |
| `aarch64-linux-musl` | `yt-dlp_musllinux_aarch64` |

### Configuration

`PORT`, `HOST` (ReClip parity), `RECLIPZ_DOWNLOAD_DIR`, `RECLIPZ_CACHE_DIR`,
`RECLIPZ_MAX_CONCURRENT`, `RECLIPZ_JOB_TIMEOUT`, `RECLIPZ_JOB_TTL`, `RECLIPZ_ENGINE`,
`RECLIPZ_YTDLP`, `RECLIPZ_FFMPEG`, `RECLIPZ_COOKIES`, `RECLIPZ_PROXY`, `RECLIPZ_YTDLP_ARGS`,
`RECLIPZ_LOG`. See the README for details.

### Known limitations

- macOS and Windows are out of scope for this release (the payload plumbing is generic).
- Plain HTTP only, like upstream ReClip; use a reverse proxy for TLS/auth (README has recipes).
- YouTube PO-token-gated formats and DRM are not supported — the same limitation as upstream
  yt-dlp, which also ships no botguard provider.
- A real-browser UI test is not automated; the unmodified UI is exercised through the HTTP API in
  `tests/e2e.sh`.

### Tests

`zig build test` (unit), `tests/e2e.sh` (UI byte-identity, `/api/info`, error parity, MP4 h264+aac,
MP3, six concurrent jobs, live progress, cancellation, graceful shutdown without orphan processes),
`tests/service.sh` (live `systemctl --user` install/start/uninstall), `tests/network.sh` (nightly,
real sites).

### License

MIT (ReClip is MIT). The embedded `yt-dlp` payload is Unlicense; the embedded `ffmpeg`/`ffprobe`
payload is LGPL-2.1+ (built without GPL components). See `LICENSE` and `docs/PLAN.md` §9.4.

### Disclaimer

For personal use only. Respect copyright law and the terms of service of the platforms you download
from.
