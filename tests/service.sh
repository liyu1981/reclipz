#!/usr/bin/env bash
# Verify `reclipz install-service` against a real user systemd instance.
# Skips (exit 0) when no user systemd session is available (containers/CI).
#
#   zig build -Doptimize=ReleaseSafe
#   tests/service.sh
set -uo pipefail

cd "$(dirname "$0")/.."
BIN="${BIN:-./zig-out/bin/reclipz}"
PORT=8921

if ! systemctl --user is-system-running >/dev/null 2>&1; then
  echo "== skipping: no user systemd session"
  exit 0
fi

WORK="$(mktemp -d)"
cleanup() {
  "$BIN" uninstall-service >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }

echo "== reclipz install-service"
"$BIN" install-service --port "$PORT" --download-dir "$WORK/dl" --cache-dir "$WORK/cache" --force >"$WORK/install.log" 2>&1 \
  || { cat "$WORK/install.log"; fail "install-service"; }
pass "unit installed"

unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/reclipz.service"
[[ -s "$unit" ]] || fail "unit file missing or empty: $unit"
pass "unit file non-empty ($(stat -c%s "$unit") bytes)"

[[ "$(systemctl --user is-active reclipz.service)" == "active" ]] || {
  journalctl --user -u reclipz.service --no-pager -n 10
  fail "service is not active"
}
pass "service active"

for _ in $(seq 1 40); do
  curl -sf -o "$WORK/index.html" "http://127.0.0.1:$PORT/" && break
  sleep 0.25
done
cmp -s "$WORK/index.html" src/assets/index.html || fail "UI served by the service differs"
pass "UI served by the service is byte-identical"

"$BIN" uninstall-service >/dev/null 2>&1 || true
if systemctl --user is-active reclipz.service >/dev/null 2>&1; then fail "service still active after uninstall"; fi
[[ -f "$unit" ]] && fail "unit file left behind"
pass "uninstall stopped and removed the unit"

echo "== all service checks passed"
