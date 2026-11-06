#!/usr/bin/env bash
# lp-tour.sh — launcher for lp-tour.py. It exists ONLY to do the env
# assembly the program cannot do for itself:
#   1. the tour venv's greenlet needs libstdc++.so.6, which on a Replit
#      box lives in the nix store, and LD_LIBRARY_PATH must be exported
#      BEFORE python starts (the running interpreter's loader will not
#      pick it up afterwards);
#   2. it resolves WHICH python runs the tour (the venv that
#      `setup.sh --lightpanda` created under $LIGHTPANDA_HOME, falling
#      back to a PATH python3) and the managed engine home, so a
#      workflow/Run-button shell needs no sourcing first.
# All tour logic lives in lp-tour.py; this file adds no behaviour of
# its own. (Same justified-shim shape as the trial launcher and the
# camofox-mcp wrapper: env assembly for a caller that gets none.)
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"

LIGHTPANDA_HOME="${LIGHTPANDA_HOME:-${XDG_CONFIG_HOME:-${REPL_HOME:-$HOME}/.config}/lightpanda}"
export LIGHTPANDA_HOME

LIB=$(ls /nix/store/*gcc*lib*/lib/libstdc++.so.6 2>/dev/null | head -1)
[ -n "$LIB" ] && export LD_LIBRARY_PATH="$(dirname "$LIB")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ -x "$LIGHTPANDA_HOME/venv/bin/python" ]; then
  PY="$LIGHTPANDA_HOME/venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3)"
else
  echo "lp-tour: no python found — run: bash $D/setup.sh --lightpanda" >&2
  exit 1
fi
exec "$PY" -u "$D/lp-tour.py" "$@"
