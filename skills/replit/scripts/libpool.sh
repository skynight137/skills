#!/usr/bin/env bash
# Rebuild the shared lib pool at $POOL (default $REPL_HOME/.local/lib) from the
# camofox GTK/X11 closure. The pool is the host-wide LD_LIBRARY_PATH dir (what
# the setup.sh rc block always prepends; users commonly pin it in
# .replit [userenv.shared] too — NOT written by setup.sh), so ANY tool —
# camofox, Hermes' staged node, native addons — can dlopen libgtk-3, libasound,
# openssl, etc. from the nix store via symlinks.
#
# Why re-runnable: store paths are content-hashed; a channel bump or store GC
# turns symlinks into dangling ones. start-camofox.sh calls this automatically
# (step 3) after generating the closure; run it standalone only to refresh
# the pool for non-camofox consumers without starting the server.
#
# Safety rules:
#  - ONLY directories under /nix/store are ever linked in (the closure file is
#    workspace-writable — it must not be able to point the pool anywhere else).
#  - only symlinks that point into /nix/store are ever deleted (real files —
#    e.g. libatomic.so.1.2.0 — are never touched; their companion SONAME
#    links like libatomic.so.1 are protected by the first-wins skip below).
#  - on basename collisions the FIRST closure dir wins (loader search order =
#    closure order); an existing link is never re-pointed.
set -uo pipefail
REPL="${REPL_HOME:-/home/runner/workspace}"
# Path truth belongs to the caller: start-camofox.sh resolves $REPO (honoring
# CAMOFOX_ROOT/CAMOFOX_REPO_DIR overrides) and passes TXT/POOL through the
# env; the defaults below only cover standalone runs on the default layout.
TXT="${TXT:-$REPL/camofox/camofox-browser/LD_LIBRARY_PATH.txt}"
POOL="${POOL:-$REPL/.local/lib}"
[[ -s "$TXT" ]] || { echo "libpool: no closure at $TXT — run scripts/start-camofox.sh first" >&2; exit 1; }
mkdir -p "$POOL"

find "$POOL" -maxdepth 1 -type l -lname '/nix/store/*' -delete
linked=0; kept=0; rejected=0
while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    # The pool is host-wide LD_LIBRARY_PATH for EVERY consumer — linking it
    # from dirs a writable closure file names turns a file-write primitive
    # into library injection. Only /nix/store paths are trusted inputs.
    [[ "$d" == /nix/store/* ]] || { rejected=$((rejected+1)); continue; }
    for so in "$d"/*.so "$d"/*.so.*; do
        [[ -e "$so" ]] || continue
        link="$POOL/$(basename "$so")"
        if [[ -e "$link" || -L "$link" ]]; then kept=$((kept+1)); continue; fi
        ln -s "$so" "$link" && linked=$((linked+1))
    done
done < <(tr ':' '\n' < "$TXT")

# Self-heal SONAME links from the pool's OWN real files. The sweep above deletes
# any /nix/store symlink whose target was GC'd (a `hermes update` does exactly
# that: it re-locks and prunes the store). libs that live in the pool as real
# files rather than store links -- e.g. libatomic.so.1.2.0, which NO closure dir
# contains -- therefore lose their companion link (libatomic.so.1) permanently,
# and the next staged-tool launch dies with:
#   node: error while loading shared libraries: libatomic.so.1
# Recreate libX.so.<major> -> libX.so.<major>.<minor>.<patch> for every real file
# matching that shape (never overwriting an existing link or file).
healed=0
for real in "$POOL"/lib*.so.[0-9]*; do
    [[ -f "$real" && ! -L "$real" ]] || continue
    base=$(basename "$real")
    # libatomic.so.1.2.0 -> libatomic.so.1 (strip everything after the major)
    stem=${base%%.so.*}
    ver=${base#*.so.}
    soname="$stem.so.${ver%%.*}"
    [[ "$soname" == "$base" ]] && continue
    link="$POOL/$soname"
    if [[ ! -e "$link" && ! -L "$link" ]]; then
        ln -s "$base" "$link" && healed=$((healed+1))
    fi
done
echo "libpool: linked $linked, skipped $kept existing, rejected $rejected non-store dirs, self-healed $healed SONAME links (pool now has $(find "$POOL" -maxdepth 1 \( -type l -o -type f \) | wc -l) entries)"
