# reclipz — Research Findings

Status: research phase, all numbers below were measured on this machine (Zig 0.17.0, Linux x86_64,
10 cores) unless marked otherwise. Raw experiments live in `docs/experiments/`.

Upstream target: <https://github.com/averygan/reclip> (commit `1d161d1`, single commit repo).

---

## 1. What reclip actually is (measured)

| Item | Value |
| --- | --- |
| `app.py` | 210 lines, Flask, 6 routes |
| `templates/index.html` | 705 lines, 21 KB, vanilla HTML/CSS/JS, no build step |
| `static/` | one file: `favicon.svg` (217 B) |
| Python deps | `flask`, `yt-dlp` (+ gunicorn in Docker) |
| External binaries | `yt-dlp`, `ffmpeg` |
| State | in-memory `jobs` dict, files in `./downloads` |
| UI features | multi-URL paste + dedupe, MP4/MP3 toggle, fetch info+thumbnail+duration+uploader, resolution chips, per-card download, "Download All", polling status, save-to-disk |

### 1.1 The entire backend API (this is the only integration surface)

| Method | Path | Request body | Response |
| --- | --- | --- | --- |
| GET | `/` | – | rendered `index.html` |
| GET | `/static/favicon.svg` | – | SVG |
| POST | `/api/info` | `{"url"}` | `{"title","thumbnail","duration","uploader","formats":[{"id","label","height"}]}` |
| POST | `/api/playlist` | `{"url"}` | `{"urls":[...]}` |
| POST | `/api/download` | `{"url","format":"video"\|"audio","format_id","title"}` | `{"job_id"}` |
| GET | `/api/status/<job_id>` | – | `{"status":"downloading"\|"done"\|"error","error","filename"}` |
| GET | `/api/file/<job_id>` | – | attachment stream |

Errors are `{"error": "<message>"}` with HTTP 400 (info/playlist), 404 (status/file).

**Conclusion: the frontend can be reused byte-for-byte.** It talks plain JSON over 7 endpoints, uses
no framework, no websockets, no progress bar (1 s polling), no template variables (Flask's Jinja is
never used — `index.html` contains zero `{{ }}`). Serving it from `@embedFile` needs no changes at all.

### 1.2 Hidden frontend contracts we must preserve

These are easy to miss and will silently degrade the UI if they change:

1. **Error strings are matched client-side** (`friendlyError()` in `index.html`). Our errors must
   contain these substrings: `Unsupported URL`, `Video unavailable`, `Private video`,
   `HTTP Error 403`, `HTTP Error 404`, `copyright`, `geo`, `timed out`/`Timed out`,
   `network`/`Network`. → Reuse yt-dlp's wording in our error type.
2. `formats` must only contain **video** formats (vcodec != none) that have a `height`, deduped to
   the best `tbr` per height, sorted descending, labelled `"<height>p"`.
3. `/api/playlist` is only called when the URL contains `list=`; it replaces the URL in place.
4. `format_id` from the UI is consumed as the yt-dlp selector `<format_id>+bestaudio/best`
   merged to MP4. So the backend needs a *format selector + merge* implementation, not just a
   "pick one URL".
5. Audio mode is yt-dlp `-x --audio-format mp3` (decode + re-encode, not remux).
6. Final filename is derived from the title with `\/:*?"<>|` stripped, trimmed to 100 chars
   (the UI shows it and uses it as the download name).
7. `job_id` is used as the output file basename → must be restricted to `[a-z0-9]` (path traversal
   hardening; upstream relies on uuid hex).

### 1.3 Exact engine invocations we must behaviourally match

```text
info      : yt-dlp --no-playlist -j <url>
playlist  : yt-dlp --flat-playlist -J <url>
video     : yt-dlp --no-playlist -o <job>.%(ext)s -f <format_id>+bestaudio/best --merge-output-format mp4 <url>
           (or -f bestvideo+bestaudio/best when no format_id)
audio     : yt-dlp --no-playlist -o <job>.%(ext)s -x --audio-format mp3 <url>
```

---

## 2. The engine problem: yt-dlp is not portable by hand

Measured on a fresh `--depth 1` clone of yt-dlp:

| Metric | Value |
| --- | --- |
| Python LOC (`*.py`, excluding `.git`) | **247,104** |
| Extractor files | **941** |
| Registered extractor classes (`_extractors.py`) | **1,187** |
| Sites listed in `supportedsites.md` | **1,734** |
| `extractor/` LOC | 184,575 |
| `extractor/common.py` (the base class) | 4,185 |
| YouTube extractor (`extractor/youtube/`) | 9,210 |
| Release cadence | several releases/week; extractor fixes weekly |

A faithful Zig rewrite of yt-dlp is a multi-year project with no end state, because the real cost is
not writing extractors, it is *continuously re-fixing 1,700 scraping targets*. Any plan that says
"port yt-dlp" must answer "who re-fixes Instagram every 3 weeks?".

### 2.1 What extractors actually use (so we can scope a compat layer)

Frequency of the top `InfoExtractor` helpers across all 941 extractor files:

| Uses | Helper |
| --- | --- |
| 1151 | `_download_json` |
| 1084 | `_match_id` |
| 987 | `_download_webpage` |
| 917 | `_search_regex` |
| 459 | `_match_valid_url` |
| 365 | `_call_api` |
| 362 | `_html_search_regex` |
| 343 | `_extract_m3u8_formats` |
| 301 | `_html_search_meta` |
| 284 | `_parse_json` |
| 226 | `_extract_m3u8_formats_and_subtitles` |
| 178 | `_search_json` |
| 167/123/114 | `_og_search_title` / `_description` / `_thumbnail` |

Python AST usage across extractor files (top nodes): `Constant` 182k, `Call` 39k, `Attribute` 31k,
`Assign` 24k, `Dict` 18k, `FormattedValue` 4.5k, `Lambda` 1.1k, `Yield` 319, `Try` 198, `NamedExpr`
147, `Starred` 142. `traverse_obj` is used in 463 files.

Interpretation: the helper surface is concentrated (≈15 primitives cover the majority), but the
control flow is real Python (f-strings, lambdas, comprehensions, generators, try/except, walrus).
Only **129 of 940** extractor files avoid all of those constructs, so a "Python-subset interpreter in
Zig that runs unmodified `yt_dlp/extractor/*.py`" is a 10–20k LOC project of its own, with an unknown
final coverage rate. It is technically feasible (worth keeping as an option, see §8) but it is a
*separate* project, not the fastest path to a working reclipz.

### 2.2 YouTube specifically (the hard one)

- Current default clients are `('tv_samsung', 'visionos', 'web')`; `visionos` is the "JSLess" client
  (`_DEFAULT_JSLESS_CLIENTS = ('visionos',)`), i.e. some clients no longer need `nsig` solving.
- The JS challenge subsystem (`extractor/youtube/jsc/`) supports external runtimes (deno/bun/quickjs)
  and ships a **self-contained solver script** — see §5. **We can reuse it verbatim.**
- PO tokens (`extractor/youtube/pot/`) are *not* generated by yt-dlp itself; there are only
  memory-cache providers. Real PO tokens come from third-party providers (bgutil etc.) or user
  `po_token=` config. So **PO-token parity is out of scope by definition**, same as upstream default.
- Streaming: YouTube serves DASH (`adaptiveFormats`) with separate audio/video, `signatureCipher`
  for some clients, throttled URLs, and increasingly SABR for some clients. Our path: request the
  player API for a couple of clients (`visionos`, `tv_samsung`, `web`), take `adaptiveFormats`,
  solve `n`/`sig` via the EJS solver when the URL carries `n=`/`signatureCipher`, download both
  streams with `&range=` in parallel, remux to MP4.

---

## 3. Zig platform audit (0.17.0, what we can and cannot use)

| Capability | Zig std 0.17 | Verdict |
| --- | --- | --- |
| HTTP/1.1 client + TLS + gzip/deflate/zstd | `std.http.Client` | ✅ works (proved, §3.1) |
| Connection pooling | `std.http.Client.ConnectionPool` | ✅ |
| HTTP(S) proxy from env | `initDefaultProxies` | ✅ (HTTP proxy; no SOCKS) |
| Cookie jar | – | ❌ must implement |
| Brotli | – | ❌ not needed if we never advertise it (servers fall back to gzip) |
| HTTP/2 | – | ❌ HTTP/1.1 is fine for these origins/CDNs |
| Request timeouts / cancellation | `Io.operateTimeout`, `io.async`+`cancel` | ⚠️ hand-rolled wrapper needed |
| Happy-eyeballs / address fallback | – | ❌ **must** implement, see §3.2 |
| HTTP server | `std.http.Server` (`respond`, `respondStreaming`) | ✅ works (proved, §3.3) |
| HTTPS server (TLS accept) | **client only** (`std/crypto/tls/Client.zig`) | ❌ needs C TLS lib or reverse proxy |
| JSON | `std.json` (Scanner + `dynamic`) | ✅ |
| Regex | – | ❌ use PCRE2 (headers present) or hand-rolled subset |
| XML (DASH MPD) | – | ❌ small hand-rolled parser or lexbor |
| HTML (og tags, JSON-LD, `<video>`) | – | ⚠️ index-based scanning is enough for v1; lexbor if needed |
| AES-128-CBC (HLS keys) | `std.crypto.core.aes` + manual CBC | ✅ |
| SHA-256 / HMAC / base64 | std | ✅ |
| Threads / thread pool | `std.Io.Threaded` (`async`, `concurrent`) | ✅ |
| Static binary | `-target x86_64-linux-musl` | ✅ |

### 3.1 HTTPS fetch works

`docs/experiments/fetch.zig` (43 s cold build, 1.6 MB exe) results:

```
https://example.com            -> 200,    577 B
https://www.tiktok.com/        -> 200, 451,945 B
https://api.github.com/...     -> 200,   6,119 B
https://www.google.com/...     -> HANG
https://www.youtube.com/...    -> HANG
```

### 3.2 Found a real bug-class we must design around: address fallback

The Google/YouTube hang is **not** a Zig TLS/HTTP problem. This machine has a default IPv6 route
that blackholes traffic (`curl -6 https://www.google.com` also times out, `curl` (v4) succeeds).
Google/YouTube hosts return AAAA records first, and `std.http.Client` connects to the first address
without a timeout, so it hangs forever. TikTok/GitHub resolve A-first and work.

→ Requirement: our HTTP client must implement per-address connect timeouts + fallback
(RFC 8305 happy eyeballs, or at least "try each address in 3 s, v4 preferred after 250 ms"), and an
overall request deadline. Validate with a unit test that resolves a dual-stack name to a dead v6
address first. This also protects against CDN flakiness in production and is a strict improvement
over upstream (yt-dlp relies on Python/requests' own retry logic).

### 3.3 HTTP server + untouched frontend works

`docs/experiments/srvtest.zig` serves the unmodified `/tmp/reclip/templates/index.html` via
`@embedFile` and answers `/api/ping`:

```
GET / -> 200, 21419 bytes (identical file)
{"ok":true}
```

Sizes: `ReleaseSafe` 4.13 MB → **657 KB stripped**, with the 21 KB UI embedded.
That is the baseline footprint of the whole web layer.

### 3.4 Version pinning

Zig 0.17 contains the new `std.Io` rework (`main(init: std.process.Init)`, `std.http.Client` needs an
`Io`). The API changed substantially from 0.13/0.14 (this was confirmed while writing the
experiments: `main` signature, `Writer.Allocating.init`, `IpAddress.resolve`, `Stream.writer`
all differ). **Pin the toolchain with `build.zig.zon` `.minimum_zig_version` and vendor nothing that
depends on a range of Zig versions.** Don't chase Zig master during the project; upgrade
deliberately once per milestone.

---

## 4. ffmpeg embedding audit (measured)

Question: can we link ffmpeg into the single binary, and at what cost?

Built FFmpeg 7.1 with a deliberately minimal configuration
(`--disable-everything --disable-programs --disable-network --disable-x86asm --enable-small`,
demuxers mov/matroska/mpegts/flv/mp3/aac/ogg/wav, muxers mp4/ipod/mp3/matroska, decoders
aac/mp3/opus/vorbis/flac/ac3/eac3/alac/pcm, swresample). Static libs: 23.7 MB total
(`libavcodec.a` 10.7 MB, `libavformat.a` 9.2 MB, `libavutil.a` 3.5 MB, `libswresample.a` 0.5 MB).
LAME 3.100 static: `libmp3lame.a` 599 KB.

Linked with `zig cc -O2 -static -Wl,--gc-sections`:

| Binary | Unstripped | Stripped |
| --- | --- | --- |
| MP4 remux only (`docs/experiments/remux.c`) | 11.1 MB | **3.05 MB** |
| m4a → mp3 decode+encode (`docs/experiments/tomp3.c`) | — | **3.47 MB** |

Both were executed successfully (remux H.264+AAC MP4 → MP4 verified with ffprobe; 3 s AAC → 192 kbps
MP3 verified). Because `--gc-sections` only pulls reachable objects, the union of both paths is
~3.5–4 MB, **not** the sum.

Conclusion: embed ffmpeg. It is 3–4 MB, gives production-grade muxing, container/codec edge cases,
faststart, and MP3 encoding, and removes any runtime dependency. A hand-written MP4 muxer + AAC/Opus
decoder + MP3 encoder in Zig would be several thousand lines and would still lose on edge cases.

### 4.1 Licensing (must be handled in the release, not ignored)

- FFmpeg built **without** `--enable-gpl` (our config) is **LGPL-2.1-or-later**.
- LAME is **LGPL-2.0-or-later**.
- LGPL + static linking into one binary is allowed *if* we also distribute what is needed to relink
  (object files / static libs / source) and state the licence. Concretely: ship `THIRD_PARTY_LICENSES`,
  the exact ffmpeg/LAME `configure` lines, and per-release source + `.a` archives (or a written offer).
- Never enable `--enable-gpl`, `libx264`, `libx265`, or `--enable-nonfree`: that would force GPL or
  make distribution impossible. (We only remux video; we never re-encode video, so we don't need
  encoders at all.)
- QuickJS-ng is MIT; the EJS solver is Unlicense with ISC/MIT bundled deps (meriyah/astring);
  reclip is MIT. Final binary: MIT + LGPL components.

---

## 5. QuickJS + the reusable YouTube JS solver (the important unlock)

yt-dlp's YouTube `n`/`sig` challenge solving is isolated in **`yt-dlp/ejs`**, published as
`yt-dlp-ejs` (PyPI, 0.8.0, wheel 53 KB). It contains:

| File | Size | Licence |
| --- | --- | --- |
| `yt/solver/lib.min.js` | 151,561 B | Unlicense (bundles meriyah 6.1.4 ISC + astring 1.9.0 MIT) |
| `yt/solver/core.min.js` | 6,945 B | Unlicense |

Protocol (from `extractor/youtube/jsc/_builtin/ejs.py`): evaluate `lib.min.js`, then
`Object.assign(globalThis, lib)`, then `core.min.js`, then
`console.log(JSON.stringify(jsc({type:'player', player: <base.js>, requests:[{type:'n'|'sig', challenges:[...]}], output_preprocessed:true})))`.
Response: `{type:'result', responses:[{type:'result',data:{challenge: solved}}], preprocessed_player}`.
`preprocessed_player` can be cached per player URL (yt-dlp does exactly that) — very useful for us.

Verified on this machine with quickjs-ng 0.18.0 (`docs/experiments/run_solver.js`, generated by
`docs/experiments/gen_solver_harness.py`): the bundled solver loads, parses a player JS source,
emits the preprocessed player and returns the per-challenge result envelope
(`{"type":"result","responses":[{"type":"error","error":"no solutions: "},...]}` for a synthetic
player with no n/sig function — exactly what is expected). Runtime for the synthetic case: 19 ms.

Sizes: quickjs-ng `qjs` binary 1.42 MB → **1.33 MB stripped**; as a static lib linked into Zig expect
~1 MB and ~158 KB of embedded JS. That is the price for real YouTube support, and it is also the
foundation of a runtime-extractor-pack strategy (§6.2).

---

## 6. Strategy options (with honest cost/coverage)

### 6.1 Native Zig extractors (hand-ported)
- +Full speed, compile-time safety, no sandbox.
- +Simple to debug and test offline (golden fixtures).
- −~150–400 LOC per site; YouTube alone 3–5k LOC.
- −Every site change requires a release.
- Coverage realistically 20–40 sites well.

### 6.2 JS extractor pack on top of the embedded QuickJS
- +Site logic written in JS is 3–10× shorter than Zig, and much closer to yt-dlp's own logic
  (regex/JSON/DOM-ish code). Iteration is minutes.
- +**Hot-updatable**: the extractor pack can be a signed file fetched at runtime, so site breakage
  is fixed without shipping a binary (the strongest answer to "yt-dlp breaks weekly").
- +Zero extra runtime cost: QuickJS is already embedded for §5.
- −Needs a host API (http with cookies/headers, json, regex, crypto, hls/dash helpers) and sandbox
  limits (instruction/timeout/memory). ~2–3 weeks of infra.
- −Slightly slower than native, and JS bugs are runtime bugs.

### 6.3 Embedded CPython + yt-dlp ("parity mode")
- +Instant 100 % feature parity, 1,734 sites, upstream updates by swapping a zipapp.
- +Also solves playlist, subtitles, hundreds of edge cases for free.
- −+30–40 MB binary, ~100 ms cold start, and the "Zig implementation" claim becomes a wrapper.
- −CPython + yt-dlp + deps is a bigger, more fragile embed than ffmpeg (python-build-standalone
  static, or link `libpython` and extract the zipapp to a temp dir/memfd).
- Effort: 1–2 weeks. Good insurance, poor identity.

### 6.4 External `yt-dlp` bridge (opt-in)
- +~1 day of work (spawn process, parse the same JSON), zero size.
- +Perfect escape hatch for "site X isn't supported yet".
- −Requires the user to install yt-dlp; not a single binary by default.

### Recommended combination
**6.1 + 6.2 as the product, 6.4 as an opt-in fallback, 6.3 only if parity becomes a hard
requirement.** Rationale: the embedded QuickJS is already justified by YouTube, so the incremental
cost of an updatable extractor pack is low, and it is the only approach that scales maintenance to
"1000+ sites" without a permanent porting treadmill.

---

## 7. Risk register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Sites break faster than we fix them | product dies | JS extractor pack + signed runtime updates; opt-in yt-dlp bridge; honest supported-site list in UI/docs |
| YouTube anti-bot (PO tokens, SABR) | core feature degraded | support `po_token` config like yt-dlp; multiple clients; document limitation; fallback bridge |
| Zig 0.17 API churn | wasted work | pin toolchain, upgrade once per milestone |
| IPv6 blackhole / CDN flakiness | hangs | happy-eyeballs + per-request deadline + retries (already specified) |
| Bot walls need cookies (IG/FB/X) | those sites unreliable | Netscape cookies.txt support + cookie jar; document |
| Legal (YouTube ToS, LGPL relinking) | takedown / compliance | disclaimer parity with reclip; THIRD_PARTY_LICENSES + relink artifacts |
| Binary size creep | "single binary" becomes 60 MB | size budget in CI (target ≤ 12 MB), `--gc-sections`, no GPL codecs |
| Regex/HTML parsing bugs | wrong formats | PCRE2 (battle-tested) instead of custom regex; golden fixtures from yt-dlp |
| No HTTPS server in std | can't serve TLS | document reverse-proxy deployment (parity with reclip, which is plain HTTP too) |

---

## 8. Open questions (need a decision before coding)

1. **Engine scope** — accept "top ~20 sites + generic + updatable JS pack" (recommended), or demand
   full parity via embedded CPython (§6.3)?
2. **Opt-in external yt-dlp bridge** — include it? (1 day, big safety net; slightly dilutes the
   "single binary" story.)
3. **YouTube acceptance criteria** — is "works for public videos from a normal residential IP,
   PO-token-limited cases documented" enough for v1?
4. **Updatable extractor pack** — is runtime downloading a signed JS pack acceptable (needs a
   hosting URL), or must everything be compiled in (then accept release-bound fixes)?
5. **Platforms** — Linux x86_64 only for v1, or Linux+macOS+Windows release matrix from day one
   (affects ffmpeg cross-compilation/CI work ~1 week)?
6. **Cookies/auth** — do we need logged-in support (Instagram/Facebook/X) in v1, or Phase 2?

---

## 9. Experiment index

| Path | What it proves |
| --- | --- |
| `docs/experiments/fetch.zig` | `std.http.Client` + TLS works; the IPv6-first hang reproduces |
| `docs/experiments/srvtest.zig` | `std.http.Server` serves the **unmodified** reclip UI; 657 KB stripped |
| `docs/experiments/remux.c` | minimal FFmpeg build remuxes MP4 in a 3.05 MB static binary |
| `docs/experiments/tomp3.c` | same libs decode AAC + encode MP3 via LAME, 3.47 MB stripped |
| `docs/experiments/gen_solver_harness.py` | builds the EJS harness exactly like yt-dlp does |
| `docs/experiments/run_solver.js` | yt-dlp's Unlicense JS solver runs under quickjs-ng 0.18 |

Build commands are recorded in `docs/experiments/README.md`.

---

## 10. Addendum (v2): "compile Python into a binary" — embedding the official engine

Prompted by the observation that yt-dlp itself publishes platform-specific standalone binaries.
All numbers below were measured on Linux x86_64.

### 10.1 What yt-dlp actually ships

`yt-dlp/yt-dlp` latest release (tag `2026.10.26`) assets:

| Asset | Size |
| --- | --- |
| `yt-dlp` (zipapp) | 3.1 MB |
| `yt-dlp_linux` (glibc x86_64) | **41.2 MB** |
| `yt-dlp_linux_aarch64` / `_armv7l` | 40.8 / 39.4 MB |
| `yt-dlp_musllinux` / `_aarch64` | 41.2 / 40.5 MB |
| `yt-dlp_macos` | 37.5 MB |
| `yt-dlp.exe` / `yt-dlp_arm64.exe` / `yt-dlp_x86.exe` | 23.6 / 22.8 / 18.6 MB |
| `SHA2-256SUMS`, `SHA2-512SUMS` (+ `.sig`) | checksums for verification |

These are PyInstaller **onefile** builds: a bootloader with a zlib-compressed archive that is
extracted to `$TMPDIR/_MEIxxxxxx` **on every invocation**.

### 10.2 Measured behaviour of the official binaries

| Check | Result |
| --- | --- |
| `yt-dlp_linux --version` | works: `2026.10.26`, **0.87 s** (extract 41 MB each run) |
| `yt-dlp_linux` interpreter | `/lib64/ld-linux-x86-64.so.2`; needs `libz`, `libdl`, `libpthread` |
| `yt-dlp_linux` glibc baseline | **GLIBC_2.14** (very portable) |
| `yt-dlp_musllinux --version` | **fails on glibc host**: `cannot execute: required file not found` |
| `yt-dlp_musllinux` interpreter | `/lib/ld-musl-x86_64.so.1`; needs `libc.musl-x86_64.so.1`, `libz.so.1` |
| `zstd -19` on `yt-dlp_linux` | 41.2 MB → **40.6 MB** (1.4 % — already zlib-compressed, do not bother) |
| `yt-dlp_linux -j <local file URL>` | real yt-dlp JSON, 1.40 s |
| `-x --audio-format mp3 --ffmpeg-location <dir>` | **works** with a minimal custom ffmpeg (see 10.4), 1.48 s |
| error text on 404 page | `ERROR: [generic] …: Unable to download webpage: HTTP Error 404: Not Found …` → matches the UI's `friendlyError` substrings |
| `TMPDIR=/nonexistent` | still works (PyInstaller falls back) |

→ Embedding the official binary is viable, but the payload must match the **libc** of the target
(glibc vs musl are not interchangeable), and every invocation costs ~0.9 s + 41 MB of temp writes.

### 10.3 If we instead build the Python payload ourselves

| Approach | Size (measured) | Startup | Notes |
| --- | --- | --- | --- |
| PyInstaller `--onefile` from yt-dlp source (no optional deps) | **18.3 MB** | 0.395 s | self-extracts each run; built in ~17 s |
| PyInstaller `--onedir` (strip `libpython3.12.so`) | **29 MB** | 0.263 s | extract-once semantics (dir), zstd ≈ 16 MB |
| official `yt-dlp_linux` | 41.2 MB | 0.87 s | bundles optional deps (requests, brotli, certifi, …) |
| embed CPython + `yt-dlp` zipapp | `libpython3.12.a` = **65 MB** unstripped | ~0.05 s | needs a custom `Modules/Setup.stdlib` (all modules static), `--export-dynamic`, stdlib zip via memfd; python-build-standalone only ships **shared** `libpython3.12.so`, so this means building CPython yourself |

Notes on "true" compilation: PyInstaller/Nuitka/PyOxidizer all still embed CPython — there is no
reliable AOT compiler for arbitrary Python (GraalPy `native-image` and RustPython exist, but yt-dlp's
`re`/stdlib behaviour and optional C extensions make them a compatibility gamble). yt-dlp is pure
Python (every third-party dep is optional — verified in `yt_dlp/dependencies/__init__.py`), so these
are not insane, just unnecessary.

Also measured: `yt_dlp/aes.py` fallbacks mean no pycryptodomex is required; a minimal PyInstaller
build (18.3 MB) already works standalone.

### 10.4 Minimal ffmpeg payload (what yt-dlp needs)

yt-dlp shells out to `ffmpeg`/`ffprobe` for `--merge-output-format` and `-x --audio-format`.
A static LGPL build with only the needed demuxers/muxers/decoders/filters (measured earlier in §4)
plus the CLI frontends:

| Binary | Size |
| --- | --- |
| `ffmpeg` (remux + AAC/Opus/Vorbis/MP3 decode + libmp3lame encode + filters) | **3.07 MB** |
| `ffprobe` | **2.95 MB** |
| `zstd -19` on `ffmpeg` | 3.07 MB → **1.25 MB** |

Verified: `-c copy` MP4 remux and `-c:a libmp3lame -q:a 5` MP3 encode both work, and yt-dlp drives
them correctly via `--ffmpeg-location <dir>`.

### 10.5 End-to-end proof (v2 architecture)

`docs/experiments/payload.zig` embeds `yt-dlp_linux` + `ffmpeg` + `ffprobe`, extracts them once into
`$XDG_CACHE_HOME/reclipz-demo/<version>/` (atomic tmp+rename, chmod 0755), and spawns yt-dlp with the
user's argv:

| Metric | Value |
| --- | --- |
| Single binary size | **51.2 MB** (Zig + 46 MB payloads) |
| `--version` cold / warm | 0.874 s / 0.830 s |
| Cache after first run | yt-dlp 40 MB, ffmpeg 3.0 MB, ffprobe 2.9 MB |
| `-x --audio-format mp3` on a local URL | MP3 produced (13,280 B, verified with ffprobe) |
| `-j` on a local URL | valid yt-dlp JSON (formats/title/etc.) |

This is the entire v2 thesis in one file: the Zig part is a ~3k LOC host (server, API, jobs, payload,
process, CLI); the engine is upstream yt-dlp, always current, no recompilation.
