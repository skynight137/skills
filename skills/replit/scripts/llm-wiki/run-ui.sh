#!/usr/bin/env bash
# Serve the llm-wiki desktop UI to a browser: Xvfb (:99) -> x11vnc (loopback) -> noVNC (public).
#
#   bash run-ui.sh            # foreground supervisor (idempotent, restarts what died)
#
# Ports:  VNC 127.0.0.1:5900 (never public) · noVNC 0.0.0.0:8000 (public, VNC password required)
# Open:   https://<host>:8000/vnc.html     (password in $STATE/vnc-password.txt)
#
# Why not expose the app directly: the frontend is Tauri (invoke), so there is no
# web UI to serve; VNC is the only way to see the real desktop window in a browser.
set -uo pipefail
APP="$(cd "$(dirname "$0")" && pwd)"
STATE="${XDG_CONFIG_HOME:-$HOME/.config}/llmwiki-ui"
DISP="${LLM_WIKI_DISPLAY:-:99}"
VNC_PORT="${LLM_WIKI_VNC_PORT:-5900}"
WEB_PORT="${LLM_WIKI_UI_PORT:-8000}"
SLEEP="${LLM_WIKI_UI_SLEEP:-15}"

mkdir -p "$STATE"; chmod 700 "$STATE"
X11VNC="$(ls -d /nix/store/*x11vnc-*/bin/x11vnc 2>/dev/null | head -1)"
NOVNC="$(ls -d /nix/store/*novnc-*/bin/novnc 2>/dev/null | head -1)"

port_open() { (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# --- VNC password (chmod 600; the plaintext copy is what you type in the browser) ---
if [ ! -s "$STATE/vnc-pass" ] || [ ! -s "$STATE/vnc-password.txt" ]; then
  [ -n "$X11VNC" ] || { echo "x11vnc not found in /nix/store — nix build nixpkgs#x11vnc" >&2; exit 1; }
  PW="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-12)"
  env -u LD_LIBRARY_PATH "$X11VNC" -storepasswd "$PW" "$STATE/vnc-pass" >/dev/null 2>&1
  printf '%s\n' "$PW" > "$STATE/vnc-password.txt"
  chmod 600 "$STATE/vnc-pass" "$STATE/vnc-password.txt"
  log "VNC password written to $STATE/vnc-password.txt (chmod 600)"
fi

start_vnc() {
  port_open "$VNC_PORT" && return 0
  [ -n "$X11VNC" ] || return 1
  env -u LD_LIBRARY_PATH "$X11VNC" -display "$DISP" -localhost -rfbport "$VNC_PORT" \
    -rfbauth "$STATE/vnc-pass" -forever -shared -repeat -noxdamage -quiet \
    >"$STATE/x11vnc.log" 2>&1 &
  for _ in $(seq 1 15); do port_open "$VNC_PORT" && { log "x11vnc up (127.0.0.1:$VNC_PORT -> $DISP)"; return 0; }; sleep 1; done
  log "x11vnc FAILED (see $STATE/x11vnc.log)"; return 1
}

# x11vnc needs a live X server. A stale /tmp/.X11-unix socket must not be trusted: require
# a running Xvfb for this display, otherwise the VNC server dies silently and the browser
# shows a black page. run-public.sh starts the same display; whichever supervisor comes
# first wins and the other just finds it there.
ensure_display() {
  [ -S "/tmp/.X11-unix/X${DISP#:}" ] && pgrep -f "Xvfb ${DISP} " >/dev/null && return 0
  local xvfb
  xvfb="$(command -v Xvfb || ls -d /nix/store/*-xorg-server-*/bin/Xvfb 2>/dev/null | head -1)"
  [ -n "$xvfb" ] || { log "no Xvfb found — cannot create display $DISP"; return 1; }
  rm -f "/tmp/.X11-unix/X${DISP#:}" "/tmp/.X${DISP#:}-lock"
  "$xvfb" "$DISP" -screen 0 1600x1000x24 +extension GLX +extension RANDR +render -noreset >/tmp/xvfb.log 2>&1 &
  for _ in $(seq 1 10); do [ -S "/tmp/.X11-unix/X${DISP#:}" ] && { log "Xvfb up on $DISP"; return 0; }; sleep 1; done
  log "Xvfb FAILED (see /tmp/xvfb.log)"; return 1
}

start_novnc() {
  port_open "$WEB_PORT" && return 0
  [ -n "$NOVNC" ] || { log "noVNC not found — nix build nixpkgs#novnc"; return 1; }
  env -u LD_LIBRARY_PATH "$NOVNC" --listen "0.0.0.0:$WEB_PORT" --vnc "127.0.0.1:$VNC_PORT" \
    >"$STATE/novnc.log" 2>&1 &
  for _ in $(seq 1 20); do port_open "$WEB_PORT" && { log "noVNC up (0.0.0.0:$WEB_PORT)"; return 0; }; sleep 1; done
  log "noVNC FAILED (see $STATE/novnc.log)"; return 1
}

log "ui supervisor: display=$DISP vnc=$VNC_PORT web=$WEB_PORT"
while true; do
  ensure_display; start_vnc; start_novnc
  sleep "$SLEEP"
done
