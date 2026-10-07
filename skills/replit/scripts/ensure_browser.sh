#!/usr/bin/env bash
# ensure_browser.sh — idempotent, ON-DEMAND launcher for a headless Chromium
# CDP daemon on Replit. Serves references/playwright-chromium.md.
#
# Usage: run it ONCE when you need the browser. It is a no-op when the CDP port
# is already live (safe to run right before any automation). Do NOT schedule it
# on recurring cron — launch on demand and kill the daemon when done.
#
# Multiple agents: Chromium locks --user-data-dir (SingletonLock), so two
# instances can NEVER share one profile dir. Give each agent its own port +
# data dir, e.g.:
#   CHROME_PORT=9223 CHROME_DATA_DIR="$XDG_DATA_HOME/chromium/agent-b" \
#       bash ensure_browser.sh
#
# ── PORTABLE lib mapping (do NOT hardcode /nix/store hashes) ────────────────
# Every Replit machine has DIFFERENT /nix/store hashes for the same packages.
# A path that works on one box is absent on the next. So this script resolves
# the shared libs at RUN time:
#   1. Replit's Playwright Chromium ($REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE)
#      is a self-contained wrapper — it needs NO extra LD_LIBRARY_PATH.
#   2. Other Chromium builds (e.g. Hermes' chrome-linux64) can miss
#      libnspr4/nss/xkbcommon/gbm. We detect that with `ldd` and map each
#      missing soname to its CURRENT store path via `nix eval --raw
#      nixpkgs#<attr>` (the same resolve-by-name approach generate-closure.sh
#      uses). The 32-bit /nix/store copies of nspr/nss are filtered out — a
#      64-bit browser cannot load them ("wrong ELF class: ELFCLASS32").
set -euo pipefail

PORT="${CHROME_PORT:-9222}"
DATA_DIR="${CHROME_DATA_DIR:-${XDG_DATA_HOME:-${REPL_HOME:-$HOME}/.local/share}/chromium/default}"
LOG="${CHROME_LOG:-$DATA_DIR/chrome-boot.log}"

# A 64-bit browser binary: prefer the Replit store wrapper, else an explicit
# CHROME_BIN, else the Hermes bundled Chrome.
CHROME="${CHROME_BIN:-${REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}}"
if [[ -z "$CHROME" || ! -x "$CHROME" ]]; then
    for c in "${HERMES_HOME:-$HOME/.hermes}/tools"/chromium-*/chrome-linux64/chrome; do
        [[ -x "$c" ]] && { CHROME="$c"; break; }
    done
fi
if [[ -z "${CHROME:-}" || ! -x "$CHROME" ]]; then
    echo "error: no Chromium found (set CHROME_BIN or REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE)." >&2
    exit 1
fi

# If the CDP port already answers, nothing to do.
if curl -s --max-time 2 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
    echo "chrome already up on :${PORT}"
    exit 0
fi

# ── portability: resolve missing runtime libs by NAME, never by hash ────────
# /nix/store hashes differ per machine and per nixpkgs revision, so a literal
# path is not portable. The shared resolver (setup/resolve-libs.sh) maps each
# missing soname to its CURRENT store root (the same nixpkgs-attr approach the
# camofox lane uses for its GTK closure) and refuses a 32-bit copy.
if [[ -n "$(ldd "$CHROME" 2>/dev/null | awk '/not found/{print $1}')" ]]; then
    _resolver="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/setup/resolve-libs.sh"
    if [[ -f "$_resolver" ]]; then
        _closure="$(mktemp)"
        if bash "$_resolver" "$_closure" chromium >/dev/null 2>&1 && [[ -s "$_closure" ]]; then
            export LD_LIBRARY_PATH="$(cat "$_closure")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            echo "resolved Chromium runtime libs onto LD_LIBRARY_PATH ($(tr ':' '\n' < "$_closure" | grep -c .) dirs)"
        else
            echo "warning: could not resolve Chromium runtime libs — the browser may fail to start" >&2
        fi
        rm -f "$_closure"
    fi
fi

# The Replit wrapper EXECs the real binary with its own flags; pass ours after.
mkdir -p "$DATA_DIR"
setsid "$CHROME" \
    --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --remote-debugging-port="${PORT}" \
    --user-data-dir="$DATA_DIR" about:blank \
    >>"$LOG" 2>&1 &
for _ in 1 2 3 4 5; do
    sleep 1
    if curl -s --max-time 1 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
        echo "chrome launched on :${PORT} (pid $!); profile: $DATA_DIR"
        echo "  browser: $CHROME"
        exit 0
    fi
done
echo "error: chrome failed to bind :${PORT}; see $LOG" >&2
exit 1