#!/usr/bin/env bash
# start-camofox.sh — one-command provision + launch of the camofox-browser
# server (jo-inc/camofox-browser) on a Replit/Nix sandbox.
#
# Fixed steps, self-verifying — each run is deterministic:
#   1. clone the repo          (clone only when absent)
#   2. python venv             (uv picks the interpreter -> $CAMOFOX_ROOT/venv; self-skip)
#   3. lib closure             (fail loudly if the nix store has no GTK)
#   4. npm install             (always runs; lockfile-pinned no-op when correct)
#   5. fetch engine            (always runs; fetch-bin self-verifies —
#                                up-to-date = no re-download, broken = repairs)
#   6. exec node server.js     (port 8008)
#
# ONE directory holds everything (uv-style, under XDG_DATA_HOME):
#   $XDG_DATA_HOME/camofox/
#   ├── camofox-browser/   repo clone (node_modules, LD_LIBRARY_PATH.txt)
#   ├── venv/              python (uv, no pinned version; self-provisioned)
#   ├── camoufox/          engine = CAMOUFOX_INSTALL_DIR (re-fetchable)
#   └── state/             server state: cookies/ profiles/ uploads/ traces/
# Reset = rm -rf "$XDG_DATA_HOME/camofox"  (re-run this script to re-provision)
#
# Naming: camofox = the SERVER (jo-inc/camofox-browser); camoufox = the ENGINE
# (daijro/camoufox Firefox build). State lives in state/, NOT inside camoufox/:
# `npx camoufox-js fetch` rm -rf's the engine dir on a version bump
# (camoufox-js dist/pkgman.js), and would wipe cookies/profiles.
#
# The only real requirement: GTK3/ALSA/X11 must EXIST in /nix/store — via
# replit.nix (recommended), nix-env, or a warm store from a prior build.
# Gate (~2s, resolve the store path — never glob the whole store, a
# /nix/store/*/lib/* glob never finishes on a warm 700k-entry store):
#   R="$(nix eval --raw nixpkgs#gtk3 2>/dev/null)"; [ -e "$R/lib/libgtk-3.so.0" ] && echo warm
# Background (persistence, /nix/store fast path, npm firewall): the
# replit-nix skill.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# XDG: Replit PRE-SETS XDG_*_HOME to workspace (persistent) paths — check
# with `printenv | grep XDG_`. The fallbacks below are the XDG SPEC
# defaults, used only on other machines / non-login contexts where the vars
# are unset — so the layout stays uv-style (~/.local/share/<tool>) and any
# user-set XDG_*_HOME is honored everywhere.
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

# --- the single root — all absolute, independent of where the skill lives ----
# Default under XDG_DATA_HOME; every target overridable independently.
# Everything the script reads AND writes lives under $CAMOFOX_ROOT — it never
# touches any other location.
CAMOFOX_ROOT="${CAMOFOX_ROOT:-$XDG_DATA_HOME/camofox}"
REPO="${CAMOFOX_REPO_DIR:-$CAMOFOX_ROOT/camofox-browser}"
ENGINE="${CAMOUFOX_INSTALL_DIR:-$CAMOFOX_ROOT/camoufox}"
STATE="${CAMOFOX_STATE_DIR:-$CAMOFOX_ROOT/state}"
# --- Tuned overrides -----------------------------------------------------------
# Every variable below is OPTIONAL: Camofox sets its own default for each. These
# are the values this skill recommends, and each is an explicit override of a
# Camofox default — not a redundant restatement of one. Comment a line out to
# accept Camofox's default instead. Full list: camofox.env.example.
# Port: Camofox already defaults to 9377 (lib/config.js:129 tries CAMOFOX_PORT,
# then PORT, then '9377'), so this export is a no-op in a clean environment.
export CAMOFOX_PORT="${CAMOFOX_PORT:-9377}"        # Camofox default: 9377
# Per-tab inactivity reaper threshold (server.js:6040, lib/config.js:149).
# Camofox default 300000 sits exactly on a 300s client loop period -> the reaper
# wins the race and closes the tab (refresh 404 -> client reopens). Keep this
# well above any client --interval: 900000 = 3x a 300s loop.
# NOTE: 0 does NOT disable this one -- lib/config.js:149 is `parseInt(...) || 300000`,
# so 0 is falsy and silently becomes the 300000 default (the MOST aggressive).
# To effectively turn the reaper off, pass a large number (e.g. 86400000 = 24h).
export TAB_INACTIVITY_MS="${TAB_INACTIVITY_MS:-900000}"   # Camofox default: 300000

# Session reaper (server.js:5978, lib/config.js:116). Camofox default 600000 is
# the REAL binding constraint: a tab reap empties the session, and once its
# lastAccess goes stale the session is closed -> context.close() -> cookies
# gone -> the client's tab reopen lands logged OUT. Only a request touching
# the session (refresh, screenshot, navigate) bumps lastAccess, so this must
# stay comfortably above the client --interval too.
# Unlike TAB_INACTIVITY_MS, 0 here genuinely disables expiry (guarded by
# `SESSION_TIMEOUT_MS > 0` at server.js:5978) -- set 0 to never expire.
export SESSION_TIMEOUT_MS="${SESSION_TIMEOUT_MS:-1800000}"  # Camofox default: 600000

# Idle browser shutdown (server.js:697-705, lib/config.js:119). Camofox default
# 300000 costs a full cold start (~90s: xvfb + camoufox launch) the next time a
# run needs the browser. Only runs when sessions.size === 0. 0 = never shut it
# down.
export BROWSER_IDLE_TIMEOUT_MS="${BROWSER_IDLE_TIMEOUT_MS:-0}"  # Camofox default: 300000

# Load secrets/config from an env file IF one exists. OPTIONAL — no agent
# framework is involved. Resolution order, first existing wins:
#   1. $CAMOFOX_ENV_FILE     explicit path
#   2. $CAMOFOX_ROOT/.env    tool-native home (copy camofox.env.example here)
#   3. nothing — falls through to the CAMOFOX_API_KEY process env var
# See camofox.env.example for every tunable with its Camofox default.
for _cand in "${CAMOFOX_ENV_FILE:-}" "$CAMOFOX_ROOT/.env"; do
    if [[ -n "$_cand" && -f "$_cand" ]]; then
        # shellcheck disable=SC1090
        set -a; . "$_cand"; set +a
        echo "[start-camofox] loaded env file $_cand"
        break
    fi
done
unset _cand

# 1) repo ------------------------------------------------------------------------
if [[ ! -f "$REPO/server.js" ]]; then
    echo "[provision] cloning camofox-browser -> $REPO"
    git clone --depth 1 https://github.com/jo-inc/camofox-browser "$REPO"
fi

# 2) python — a usable interpreter is NOT guaranteed on the default PATH
#    (python3 only shows up once some venv is activated; a bare workspace
#    has none). So we self-provision a dedicated venv at $CAMOFOX_ROOT/venv
#    — inside the single root, so the one rm -rf still resets everything.
#    Idempotent: a healthy venv is a ~1s check; a missing/partial one is
#    rebuilt. Requires `uv` (Replit: $PWD/bin; elsewhere: PATH).
if [[ ! -x "$CAMOFOX_ROOT/venv/bin/python" ]] || ! "$CAMOFOX_ROOT/venv/bin/python" -c pass 2>/dev/null; then
    if command -v uv >/dev/null 2>&1; then UV="$(command -v uv)"
    elif [[ -x "$PWD/bin/uv" ]]; then UV="$PWD/bin/uv"
    else echo "[error] python required but no usable venv at $CAMOFOX_ROOT/venv and no uv found" >&2; exit 1; fi
    echo "[provision] python venv (uv, version chosen by uv) -> $CAMOFOX_ROOT/venv"
    rm -rf "$CAMOFOX_ROOT/venv"   # partial venv = broken venv; rebuild, don't skip
    "$UV" venv "$CAMOFOX_ROOT/venv"
fi
export PATH="$CAMOFOX_ROOT/venv/bin:$PATH"
# Optional extra: the youtube plugin prefers yt-dlp over its browser
# fallback when available. One-liner: uv tool install yt-dlp
command -v yt-dlp >/dev/null 2>&1 || echo "[note] yt-dlp not on PATH — YouTube transcripts will use the (slower) browser fallback"

# 3) GTK/X11/ALSA lib closure — generated into the repo dir; regenerated when
#    any store path in it vanished (store rebuild/GC). Fails loudly + early
#    (before the slow steps) when the store is cold.
closure_ok() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    [[ "$(tr ':' '\n' < "$f" | while IFS= read -r d; do [[ -d "$d" ]] || echo gone; done)" == "" ]]
}
if ! closure_ok "$REPO/LD_LIBRARY_PATH.txt"; then
    echo "[provision] generating lib closure -> $REPO/LD_LIBRARY_PATH.txt"
    bash "$SKILL_DIR/scripts/generate-closure.sh" "$REPO/LD_LIBRARY_PATH.txt"
fi
if [[ -z "${LD_LIBRARY_PATH:-}" ]]; then
    export LD_LIBRARY_PATH="$(cat "$REPO/LD_LIBRARY_PATH.txt")"
fi

# 4) npm deps — ALWAYS run (fixed step). Self-healing: with the pinned
#    package-lock.json an already-correct tree resolves in seconds; a
#    partial/corrupt node_modules dir is repaired — `[[ -d node_modules ]]`
#    would have let a broken tree pass and leak into the server start.
#    Replit's package-firewall pins the npm registry and 404s tarballs, so
#    pin npmjs.org explicitly (matches the verified fast path). XDG vars are
#    exported above (the repo's postinstall shells out to npx, whose nix
#    wrapper dies on unset XDG_*), loglevel=error hides harmless peer
#    warnings, and CAMOFOX_SKIP_DOWNLOAD=1 stops the repo's postinstall from
#    silently fetching a SECOND engine copy into its default cache — step 4
#    owns the engine, in $ENGINE.
export CAMOFOX_SKIP_DOWNLOAD=1
(cd "$REPO" && npm_config_loglevel=error npm install --no-audit --no-fund --registry="https://registry.npmjs.org/")

# 5) engine — ALWAYS run `npm run fetch-bin` (fixed step, no skip-guessing).
# It is self-verifying: `camoufox-js fetch` compares the installed version
# against the pinned one and prints "Camoufox binaries up to date!" without
# re-downloading (~2s), re-fetches only on a version bump, and repairs a
# partial/broken engine dir. Never guard it on marker files — a partial
# engine passes any marker check but still fails to launch.
export CAMOUFOX_INSTALL_DIR="$ENGINE"
# camoufox-js honors playwright's skip flag by convention; a stray
# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD in the shell would leave the engine empty
# and crash the server with "Version information not found".
unset PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD
mkdir -p "$ENGINE"
(cd "$REPO" && npm run fetch-bin)

# 6) server state + launch ----------------------------------------------------------
# Upstream defaults live under $HOME/.camofox/ (wiped on recreate); anchor them
# here. Env names keep upstream's CAMOFOX_ spelling (that is what the server
# reads); only the on-disk location moved.
export CAMOFOX_COOKIES_DIR="${CAMOFOX_COOKIES_DIR:-$STATE/cookies}"
export CAMOFOX_UPLOADS_DIR="${CAMOFOX_UPLOADS_DIR:-$STATE/uploads}"
export CAMOFOX_PROFILE_DIR="${CAMOFOX_PROFILE_DIR:-$STATE/profiles}"
export CAMOFOX_TRACES_DIR="${CAMOFOX_TRACES_DIR:-$STATE/traces}"
mkdir -p "$ENGINE" "$CAMOFOX_COOKIES_DIR" "$CAMOFOX_UPLOADS_DIR" \
         "$CAMOFOX_PROFILE_DIR" "$CAMOFOX_TRACES_DIR"

echo "[start-camofox] root=$CAMOFOX_ROOT"
echo "[start-camofox] repo=$REPO"
echo "[start-camofox] engine=$ENGINE"
echo "[start-camofox] state=$STATE"
echo "[start-camofox] listening on :$CAMOFOX_PORT"
cd "$REPO"
exec node server.js
