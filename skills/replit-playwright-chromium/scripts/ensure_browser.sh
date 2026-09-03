#!/usr/bin/env bash
# ensure_browser.sh — idempotent, ON-DEMAND launcher for the headless Chromium
# daemon on Replit (the Playwright-managed store browser). Serves the
# replit-playwright-chromium skill; ship it alongside SKILL.md so the skill is
# self-contained.
#
# Usage: run it ONCE when you need the browser. It is a no-op when the CDP port
# is already live (safe to run right before any automation). Do NOT schedule it
# on a recurring cron — launch on demand and kill the daemon when the task
# finishes.
#
# Multiple agents: Chromium locks --user-data-dir (SingletonLock), so two
# instances can NEVER share one profile dir. Give each agent its own port +
# data dir, e.g.:
#   CHROME_PORT=9223 CHROME_DATA_DIR="$XDG_DATA_HOME/chromium/agent-b" \
#       bash ensure_browser.sh
set -euo pipefail

# Defaults; override with env.
PORT="${CHROME_PORT:-9222}"
DATA_DIR="${CHROME_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/chromium/default}"
LOG="${CHROME_LOG:-$DATA_DIR/chrome-boot.log}"

# If the CDP port already answers, nothing to do.
if curl -s --max-time 2 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
    echo "chrome already up on :${PORT}"
    exit 0
fi

# The Replit store browser — this skill targets ONLY it. No PATH fallback:
# finding some other chromium means this is a different environment, where
# this skill doesn't apply.
CHROME="${REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}"
if [ -z "$CHROME" ] || [ ! -x "$CHROME" ]; then
    echo "error: REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE not set or not executable." >&2
    echo "       This skill drives the Replit store Chromium only — it does not" >&2
    echo "       fall back to other browsers." >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
setsid "$CHROME" \
    --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --remote-debugging-port="${PORT}" \
    --user-data-dir="$DATA_DIR" about:blank \
    >>"$LOG" 2>&1 &
# Give it a moment to bind the debug port.
for _ in 1 2 3 4 5; do
    sleep 1
    if curl -s --max-time 1 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
        echo "chrome launched on :${PORT} (pid $!); profile: $DATA_DIR"
        exit 0
    fi
done
echo "error: chrome failed to bind :${PORT}; see $LOG" >&2
exit 1
