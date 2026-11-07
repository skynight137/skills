#!/usr/bin/env bash
# tour.sh — launcher for tour.py, the SHARED tour (scripts/ root —
# a ready-to-run script, NOT part of setup; --machine muse|repl).
# It exists ONLY to do the env assembly the
# program cannot do for itself:
#   1. (nix boxes only — repl) the tour venv's greenlet needs
#      libstdc++.so.6, which on a Replit box lives in the nix store,
#      and LD_LIBRARY_PATH must be exported BEFORE python starts (the
#      running interpreter's loader will not pick it up afterwards).
#      The assembly runs ONLY when a nix store exists; on a muse box
#      there is none and the step is skipped entirely;
#   2. it resolves WHICH python runs the tour (the venv the setup
#      entry created under $LIGHTPANDA_HOME, falling back to a PATH
#      python3) and the managed engine home, so a workflow/Run-button
#      shell needs no sourcing first;
#   3. (nix boxes, local Playwright engines only) it prepends the
#      engine's closure.txt lib dirs — a foreign Chromium binary
#      loads only under its matched nix ld.so/glibc + store libs.
# All tour logic lives in tour.py; this file adds no behaviour of its
# own — --browser/--machine and every other arg pass straight through.
# (Same justified-shim shape as the camofox-mcp wrapper: env assembly
# for a caller that gets none.)
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"

LIGHTPANDA_HOME="${LIGHTPANDA_HOME:-${XDG_CONFIG_HOME:-${REPL_HOME:-$HOME}/.config}/lightpanda}"
export LIGHTPANDA_HOME

if [ -d /nix/store ]; then
  LIB=$(ls /nix/store/*gcc*lib*/lib/libstdc++.so.6 2>/dev/null | head -1)
  [ -n "$LIB" ] && export LD_LIBRARY_PATH="$(dirname "$LIB")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Local Playwright engines (patchright / cloakbrowser): their
# Chromium is a foreign binary whose runtime libs live in the nix
# store across ~18 package dirs, and it only loads under a matched
# nix ld.so/glibc pair (the binary's interpreter is patched at
# engine setup). When the engine's closure file exists (a
# colon-separated dir list in its home, produced at setup), prepend
# it — gated on the requested engine so the other engines' runs
# keep the plain path above.
_PW_ENGINE=""
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "--browser" ]; then _PW_ENGINE="$_a"; fi
  case "$_a" in --browser=*) _PW_ENGINE="${_a#--browser=}" ;; esac
  _prev="$_a"
done
[ -z "$_PW_ENGINE" ] && _PW_ENGINE="${TOUR_BROWSER:-}"
case "$_PW_ENGINE" in
  patchright|cloakbrowser)
    _CFG_BASE="$(dirname "$LIGHTPANDA_HOME")"
    _CLOSURE="$_CFG_BASE/$_PW_ENGINE/closure.txt"
    if [ -f "$_CLOSURE" ]; then
      export LD_LIBRARY_PATH="$(cat "$_CLOSURE")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    ;;
esac

if [ -x "$LIGHTPANDA_HOME/venv/bin/python" ]; then
  PY="$LIGHTPANDA_HOME/venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3)"
else
  echo "tour: no python found — run: bash $D/setup.sh --lightpanda" >&2
  exit 1
fi
exec "$PY" -u "$D/tour.py" "$@"
