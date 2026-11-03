#!/usr/bin/env python3
"""Reproduce yt-dlp's EJS solver harness (see yt_dlp/extractor/youtube/jsc/_builtin/ejs.py).

Downloads the yt-dlp-ejs wheel, extracts lib.min.js/core.min.js, and emits a standalone
script for quickjs that solves a single player's `n`/`sig` challenges.

Usage:
    python3 gen_solver_harness.py base.js out.js            # real player
    python3 gen_solver_harness.py --fake out.js             # synthetic player (smoke test)

Then:
    qjs --script out.js
"""
import io
import json
import socket
import sys
import urllib.request
import zipfile

# This box has a default IPv6 route that blackholes traffic and glibc's resolver
# returns AAAA first, so urllib hangs on connect (see RESEARCH.md 3.2).
# Force IPv4 for this probe.
_real_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda *a, **kw: [
    r for r in _real_getaddrinfo(*a, **kw) if r[0] == socket.AF_INET
]

PYPI = "https://pypi.org/pypi/yt-dlp-ejs/json"
VERSION = "0.8.0"  # see yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py

FAKE_PLAYER = """\
var _yt_player = {};
(function (g) {
  g.qs = function (a) { return a.split('').reverse().join(''); };
})(_yt_player);
"""


def fetch_js():
    with urllib.request.urlopen(PYPI, timeout=30) as r:
        meta = json.load(r)
    url = next(u["url"] for u in meta["urls"] if u["filename"].endswith(".whl"))
    with urllib.request.urlopen(url, timeout=60) as r:
        whl = zipfile.ZipFile(io.BytesIO(r.read()))
    lib = whl.read("yt_dlp_ejs/yt/solver/lib.min.js").decode()
    core = whl.read("yt_dlp_ejs/yt/solver/core.min.js").decode()
    return lib, core


def main():
    args = sys.argv[1:]
    fake = "--fake" in args
    args = [a for a in args if a != "--fake"]
    out_path = args[0]
    player = FAKE_PLAYER if fake else open(args[1] if len(args) > 1 else args[0]).read()

    lib, core = fetch_js()
    data = {
        "type": "player",
        "player": player,
        "requests": [
            {"type": "n", "challenges": ["abcd"]},
            {"type": "sig", "challenges": ["abcd"]},
        ],
        "output_preprocessed": True,
    }
    script = (
        lib
        + "\nObject.assign(globalThis, lib);\n"
        + core
        + f"\nconsole.log(JSON.stringify(jsc({json.dumps(data)})));\n"
    )
    with open(out_path, "w") as f:
        f.write(script)
    print(f"wrote {out_path} ({len(script)} bytes)")


if __name__ == "__main__":
    main()
