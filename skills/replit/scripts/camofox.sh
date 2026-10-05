#!/usr/bin/env bash
# camofox.sh — install/update + run the Camofox browser server (@askjo/camofox-browser)
# on a Replit/Nix sandbox. ONE script, no framework.
#
# Usage:
#   camofox.sh                  # install pkg @latest + fetch engine + start server
#   camofox.sh --skip-fetch-bin # start server only (engine must already be present)
#
# Install/run (what this script does, nothing more):
#   npm i -g --registry=https://registry.npmjs.org @askjo/camofox-browser@latest
#   PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npx -y camoufox-js fetch   # engine -> $CAMOUFOX_INSTALL_DIR
#   exec camofox-browser                                          # server :9377
#
# Env (official server/engine vars; unset = the fallback shown):
#   CAMOUFOX_INSTALL_DIR   engine dir        (default: ${REPL_HOME:-$HOME}/camofox)
#   CAMOFOX_COOKIES_DIR    cookie jars       (default: <root>/state/cookies)
#   CAMOFOX_PROFILE_DIR    browser profiles  (default: <root>/state/profiles)
#   CAMOFOX_UPLOADS_DIR    uploads           (default: <root>/state/uploads)
#   CAMOFOX_TRACES_DIR     traces            (default: <root>/state/traces)
#   CAMOFOX_PORT           listen port       (default: 9377, server default)
#   CAMOFOX_ACCESS_KEY     global REST auth  (default: unset = loopback-only)
#   CAMOFOX_API_KEY        cookie-import auth(default: unset)
#   CAMOFOX_BASE_URL       dial var for MCP/clients (default: http://127.0.0.1:$CAMOFOX_PORT)
#   where <root> = ${REPL_HOME:-$HOME}/camofox (persistent on Replit)
#
# Nix closure: GTK3/ALSA/X11 libs come from /nix/store as a transitive closure.
# The dir list is built once into $XDG_CONFIG_HOME/camofox/LD_LIBRARY_PATH.txt
# and exported as LD_LIBRARY_PATH on every start. glibc/gcc/ncurses/readline/
# binutils copies are EXCLUDED — a nix glibc/libgcc on LD_LIBRARY_PATH
# stack-smashes node ("*** stack smashing detected ***", proven 2026-10-05).

set -euo pipefail

SKIP_FETCH=0
for arg in "$@"; do
    case "$arg" in
        --skip-fetch-bin) SKIP_FETCH=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "camofox.sh: unknown arg '$arg' (see --help)" >&2; exit 2 ;;
    esac
done

ROOT="${CAMOFOX_ROOT:-${REPL_HOME:-$HOME}/camofox}"        # on-disk home for engine + state
export CAMOUFOX_INSTALL_DIR="${CAMOUFOX_INSTALL_DIR:-$ROOT}"
export CAMOFOX_PORT="${CAMOFOX_PORT:-9377}"
STATE="${CAMOFOX_STATE_DIR:-$ROOT/state}"
export CAMOFOX_COOKIES_DIR="${CAMOFOX_COOKIES_DIR:-$STATE/cookies}"
export CAMOFOX_PROFILE_DIR="${CAMOFOX_PROFILE_DIR:-$STATE/profiles}"
export CAMOFOX_UPLOADS_DIR="${CAMOFOX_UPLOADS_DIR:-$STATE/uploads}"
export CAMOFOX_TRACES_DIR="${CAMOFOX_TRACES_DIR:-$STATE/traces}"
export CAMOFOX_BASE_URL="${CAMOFOX_BASE_URL:-http://127.0.0.1:$CAMOFOX_PORT}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${REPL_HOME:-$HOME}/.local/share}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${REPL_HOME:-$HOME}/.config}"
mkdir -p "$CAMOUFOX_INSTALL_DIR" "$CAMOFOX_COOKIES_DIR" "$CAMOFOX_PROFILE_DIR" \
         "$CAMOFOX_UPLOADS_DIR" "$CAMOFOX_TRACES_DIR"

NPM_PREFIX="$(npm config get prefix)"
PKG_DIR="$NPM_PREFIX/lib/node_modules/@askjo/camofox-browser"

# ---- nix lib closure (GTK3/ALSA/X11) -> $XDG_CONFIG_HOME/camofox/LD_LIBRARY_PATH.txt
CLOSURE_FILE="$XDG_CONFIG_HOME/camofox/LD_LIBRARY_PATH.txt"
build_closure() {
    local out="$CLOSURE_FILE" root p
    mkdir -p "$(dirname "$out")"
    local tmp; tmp="$(mktemp)"
    # Root libs the engine needs at runtime; each resolves via nixpkgs channel,
    # then nix path-info -r expands to the full transitive store closure.
    for lib in libgtk-3.so.0 libasound.so.2 libXdamage.so.1; do
        root="$(nix eval --raw "nixpkgs#$(case $lib in
            libgtk-3.so.0) echo gtk3 ;;
            libasound.so.2) echo alsa-lib ;;
            libXdamage.so.1) echo xorg.libXdamage ;;
        esac)" 2>/dev/null)" || true
        [[ -z "$root" || ! -d "$root" ]] && {
            echo "camofox.sh: $lib not in /nix/store — add 'gtk3 alsa-lib xorg.libXdamage' to replit.nix" >&2
            exit 1
        }
        nix path-info -r "$root" 2>/dev/null >> "$tmp" || true
    done
    sort -u "$tmp" | while read -r p; do
        # EXCLUDE base-image families: their nix copies shadow the base libc
        # and crash node. Load-bearing — do not remove.
        case "$p" in *glibc*|*gcc*|*libgcc*|*ncurses*|*readline*|*binutils*) continue ;; esac
        [[ -d "$p/lib" ]] && printf '%s\n' "$p/lib"
    done | sort -u | paste -sd: - > "$out"
    rm -f "$tmp"
    echo "camofox.sh: closure -> $out ($(tr ':' '\n' < "$out" | grep -c .) dirs)"
}

if [[ ! -s "$CLOSURE_FILE" ]]; then
    build_closure
fi
# closure FIRST (holds the X11/GTK families the base image lacks), then the
# lib pool (libatomic for node). Ambient LD_LIBRARY_PATH is INTENTIONALLY
# dropped: a caller-pinned dir could re-introduce the nix-glibc crash.
export LD_LIBRARY_PATH="$(cat "$CLOSURE_FILE"):/home/runner/workspace/.local/lib"

# ---- sanity: critical libs resolvable
for lib in libgtk-3.so.0 libasound.so.2 libXdamage.so.1; do
    IFS=':' read -ra dirs <<< "$(cat "$CLOSURE_FILE")"
    ok=0; for d in "${dirs[@]}"; do [[ -e "$d/$lib" ]] && ok=1 && break; done
    [[ $ok == 1 ]] || { echo "camofox.sh: $lib MISSING from closure — rebuild it: rm $CLOSURE_FILE" >&2; exit 1; }
done

if [[ $SKIP_FETCH == 0 ]]; then
    echo "camofox.sh: installing @askjo/camofox-browser@latest"
    npm i -g --registry=https://registry.npmjs.org @askjo/camofox-browser@latest
    echo "camofox.sh: fetching engine (pkg-pinned release) -> $CAMOUFOX_INSTALL_DIR"
    (cd "$PKG_DIR" && node lib/camoufox-download.js)
fi

# engine presence check for --skip-fetch-bin
if [[ ! -x "$CAMOUFOX_INSTALL_DIR/camoufox-bin" ]]; then
    echo "camofox.sh: engine missing at $CAMOUFOX_INSTALL_DIR/camoufox-bin — run without --skip-fetch-bin once" >&2
    exit 1
fi

# ---- newPageTimeoutMs floor (file-only setting; upstream default 10s is too
# tight for Nix cold starts — 60000 proven live). Raise-only, idempotent.
node -e '
const fs=require("fs"),p="'"$PKG_DIR"'/camofox.config.json";
const j=JSON.parse(fs.readFileSync(p,"utf8"));
const cur=Number(j.newPageTimeoutMs);
if(!Number.isFinite(cur)||cur<60000){
  j.newPageTimeoutMs=60000;
  fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n");
  console.log("camofox.sh: newPageTimeoutMs "+cur+" -> 60000");
}' 2>/dev/null || true

echo "camofox.sh: starting server on :$CAMOFOX_PORT (engine $CAMOUFOX_INSTALL_DIR)"
cd "$PKG_DIR"
exec node server.js
