#!/usr/bin/env bash
# refresh-page-keepalive.sh — keep ONE page alive on a camofox-browser
# server, with the two guards a bare loop lacks:
#   --dismiss   closes the Replit Starter-limit upsell before screenshots
#   --fail-text exits loudly if the page turns into a logged-out wall
#               (stale cookies) instead of screenshotting it for hours
#
# Example from examples/replit/ — NOT installed with the skill. Copy it
# into your workspace and adapt the CONFIG block.
#
# Requires: the camofox server running (skill: setup.sh --camofox) and
# its env reachable (CAMOFOX_BASE_URL / keys via env or the server .env).
set -uo pipefail
[ -r /run/replit/env/latest ] && . /run/replit/env/latest
cd "${REPL_HOME:-$HOME/workspace}"

# --- CONFIG (adapt) ---------------------------------------------------
URL="https://replit.com/~"                  # page to keep alive
USER_ID="your-replit-username"              # camofox profile / cookie jar
SESSION="keepalive"                         # session group label
COOKIES=".config/cookies/repl-${USER_ID}.json"   # exported cookie jar
INTERVAL="${INTERVAL:-180}"                 # < TAB_INACTIVITY_MS default (300s)
SHOT_DIR="attached_assets/cfx-refresh-page"
# ----------------------------------------------------------------------

PY="$(command -v python3 || ls /nix/store/*-python3-3.1*/bin/python3 2>/dev/null | head -1)"
CLI=".agents/skills/replit/scripts/camofox.py"

# Always close the session group on the way out — a dead client leaves
# its tab on the server eating RAM until the reapers notice.
trap '"$PY" "$CLI" --user "$USER_ID" --session "$SESSION" --close || true' EXIT

"$PY" -u "$CLI" \
  --user "$USER_ID" --session "$SESSION" --wait 10 \
  --tools refresh-page --interval "$INTERVAL" --url "$URL" \
  --cookies "$COOKIES" \
  --screenshot "$SHOT_DIR" --log-file "logs/refresh-${SESSION}.log" \
  --dismiss "Keep using Replit?" \
  --fail-text "Log in" --fail-text "Sign up" \
  --max-failures 3
