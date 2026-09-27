#!/usr/bin/env bash
# Rebuild the shared lib pool at $REPL_HOME/.local/lib from the camofox GTK/X11
# closure. The pool is the host-wide LD_LIBRARY_PATH (pinned in
# .replit [userenv.shared]) so ANY tool — camofox, Hermes' staged node,
# native addons — can dlopen libgtk-3, libasound, openssl, etc. from the nix
# store via symlinks.
#
# Why re-runnable: store paths are content-hashed; a channel bump or store GC
# turns symlinks into dangling ones. start-camofox.sh calls this automatically
# (step 4b) after regenerating the closure; run it standalone only to refresh
# the pool for non-camofox consumers without starting the server.
#
# Safety rules:
#  - only symlinks that point into /nix/store are ever deleted (real files —
#    e.g. libatomic.so.1.2.0 — are never touched; their companion SONAME
#    links like libatomic.so.1 are protected by the first-wins skip below).
#  - on basename collisions the FIRST closure dir wins (loader search order =
#    closure order); an existing link is never re-pointed.
set -uo pipefail
REPL="${REPL_HOME:-/home/runner/workspace}"
TXT="$REPL/camofox/camofox-browser/LD_LIBRARY_PATH.txt"
POOL="$REPL/.local/lib"
[[ -s "$TXT" ]] || { echo "libpool: no closure at $TXT — run scripts/start-camofox.sh first" >&2; exit 1; }
mkdir -p "$POOL"

find "$POOL" -maxdepth 1 -type l -lname '/nix/store/*' -delete
linked=0; kept=0
while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    for so in "$d"/*.so "$d"/*.so.*; do
        [[ -e "$so" ]] || continue
        link="$POOL/$(basename "$so")"
        if [[ -e "$link" || -L "$link" ]]; then kept=$((kept+1)); continue; fi
        ln -s "$so" "$link" && linked=$((linked+1))
    done
done < <(tr ':' '\n' < "$TXT")
echo "libpool: linked $linked, skipped $kept existing (pool now has $(find "$POOL" -maxdepth 1 \( -type l -o -type f \) | wc -l) entries)"
