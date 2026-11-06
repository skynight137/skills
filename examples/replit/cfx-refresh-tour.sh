#!/usr/bin/env bash
# cfx-refresh-tour.sh — sequential camofox keep-alive tour.
#
# Tours a list of FULL LINKS, one tab at a time: open a link, dwell on
# it, close its session group, move to the next. Peak RAM stays at 1-2
# tabs no matter how many links are listed (this replaced the old
# parallel-task setup, whose live IDE tabs — ~600 MB each — exhausted
# an 8 GB box).
#
# Example from examples/replit/ — NOT installed with the skill. Copy it
# into your workspace and adapt USER_ID / COOKIES / LINKS.
#
# To change targets, edit LINKS below: full URLs, any site. The session
# name, log file, and screenshot name derive from the link's last path
# segment (…/@user/HMS -> tour-hms); cookie import happens on the first
# stop only, later stops reuse the persisted jar. Replit stops also get
# the upsell dismiss + login checker (--fail-text); an early non-timeout
# exit (checker / crash) leaves a *** FAILED early *** banner here.
#
# Tunables (env): TOUR_DWELL_S (seconds per link, default 600),
# TOUR_INTERVAL_S (refresh-page interval within a stop, default 180 —
# keep interval + 60 well under the 300s default tab reaper).
# Detail goes to logs/refresh-tour.log (+ logs/tour-<slug>.log per
# stop); the workflow console keeps the startup summary only.
set -uo pipefail
[ -r /run/replit/env/latest ] && . /run/replit/env/latest
cd "${REPL_HOME:-$HOME/workspace}"

USER_ID="your-replit-username"
COOKIES=".config/cookies/repl-${USER_ID}.json"
SHOT_DIR="attached_assets/cfx-refresh-page"
LINKS=(
  "https://replit.com/~"
  "https://replit.com/@your-replit-username/YourProject"
)
DWELL="${TOUR_DWELL_S:-600}"
INTERVAL="${TOUR_INTERVAL_S:-180}"
# Circuit breaker: abort the whole tour after this many CONSECUTIVE
# early-failed stops (0 = never). A stop that serves its full dwell (or
# exits 0) resets the count.
MAX_EARLY="${TOUR_MAX_EARLY_FAILURES:-3}"
# Log colors, setup-script style (house style): severity you can scan
# at a glance. Always on, no opt-out - the eye catches color before
# text, so diagnosis starts from the color. Phrases stay plain inside
# the color span, so grep on the log keeps working.
C_STOP=$'\033[0;36m' C_OK=$'\033[0;32m' C_WARN=$'\033[1;33m' C_ERR=$'\033[1;31m' C_DIM=$'\033[2m' C_RST=$'\033[0m'
PY="$(command -v python3 || ls /nix/store/*-python3-3.1*/bin/python3 2>/dev/null | head -1)"
CLI=".agents/skills/replit/scripts/camofox.py"

slug_for() {
  local s="$1" out
  s="${s%%\?*}"                        # strip query string
  s="${s%/}"                           # strip trailing slash
  s="${s##*/}"                         # last path segment
  [ -n "$s" ] || s="$1"                # bare host link: use the host part
  out="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
  [ -n "$out" ] || out="home"          # last segment sanitized away (e.g. /~)
  printf '%s' "$out"
}

LOG="$PWD/logs/refresh-tour.log"
echo "refresh-tour: ${#LINKS[@]} links, one tab at a time (dwell ${DWELL}s, round ~$(( ${#LINKS[@]} * DWELL / 60 )) min)"
echo "  user=$USER_ID  full log: $LOG"
if [ ! -t 1 ]; then
  mkdir -p logs
  exec >>"$LOG" 2>&1
  echo "=== refresh-tour start $(date -Is) ==="
fi

first=1
early_fails=0
while true; do
  for url in "${LINKS[@]}"; do
    slug="$(slug_for "$url")"
    sess="tour-$slug"
    echo "${C_STOP}[$(date +%H:%M:%S)] stop: $slug ($url) session=$sess dwell=${DWELL}s${C_RST}"
    args=(--user "$USER_ID" --session "$sess" --wait 10 --tools refresh-page
          --interval "$INTERVAL" --url "$url" --screenshot "$SHOT_DIR"
          --log-file "logs/tour-$slug.log")
    # the Replit needles only apply to replit.com links
    case "$url" in *replit.com*) args+=(--dismiss "Keep using Replit?" --fail-text "Log in" --fail-text "Sign up");; esac
    if [ "$first" = 1 ]; then args+=(--cookies "$COOKIES"); first=0; fi
    rc=0
    timeout "$DWELL" "$PY" -u "$CLI" "${args[@]}" || rc=$?
    if [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
      echo "${C_WARN}*** stop FAILED early (rc=$rc): $slug - see logs/tour-$slug.log (content checker / crash) ***${C_RST}"
      early_fails=$((early_fails + 1))
    else
      early_fails=0
    fi
    "$PY" "$CLI" --user "$USER_ID" --session "$sess" --close || true
    echo "${C_DIM}[$(date +%H:%M:%S)] closed: $slug${C_RST}"
    if [ "$MAX_EARLY" != 0 ] && [ "$early_fails" -ge "$MAX_EARLY" ]; then
      echo "${C_ERR}*** tour ABORTED: $early_fails consecutive early failures (TOUR_MAX_EARLY_FAILURES=$MAX_EARLY) - exiting ***${C_RST}"
      exit 1
    fi
  done
  echo "${C_OK}[$(date +%H:%M:%S)] round complete - restarting tour${C_RST}"
done
