#!/usr/bin/env bash
# Toggle the live browser monitor (the "watch what the agent's browser is doing"
# screenshot stream on port 5000). Ships with the replit-playwright-chromium
# skill; self-contained — resolves paths from this file's own directory.
#
# Default is OFF — the agent drives Chrome directly on the CDP port (9222)
# with zero screenshot overhead. Start the monitor ONLY when you want to watch.
#
# Usage:
#   monitor.sh        # status
#   monitor.sh on     # start the monitor on :5000, serve full-screen mirror
#   monitor.sh off    # stop it (agent keeps working unaffected)
#   monitor.sh port N # run on port N instead of 5000 (default)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PORT="${2:-5000}"
SCRIPT="$SCRIPT_DIR/browser_monitor.py"
DATA_DIR="${CHROME_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/chromium/default}"
PIDFILE="${MONITOR_PIDFILE:-$DATA_DIR/monitor.pid}"
PY="${MONITOR_PYTHON:-python3}"

mkdir -p "$DATA_DIR"

require_agent_ok() {
  if ! curl -s --max-time 2 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
    echo "warning: Chrome on :9222 is not running — relaunch it first (ensure_browser.sh)"
  fi
}

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "monitor already running (pid $(cat "$PIDFILE")) on :$PORT"
    return 0
  fi
  require_agent_ok
  nohup "$PY" "$SCRIPT" "$PORT" >"$DATA_DIR/monitor.log" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  if curl -s --max-time 3 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    echo "monitor started on :$PORT — open https://${REPLIT_DOMAINS}:$PORT to watch"
  else
    echo "monitor started on :$PORT but not yet answering (pid $(cat "$PIDFILE"))"
  fi
}

stop() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    echo "monitor stopped"
  else
    echo "monitor not running"
  fi
}

case "${1:-status}" in
  on|start) start ;;
  off|stop) stop ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      pid=$(cat "$PIDFILE")
      echo "monitor: ON (pid $pid) on :$PORT — https://${REPLIT_DOMAINS}:$PORT"
      curl -s --max-time 2 "http://127.0.0.1:$PORT/healthz" && echo " <- healthy"
    else
      echo "monitor: OFF (fast path — agent drives Chrome directly on :9222)"
    fi
    ;;
  *) echo "usage: monitor.sh [on|off|status] [port]";;
esac