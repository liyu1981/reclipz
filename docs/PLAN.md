# reclipz — Implementation Plan (v2: embedded-engine)

Zig re-implementation of [reclip](https://github.com/averygan/reclip) as **one self-contained
binary**: the untouched reclip web UI, a Zig HTTP/API layer, and the official
**`yt-dlp` + `ffmpeg` release binaries embedded as payloads**.

Supersedes v1 (`docs/RESEARCH.md` §6/§8 remains the analysis; the v1 "native extractor" architecture
is dropped). New evidence for this design: `docs/RESEARCH.md` §10 and `docs/experiments/payload.zig`.

---

## 0. What changed from v1, and why

v1 planned a Zig re-implementation of yt-dlp's engine (extractors, HLS/DASH, format selection,
QuickJS for YouTube's JS challenges) — 12–15 weeks, 1,187 extractors forever unported.

v2 embeds the official yt-dlp release binary instead:

| | v1 (native engine) | v2 (embedded engine) |
| --- | --- | --- |
| Binary size | 6–8 MB | **~51 MB** (measured) |
| Time to working product | 12–15 weeks | **4–6 weeks** |
| Site coverage | ~20 sites + JS pack | **1,734 sites** (whatever upstream supports) |
| Site fixes | our release / JS pack | **`reclipz update`** (swap the payload, no recompile) |
| YouTube/POT/DRM edge cases | months of work | upstream's problem |
| Zig code | ~20k LOC | **~3k LOC** (server, API, jobs, payload, process, CLI) |
| Per-invocation overhead | ~0 | **~0.83 s** (PyInstaller self-extract, measured) |
| Runtime deps | none | none (still one binary) |
| Cache dir needed | no | **yes**, 46 MB extracted once (+ temp writes) |

The trade is explicit: we stop being "yt-dlp rewritten in Zig" and become "a Zig host that embeds
the official engine". That is a legitimate (and very common) architecture, and it is the only one
that makes reclipz usable across 1,734 sites this year. If native extraction is still wanted later,
it can be added as an *optional* third engine without changing anything else.

---

## 0.1 Implementation status

| Milestone | State |
| --- | --- |
| **M0** skeleton, UI, API, jobs | **done** |
| **M1** payload layer, process layer, real engine, download+merge+MP3 | **done** |
| **M2** `reclipz update`, live progress, cancellation, graceful shutdown, `install-service` | **done** |
| **M3** linux release matrix (x86_64/aarch64 × gnu/musl), Docker image, CI release workflow | **done** |
| **M4** hardening: unit + e2e suites, fuzz-ish inputs, orphan-process checks, nightly network suite | **done** |

Verified end-to-end (`tests/e2e.sh`, 12 checks) on Linux x86_64 with the official `yt-dlp_linux`
2026.10.26 payload and a minimal LGPL ffmpeg 7.1 build:

- `GET /` is byte-identical to upstream `templates/index.html` (21,419 B).
- `/api/info` → yt-dlp JSON mapping; errors keep upstream's last-stderr-line contract
  (`HTTP Error 404` → the UI's `friendlyError()` mapping fires).
- video job → MP4 (h264+aac); audio job → MP3 (both verified with ffprobe).
- `/api/status` exposes live `progress`; `/api/cancel/<id>` stops the job and kills the engine group.
- SIGTERM → exit 0, engine process groups killed (no orphan yt-dlp/ffmpeg).
- `reclipz update` downloads the official asset, verifies SHA2-256SUMS, installs it into a versioned
  cache dir and repoints `engine.json` (measured: 2.5 s for 41 MB on a warm connection).
- `reclipz install-service --dry-run` renders a hardened user unit.
- Cross builds validated: `aarch64-linux-musl` (payload `yt-dlp_musllinux_aarch64` + zig-cc-built
  ffmpeg/ffprobe) produces a 57 MB aarch64 ELF.

Sizes: x86_64 release 52.6 MB unstripped / **49.0 MB stripped**; no-payload build 5.4 MB;
one-time cache ~47 MB.

---

## 1. Goal & scope

```bash
reclipz                      # = reclipz serve: http://127.0.0.1:8899, identical UI
reclipz serve --port 9000
reclipz yt-dlp -j <url>      # pass-through to the embedded yt-dlp
reclipz ffmpeg -i a.mp4 ...  # pass-through to the embedded ffmpeg
reclipz ffprobe ...
reclipz update [--check]     # refresh the embedded/released yt-dlp payload
reclipz which                # print resolved payload paths + versions
reclipz selftest             # DNS/TLS/payload/ffmpeg/exec smoke test
```

### In scope (v1 of reclipz)

- **Parity with reclip's UI and API** (7 endpoints, byte-identical frontend) — §5.
- Video → MP4 (`<format_id>+bestaudio/best`, merged), audio → MP3 (`-x --audio-format mp3`).
- Bulk downloads, playlist expansion, per-job status polling, filename sanitization.
- Single binary, no runtime dependencies; works on a `scratch` container.
- Payload integrity (hash-pinned), atomic extract-once, concurrent-safe, `noexec`-aware.
- Updatable engine (`reclipz update`) with checksum verification.

### Out of scope

- Subtitles/SponsorBlock/thumbnails/cookies-from-browser in the **UI** (the engine supports them; we
  simply don't expose UI for them — same as reclip). Cookies via `cookies.txt` *file* is exposed
  because the engine needs it for Instagram/Facebook/X.
- HTTPS server (reclip is HTTP-only too; document a reverse proxy).
- Re-encoding video, DRM, live recording (engine may do parts of it; we don't add UI).

---

## 2. Architecture

```
                      ┌───────────────────────────────────────────────────────┐
 browser (unchanged)  │  src/http/server.zig     std.http.Server, thread pool │
 upstream index.html─►│  src/api/routes.zig      7 endpoints (frozen contract)│
                      │  src/api/jobs.zig        job registry + worker pool   │
                      └──────────────┬────────────────────────────────────────┘
                                     │
                      ┌──────────────┴───────────────┐
                      │  src/engine.zig              │  builds argv exactly like reclip
                      │  src/proc.zig                │  spawn, stream, timeout, kill group
                      │  src/engine_json.zig         │  -j / --flat-playlist -J parsing
                      └──────────────┬───────────────┘
                                     │  exec
        ┌────────────────────────────┴────────────────────────────────┐
        │  src/payload.zig   embedded blobs → extract-once cache      │
        │   <cache>/reclipz/bin/<ver>-<target>/yt-dlp,ffmpeg,ffprobe   │
        └────────────────────────────┬────────────────────────────────┘
                                     │
        ┌────────────────────────────┴────────────────────────────────┐
        │  src/payload_update.zig   fetch + verify SHA2-256SUMS       │
        │  src/config.zig  src/cli.zig  src/assets.zig  src/log.zig   │
        └─────────────────────────────────────────────────────────────┘
```

No C libraries, no Python headers, no libav* linking, no QuickJS. The only "C integration" is
running child processes, which is `std.process`.

### 2.1 Repo layout

```
build.zig                    # exe, @embedFile payloads, hash manifest, tests, install
build.zig.zon                # pinned zig version
build/payload.zig            # zig build step: fetch/select/verify engine payloads per target
src/main.zig                 # dispatch: serve (default) | yt-dlp | ffmpeg | ffprobe | update | ...
src/cli.zig                  # arg parsing, help, exit codes
src/config.zig               # env + flags (UPSTREAM_PORT parity), Config struct
src/log.zig                  # leveled logger
src/assets.zig               # @embedFile: index.html, favicon.svg, cacert.pem
src/http/server.zig          # accept loop, keep-alive, limits, graceful shutdown
src/http/router.zig          # method + path pattern dispatch
src/api/routes.zig           # the 7 endpoints
src/api/jobs.zig             # Job state, worker pool, TTL sweeper, cancellation
src/api/files.zig            # streaming attachment response, RFC 5987 filename
src/engine.zig               # argv builders: info / playlist / download(video|audio)
src/engine_json.zig          # tolerant JSON-lines parser, format list mapping (reclip logic)
src/proc.zig                 # spawn, pipes, line reader, timeout, process-group kill
src/payload.zig              # embed manifest, extract-once, locking, exec resolution
src/payload_update.zig       # update channel (download + checksum verify + cache swap)
src/version.zig              # reclipz version + embedded payload versions
assets/index.html            # byte-identical upstream templates/index.html
assets/favicon.svg           # byte-identical upstream static/favicon.svg
assets/cacert.pem            # ~220 KB, for `reclipz update` (HTTPS via std.http.Client)
third_party/engine.lock      # yt-dlp version + per-target sha256, ffmpeg build recipe + sha256
tools/fetch_payloads.zig     # release-asset download + SHA2-256SUMS verification
tools/make_ffmpeg.sh         # minimal LGPL ffmpeg/ffprobe build (CI + local)
tests/{unit,fixtures,e2e}/   # argv goldens, API contract, local-server E2E, Playwright
```

---

## 3. Payload layer (`src/payload.zig`) — the heart of v2

### 3.1 What gets embedded

| Payload | Source | Size (measured) | Licence |
| --- | --- | --- | --- |
| `yt-dlp` | official release asset for the target (`yt-dlp_linux`, `yt-dlp_musllinux`, `yt-dlp_linux_aarch64`, `yt-dlp_macos`, `yt-dlp.exe`, …) | **41.2 MB** | Unlicense |
| `ffmpeg` | our minimal LGPL static build (CI) or a user-supplied prebuilt | **3.0 MB** | LGPL-2.1+ |
| `ffprobe` | same build | **2.9 MB** | LGPL-2.1+ |
| UI assets + CA | repo | 0.25 MB | MIT |
| Zig code | — | ~0.7 MB | MIT |
| **`reclipz` binary** | | **51.2 MB** (measured, `docs/experiments/payload.zig`) | |

Notes from the measurements:

- Compressing the yt-dlp payload is **pointless**: it is a PyInstaller archive that is already
  zlib-compressed (41.2 MB → 40.6 MB at `zstd -19`). Do not add a decompressor for it.
- Compressing ffmpeg/ffprobe **is** worthwhile (3.07 MB → 1.25 MB), but only saves ~3 MB; keep it
  simple and store them raw in v1, add zstd later if the size budget is tight.
- The official binaries are **not** fully static:
  - `yt-dlp_linux` needs glibc **≥ 2.14** (`ld-linux-x86-64.so.2`, `libz.so.1`, …).
  - `yt-dlp_musllinux` needs `/lib/ld-musl-x86_64.so.1` + `libz.so.1` (musl) → **does not run on a
    glibc host** (verified: "cannot execute: required file not found").
  → the payload must be chosen per build target, and the docs must state the libc requirement.

### 3.2 Extract-once cache

```
<cache>/reclipz/
  bin/<payload-version>/<target>/
    yt-dlp        (0o755, hash-verified)
    ffmpeg        (0o755)
    ffprobe       (0o755)
    .complete     (marker written last; the dir is only trusted if present)
    .lock         (flock for first-run races)
  tmp/            (TMPDIR for children — PyInstaller unpacks ~41 MB per run here)
  yt-dlp/         (--cache-dir for yt-dlp)
```

Rules:

1. `<cache>` = `RECLIPZ_CACHE_DIR` → `XDG_CACHE_HOME/reclipz` → `$HOME/.cache/reclipz` → `/tmp/reclipz`.
2. Extract into `<version>.tmp.<pid>`, `fsync`, `chmod 0755`, write `.complete`, `rename()` the dir
   into place. A second process that loses the race renames over it harmlessly (same content) or
   reuses the winner.
3. Never extract into the download dir (user-visible) and never reuse an unverified dir: verify
   sha256 of each file against the compile-time manifest on first use (fast, ~41 MB hash = ~30 ms).
4. Detect `noexec` (exec fails with `error.AccessDenied`): print an actionable message
   (`RECLIPZ_CACHE_DIR` must be on an exec-capable mount) and exit non-zero.
5. If the cache is unusable but the payload is only needed for `serve`, we still start the server and
   fail lazily per job with a clear error (so the UI shows a useful message instead of the process
   refusing to boot).

### 3.3 Cache resolution / overrides

```
RECLIPZ_ENGINE=embedded|system|auto     # auto: system yt-dlp if found on PATH, else embedded
RECLIPZ_YTDLP=/path/to/yt-dlp           # explicit binary (dev / unusual platforms)
RECLIPZ_FFMPEG=/path/to/ffmpeg          # explicit ffmpeg (also `system`)
RECLIPZ_FFMPEG=system                   # use the host's ffmpeg (0 MB payload via -Dffmpeg=none)
```

`RECLIPZ_ENGINE=system` keeps the "I already have yt-dlp" audience working with a 1 MB binary.

### 3.4 Update channel (`reclipz update`)

reclip's superpower was `pip install -U yt-dlp` at startup. v2 must keep it without pip:

1. `GET https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest` (or `/releases/tags/<pin>`).
2. Download `<asset>` + `SHA2-256SUMS` from the same release; verify the asset's SHA-256.
3. Optional: verify `SHA2-256SUMS.sig` with `gpg` if it is installed **and** `--gpg` is passed
   (yt-dlp's public key is shipped in their repo; do not bake a key you cannot rotate).
4. Extract into a new versioned cache dir; keep the last N=2; never modify a running payload.
5. `RECLIPZ_NO_UPDATE=1` disables auto-check (mirrors upstream's `RECLIP_NO_UPDATE`).
   Default: `serve` only *checks* (cheap, once/day, ETag-cached) and logs; it never auto-installs
   unless `RECLIPZ_AUTO_UPDATE=1`. Executing newly downloaded binaries is opt-in.

Threat model stated in docs: v1 trusts HTTPS + the checksum file from the same origin; GPG is
supported but not mandatory; `--allow-unverified` is required for hash-less sources (e.g. dev builds).

---

## 4. Command surface (`src/cli.zig`)

| Command | Behaviour |
| --- | --- |
| `reclipz [serve] [--port N] [--host H]` | start the web app (default command) |
| `reclipz yt-dlp <args…>` | resolve payload, then **exec** with args (on POSIX `execv` → signals/exit code/stdout are exactly yt-dlp's) |
| `reclipz ffmpeg <args…>` / `reclipz ffprobe <args…>` | same |
| `reclipz update [--check] [--version TAG] [--force] [--gpg] [--allow-unverified]` | update channel (§3.4) |
| `reclipz install-service [--dry-run] [--force] [--no-enable] [--linger]` | user-space systemd unit (§4.1) |
| `reclipz uninstall-service` / `reclipz service-status` | unit removal / `systemctl --user status` |
| `reclipz which [--json]` | resolved paths + versions + cache dir + target |
| `reclipz selftest` | exec `yt-dlp --version`, `ffmpeg -version`, write a 1-frame mux test, DNS+TLS to github, report table |
| `reclipz version` | reclipz version + embedded payload versions + ffmpeg configure line |

`reclipz yt-dlp …` must set the child environment:

- prepend the payload dir to `PATH` (so yt-dlp finds our ffmpeg even when invoked directly),
- `RECLIPZ_*` passthrough, `PYTHON*` untouched,
- `TMPDIR=<cache>/tmp` (observability + avoids `noexec`/small `/tmp`),
- `--ffmpeg-location <payload dir>` is added for **our own** engine calls but *not* injected into a
  user's `reclipz yt-dlp` invocation (respect their args; only `PATH` is adjusted).

---

## 5. API contract (unchanged, frozen)

Identical to upstream `app.py`. Frontend is served byte-identically from `@embedFile`.

| Method | Path | Request | Response |
| --- | --- | --- | --- |
| GET | `/` | – | `index.html` (21419 B, identical) |
| GET | `/static/favicon.svg` | – | SVG |
| POST | `/api/info` | `{"url"}` | `{"title","thumbnail","duration","uploader","formats":[{"id","label","height"}]}` |
| POST | `/api/playlist` | `{"url"}` | `{"urls":[…]}` |
| POST | `/api/download` | `{"url","format","format_id","title"}` | `{"job_id"}` |
| GET | `/api/status/<id>` | – | `{"status":"downloading"\|"done"\|"error","error","filename"}` |
| GET | `/api/file/<id>` | – | attachment |

### 5.1 Engine mapping (must match upstream exactly)

```text
info      : yt-dlp --no-playlist -j <url>
playlist  : yt-dlp --flat-playlist -J <url>
video     : yt-dlp --no-playlist -o <job>.%(ext)s
                   -f "<format_id>+bestaudio/best" --merge-output-format mp4 <url>
audio     : yt-dlp --no-playlist -o <job>.%(ext)s -x --audio-format mp3 <url>
```

Additions (all behaviour-preserving, verified):

```text
--ffmpeg-location <payload-dir>     # we embed ffmpeg; don't rely on the host PATH (verified working)
--no-colors --no-progress           # for -j/-J so stdout is pure JSON
--newline --progress-template …     # downloads only, to feed the optional progress superset
--cache-dir <cache>/yt-dlp
--proxy / --cookies                 # when configured
--socket-timeout 20 --retries 3     # stability (upstream relies on yt-dlp defaults)
```

### 5.2 Compatibility details that must not regress

1. **Error strings are matched client-side.** Upstream shows the *last stderr line*; keep that exact
   behaviour (verified sample: `ERROR: [generic] x: Unable to download webpage: HTTP Error 404: Not
   Found …`, which matches the UI's `HTTP Error 404` mapping). Never wrap or translate.
2. `formats`: from `-j` JSON, keep only `vcodec != "none"` with a `height`, dedupe to best `tbr` per
   height, sort desc, label `"<height>p"` — port upstream's 12-line loop verbatim.
3. `format_id` is interpolated by the UI into `<id>+bestaudio/best`; never validate it beyond
   rejecting whitespace/leading `-` (argument injection).
4. `job_id` = 10 hex chars (upstream `uuid4().hex[:10]`), validated before any path use.
5. Video → `.mp4`, audio → `.mp3`.
6. Filename = title minus `\/:*?"<>|`, trimmed to 100 chars; same algorithm.
7. `duration` may be `null`; `/api/info` must still return a thumbnail for audio mode.
8. Status codes: 400 for info/playlist errors, 404 for unknown job / not-ready file.

Safe superset: `progress` in `/api/status`, `extractor`/`is_live`/`filesize_approx` in `/api/info`.

---

## 6. Process layer (`src/proc.zig`)

- Spawn with an explicit `argv` (never a shell string), `stdin=ignore`, `stdout/stderr=piped`,
  own process group (`pgid = 0`) so a timeout kills yt-dlp **and** the ffmpeg children it spawns.
- Line reader with per-line and total cap (1 MB line / 8 MB stderr) so a hostile error cannot OOM us.
- Wall-clock timeout (default 300 s per job, upstream's limit) → `SIGTERM` to the group, 2 s grace,
  then `SIGKILL`; job becomes `error: "Download timed out (5 min limit)"` (string matches upstream).
- Exit-code → error mapping: last non-empty stderr line, else `"Download failed (exit code N)"`.
- Cancellation: jobs hold a cancel flag + child handle; `SIGINT`/`SIGTERM` on the server cancels all.
- Concurrency: default **3** jobs (`RECLIPZ_MAX_CONCURRENT`), because each yt-dlp invocation
  re-extracts ~41 MB to `TMPDIR`; a global `exec` semaphore prevents thrash. Measured per-invocation
  overhead: 0.83 s warm (PyInstaller), 0.26 s for a `--onedir` payload (§9.2).

---

## 7. Server & jobs

Unchanged from v1 (it was always independent of the engine):

- `std.http.Server`, thread-per-connection (bounded 32), keep-alive, 15 s header timeout.
- Job registry behind a mutex; states `queued → downloading → postprocessing → done | error`;
  the API collapses the first three into `downloading` so the UI is unchanged.
- Per-job temp dir `<download-dir>/.tmp/<job_id>/`, `-o <job_id>.%(ext)s` inside it; pick the final
  file (prefer `.mp4`/`.mp3`, else the only file), delete intermediates, atomically `rename()` into
  `<download-dir>/<job_id>.<ext>`. `/api/file` can therefore never serve a partial file.
- TTL sweeper (`RECLIPZ_JOB_TTL`, default 24 h; `0` = keep forever = upstream behaviour).
- `/api/file`: streaming, `Content-Length`, `Accept-Ranges`, RFC 5987 `filename*` + ASCII fallback.
- Graceful shutdown: stop accepting, cancel jobs, kill process groups, remove partials.

---

## 8. Configuration

| Name | Default | Notes |
| --- | --- | --- |
| `PORT` / `HOST` | `8899` / `127.0.0.1` | upstream parity |
| `RECLIP_NO_UPDATE` | – | accepted as an alias of `RECLIPZ_NO_UPDATE` |
| `RECLIPZ_DOWNLOAD_DIR` | `./downloads` | |
| `RECLIPZ_CACHE_DIR` | `$XDG_CACHE_HOME/reclipz` | must be exec-capable |
| `RECLIPZ_MAX_CONCURRENT` | `3` | |
| `RECLIPZ_JOB_TIMEOUT` | `300` | seconds |
| `RECLIPZ_JOB_TTL` | `24h` | `0` disables |
| `RECLIPZ_ENGINE` | `embedded` | `system` / `auto` |
| `RECLIPZ_YTDLP` / `RECLIPZ_FFMPEG` | – | explicit binaries |
| `RECLIPZ_COOKIES` | – | Netscape `cookies.txt` |
| `RECLIPZ_PROXY` | – | passed to yt-dlp |
| `RECLIPZ_YTDLP_ARGS` | – | extra args appended (power users) |
| `RECLIPZ_NO_UPDATE` | – | disable update check |
| `RECLIPZ_AUTO_UPDATE` | `0` | opt-in: install updates automatically |
| `RECLIPZ_LOG` | `info` | `error|warn|info|debug|trace` |

---

## 9. Build, packaging, size budget

### 9.1 Build

- `build/payload.zig`: a build step that (a) downloads the release asset for the target, (b) verifies
  it against `SHA2-256SUMS`, (c) writes `third_party/engine.lock` with `{tag, asset, sha256, size}`,
  (d) emits the file for `@embedFile` plus a generated `payload_manifest.zig`.
  `-Dytdlp=official|lean|none` selects the payload flavour (§9.2).
- ffmpeg/ffprobe: `tools/make_ffmpeg.sh` (the measured minimal LGPL configure; see
  `docs/experiments/README.md` §3) with the same download+verify discipline (`-Dffmpeg=minimal|full|none`).
- `zig build -Doptimize=ReleaseSmall` → single static binary. No C toolchain needed for the Zig part.
  Payload size dominates; `-fsingle-threaded` etc. are irrelevant.
- Reproducibility: payload hashes pinned in `third_party/engine.lock`; the Zig toolchain version is
  pinned in `build.zig.zon`. The same input files produce the same binary.

### 9.2 Payload flavours

| Flavour | Size (binary) | Per-invocation overhead | Notes |
| --- | --- | --- | --- |
| `official` (default v1) | ~51 MB | 0.83 s | the exact artifact users trust; simplest |
| `lean` (CI-built `--onedir` yt-dlp) | **~15 MB** | **~0.26 s** | built in our CI from the same sdist, extract-once, zstd'd (~12 MB); not the official artifact |
| `none` (system engine) | ~1 MB | 0 | requires `yt-dlp`/`ffmpeg` on PATH |

Measured: `official` 51.2 MB / 0.83 s (`docs/experiments/payload.zig`); PyInstaller `--onedir`
29 MB uncompressed (`.so` stripped) → ~16 MB zstd, startup 0.26 s; `--onefile` built locally from
source = 18.3 MB.

Recommendation: ship `official` for v1 (respects the "use the official binary" requirement), and
add `lean` as an opt-in build for size/speed. Revisit after real-world use.

### 9.3 Target / asset matrix (Linux only for now)

| Target | yt-dlp asset | ffmpeg payload |
| --- | --- | --- |
| `x86_64-linux-gnu` | `yt-dlp_linux` (glibc ≥ 2.14) | `tools/make_ffmpeg.sh` (native) |
| `x86_64-linux-musl` | `yt-dlp_musllinux` | `tools/make_ffmpeg.sh --target x86_64-linux-musl` |
| `aarch64-linux-gnu` | `yt-dlp_linux_aarch64` | `tools/make_ffmpeg.sh --target aarch64-linux-gnu` |
| `aarch64-linux-musl` | `yt-dlp_musllinux_aarch64` | `tools/make_ffmpeg.sh --target aarch64-linux-musl` |

Cross-compiling our minimal FFmpeg with `zig cc` works (validated for `aarch64-linux-musl`): pass
`--enable-cross-compile --arch=… --target-os=linux`, `--disable-asm --disable-x86asm`, and
`--disable-stripping` with `--extra-ldflags=-s` (the host `strip` cannot touch foreign ELFs).
macOS and Windows are explicitly out of scope for now; the payload/asset plumbing is generic, so
adding them later is mostly CI work.

### 9.4 Licences (simpler than v1)

Because yt-dlp and ffmpeg are shipped as **separate executable payloads** (aggregation, not linking),
the LGPL relink obligation of v1 disappears:

- Our Zig code: MIT (like upstream reclip).
- yt-dlp payload: Unlicense.
- ffmpeg/ffprobe payload: LGPL-2.1+ (our build has `--disable-gpl`); ship `THIRD_PARTY_LICENSES`,
  the exact `configure` line, and the source tarball (or written offer).
- `SHA2-256SUMS`/`.sig` used only for verification.
- Docker image = binary + licences; nothing else.

---

## 10. What we gain / what we give up

**Gain:** 1,734 sites on day one; upstream's weekly fixes become a payload swap; identical UI/API;
tiny Zig surface (~3k LOC) that is easy to audit and test; no C/Python/QuickJS build complexity;
`reclipz yt-dlp`/`reclipz ffmpeg` are genuinely useful tools by themselves.

**Give up:** the "we rewrote yt-dlp in Zig" claim; ~45 MB of binary for the engine; ~0.26–0.83 s
extra per engine invocation; a writable, exec-capable cache dir at runtime; and we inherit yt-dlp's
behaviour/bugs (including YouTube PO-token limitations) exactly.

**Mitigations for the costs:**
- Size: `lean` flavour (~15 MB) or `none` (~1 MB).
- Startup: `lean` payload or `--onedir` extraction; cache the `/api/info` result for a few minutes.
- Cache: clear errors, `RECLIPZ_CACHE_DIR` override, and `selftest` that diagnoses noexec/TMPDIR.
- Behaviour: we test the contract, not the extraction; upstream covers extraction.

---

## 11. Milestones (4–6 weeks, one developer)

### M0 — Skeleton & contract (2–3 d)
- `zig build` → static binary; `reclipz serve` serves the byte-identical UI; router + 7 endpoints
  against a **stub engine** (canned JSON + a fake file) so the unmodified UI works end-to-end.
- CLI dispatch (`serve|yt-dlp|ffmpeg|ffprobe|which|version`), config/env parity, logging, shutdown.
- Tests: A1 (byte-identical UI), endpoint contract snapshot, error-string mapping table.

### M1 — Payload + process + real engine (1.5 w)
- `payload.zig`: embed, verify, extract-once (lock, tmp+rename, `.complete`), noexec diagnostics,
  path resolution, `RECLIPZ_*` overrides.
- `proc.zig`: spawn/exec, process group, timeouts, kill, line caps, exit-code mapping.
- `engine.zig`: the 3 argv builders + `--ffmpeg-location`, stdout JSON tolerance (first valid line,
  like upstream), format-list mapping, filename sanitization, temp dir → atomic rename.
- Tests: A4/A5/A6/A7 against a local HTTP server with `yt-dlp`'s generic extractor (MP4 + MP3),
  argv golden tests, corrupt-payload/noexec/first-run-race tests.

### M2 — Concurrency, update channel, polish (1 w)
- Job pool, cancellation, TTL sweeper, progress superset (`--newline --progress-template`).
- `reclipz update` (+ `--check`), checksum verification, versioned cache, `RECLIPZ_NO_UPDATE`.
- `selftest`, `which --json`, better log lines (job id, argv at debug, timings).
- Tests: 10 concurrent jobs, cancel mid-download (no orphan ffmpeg), update swap while serving.

### M3 — Packaging matrix & release (1 w)
- `-Dytdlp=official|lean|none`, `-Dffmpeg=minimal|full|none`; `fetch_payloads` + `make_ffmpeg.sh` in CI.
- Targets: `x86_64-linux-gnu`, `x86_64-linux-musl`; `scratch` Docker image; size budget gate (≤ 55 MB
  official / ≤ 18 MB lean / ≤ 2 MB none).
- Licences, README, migration notes from reclip, reverse-proxy doc.

### M4 — Hardening (0.5–1 w)
- Fuzz argv/JSON/stderr parsing; hostile job_id/filename tests; SSRF is inherent (documented);
  crash-safety (no partial files, no zombie children); Playwright E2E (A8) on all targets.
- Nightly real-network suite: 30 URLs across the advertised sites; a failure usually means
  "upstream released a fix" → the job surfaces `reclipz update`.

**Total: ~4–6 weeks.** Critical path: payload extraction/locking (M1) and process-group/timeout
handling (M1/M2). Nothing here is research-risky — the hard parts were measured already.

---

## 12. Testing

1. **Contract tests** — snapshot all 7 endpoints (status codes + JSON shape), assert the exact
   substrings the UI matches (`Unsupported URL`, `HTTP Error 404`, `Private video`, `timed out`, …)
   using recorded real stderr lines.
2. **argv goldens** — assert the exact command line built for info / playlist / video / audio,
   including `--ffmpeg-location`, `-f`, `--merge-output-format`, `-x`.
3. **Local-server E2E** — `python -m http.server` equivalent (small Zig test server) serving an MP4:
   `/api/info` → `/api/download` (video + audio) → `/api/status` → `/api/file` byte-compare.
   This exercises the real embedded yt-dlp + ffmpeg without touching the internet.
4. **Payload tests** — hash mismatch refusal, partial `.tmp` dir recovery, concurrent first run
   (two processes), `noexec` cache dir, read-only cache, corrupted payload.
5. **Process tests** — timeout kills the whole group (assert no surviving `ffmpeg`), stderr > 8 MB is
   truncated, exit code propagation, cancellation.
6. **UI E2E** — Playwright against the binary with the unmodified upstream `index.html`.
7. **Nightly network suite** — real URLs; failures triaged as "needs `reclipz update`" vs "our bug".

---

## 13. Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| PyInstaller extraction cost (0.83 s/invocation, 41 MB writes) | sluggish info fetches; I/O churn | `lean` onedir payload (0.26 s), info response cache, job concurrency cap, `TMPDIR` on fast disk |
| `noexec`/small/readonly `/tmp` or cache | engine cannot run | `TMPDIR=<cache>/tmp`, `RECLIPZ_CACHE_DIR`, `selftest` diagnostics, actionable error |
| libc mismatch (musl payload on glibc host) | exec fails | per-target payload matrix, `selftest`, docs; verified failure mode |
| Binary size ~51 MB | distribution annoyance | `lean`/`none` flavours; document trade-offs |
| Update channel executes downloaded code | supply chain | explicit `reclipz update`, SHA-256 verification, optional GPG, no auto-install by default |
| 41 MB × N concurrent extractions | disk/IO storms | serialized extraction lock, default concurrency 3 |
| Upstream yt-dlp regression breaks a site | user-visible | pin version; `reclipz update --version <tag>` to roll back; system-engine override |
| Windows/macOS process-group kill semantics | orphaned ffmpeg | job-object (Windows) / `killpg` (POSIX) behind one `proc.killTree` abstraction |

---

## 14. Decisions needed

1. **Payload flavour for v1**: `official` (51 MB, 0.83 s) — as requested — or `lean` (15 MB, 0.26 s,
   CI-built)? Recommendation: ship `official`, keep `lean` as a build flag.
2. **ffmpeg default**: our minimal LGPL build (6 MB, remux + audio only, `reclipz ffmpeg` is a
   *trimmed* ffmpeg) vs a full static GPL build (40–80 MB). Recommendation: minimal, with
   `-Dffmpeg=full|none` and `RECLIPZ_FFMPEG=system`.
3. **Auto-update**: default check-only (recommended) or auto-install like reclip's `pip -U`?
4. **Targets for the first release**: `x86_64-linux-gnu` + `musl` (recommended) or full matrix?
5. **Branding**: keep the UI's `ReClip` text byte-identical, or rebrand (one-line HTML diff)?
6. **Expose advanced engine flags** (`RECLIPZ_YTDLP_ARGS`, cookies file) in v1, or keep the surface
   exactly reclip's?

---

## 15. Relationship to v1 docs

- `docs/RESEARCH.md` remains valid as *analysis*: the API/frontend contract (§1), yt-dlp scale (§2),
  Zig platform audit (§3), ffmpeg embedding numbers (§4), EJS/QuickJS findings (§5), risk register
  (§7). §6 (strategy options) is now decided: **option 6.3/6.4 style "embed the engine"**, extended
  to "embed the official release binaries" (§10 of this document's research addendum).
- The v1 plan's engine sections (native extractors, HLS/DASH, format selector, QuickJS) are
  superseded; they are deliberately not deleted from RESEARCH.md because they document *why*.
