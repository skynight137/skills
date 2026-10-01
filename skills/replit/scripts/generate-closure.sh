#!/usr/bin/env bash
# generate-closure.sh — build the curated LD_LIBRARY_PATH.txt closure for
# Camoufox-Firefox on a Nix host (Replit or otherwise).
#
# WHY: Replit's rtld-loader (LD_AUDIT) only searches REPLIT_LD_LIBRARY_PATH,
# which holds the TOP-LEVEL lib dirs of the replit.nix-declared packages (~6).
# Firefox's GTK3 runtime needs the TRANSITIVE X11 closure (~40+ dirs) — those
# live in dependency stores the loader never sees. This script generates it.
# The generated file is what start-camofox.sh auto-loads (when LD_LIBRARY_PATH
# is unset) from $REPO/LD_LIBRARY_PATH.txt.
#
# RESOLUTION (per package, so the INSTALLED version is always used):
#   1. nix-env profile: if ~/.nix-profile/lib/<lib> exists (manual install),
#      the store root is derived from its symlink target.
#   2. otherwise: resolve via the nixpkgs channel
#      (`nix eval --raw nixpkgs#<attr>`) — a pure eval, needs NO replit.nix
#      file. But the resolved store path must ACTUALLY EXIST in /nix/store:
#      declaring it is not required, the store being WARM is (a prior
#      replit.nix build, nix-env, or the sandbox's own history). On a cold
#      store this script fails loudly (empty closure) and leaves no file.
#   Then: `nix path-info --recursive <root>` gives the full dependency closure;
#   keep every store path that ships a `lib/` dir, and EXCLUDE the
#   base-image-provided families (glibc/gcc/libgcc/ncurses/readline/binutils) —
#   stale nix copies shadow the base's newer libs and break Node itself.
#
# Usage: generate-closure.sh <output-file>
# Requirements: nix (nix-env or replit.nix rebuild), nixpkgs channel.
# Output: colon-separated `lib` dirs, sorted, single line.

set -euo pipefail

if [[ -n "${1:-}" ]]; then
    OUT="$1"
else
    echo "ERROR: generate-closure.sh needs an output path." >&2
    echo "       start-camofox.sh calls it for you — prefer that entry point." >&2
    exit 2
fi

PROFILE_LIB="${HOME}/.nix-profile/lib"

resolve_root() { # $1 = lib soname ; prints store root path (or nothing)
    local lib="$1" target root
    # 1) manual nix-env install: profile symlink -> store root
    if [[ -e "$PROFILE_LIB/$lib" ]]; then
        target="$(readlink -f "$PROFILE_LIB/$lib" 2>/dev/null || true)"
        if [[ "$target" == /nix/store/*/lib/* ]]; then
            root="${target%/lib/*}"
            [[ -d "$root" ]] && { printf '%s' "$root"; return 0; }
        fi
    fi
    # 2) replit.nix install: resolve via the nixpkgs channel
    case "$lib" in
        libgtk-3.so.0)   nix eval --raw "nixpkgs#gtk3" 2>/dev/null ;;
        libasound.so.2)  nix eval --raw "nixpkgs#alsa-lib" 2>/dev/null ;;
        libXdamage.so.1) nix eval --raw "nixpkgs#xorg.libXdamage" 2>/dev/null ;;
    esac
}

declare -A paths=()
declare -a roots=()
for lib in libgtk-3.so.0 libasound.so.2 libXdamage.so.1; do
    root="$(resolve_root "$lib")"
    if [[ -z "${root:-}" ]]; then
        echo "ERROR: no store root for $lib — install via replit.nix (gtk3, alsa-lib, xorg.libXdamage)" >&2
        echo "       or: nix-env -iA nixpkgs.gtk3 nixpkgs.alsa-lib nixpkgs.xorg.libXdamage" >&2
        exit 1
    fi
    if [[ ! -d "$root" ]]; then
        echo "ERROR: $lib resolved to $root, but that path is NOT in /nix/store." >&2
        echo "       Cold store: nothing has installed the GTK/ALSA/X11 libs yet (no replit.nix" >&2
        echo "       build, no nix-env). The nixpkgs channel resolves the name; the libs must" >&2
        echo "       actually exist in the store. Fix (one of):" >&2
        echo "         replit.nix: deps = [ pkgs.gtk3 pkgs.alsa-lib pkgs.xorg.libXdamage ];  # wait for rebuild" >&2
        echo "         nix-env -iA nixpkgs.gtk3 nixpkgs.alsa-lib nixpkgs.xorg.libXdamage" >&2
        exit 1
    fi
    roots+=("$root")
    echo "root for $lib: $root" >&2
    while IFS= read -r p; do
        [[ -n "$p" ]] && paths["$p"]=1
    done < <(nix path-info --recursive "$root" 2>/dev/null)
done

echo "closure paths: ${#paths[@]}" >&2

{
    for p in "${!paths[@]}"; do
        case "$p" in
            *glibc*|*gcc*|*libgcc*|*ncurses*|*readline*|*binutils*) continue ;;
        esac
        [[ -d "$p/lib" ]] && printf '%s\n' "$p/lib"
    done
} | sort -u | paste -sd: - > "$OUT"
n=$(tr ':' '\n' < "$OUT" | grep -c .)
echo "Wrote $OUT with $n lib dirs" >&2

# Prepend the base node's own linked store dirs to the FRONT of the closure.
# Why: node (and anything else it links — sqlite, nghttp2, brotli, ...) will
# resolve those sonames to the CLOSURE's older copies (e.g. gtk3-3.24.30's
# sqlite-3.35.5 / nghttp2-1.44.x) and die with "undefined symbol: ...". The
# base system's own copies are what node was built against, so they must win.
# Firefox is unaffected: it only needs the X11/GTK libs from the tail, and any
# lib it shares with node (zlib, icu, ...) resolves to the base's NEWER copy,
# which is soname-compatible.
node_dirs=""
node_bin="$(command -v node || true)"
if [[ -n "$node_bin" ]]; then
    if [[ "$(head -c4 "$node_bin" 2>/dev/null | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
        node_bin="$(grep -oE '/nix/store/[^ "]*nodejs-[^ "]*' "$node_bin" 2>/dev/null | head -1 || true)"
    fi
    if [[ -x "$node_bin" ]]; then
        node_dirs="$(ldd "$node_bin" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\/nix\/store\//) print $i}' \
            | xargs -r -n1 dirname 2>/dev/null \
            | grep -vE '(^|/)libg?c\.so|glibc|libgcc' \
            | sort -u | paste -sd: -)"
    fi
fi
if [[ -n "$node_dirs" ]]; then
    pre_n="$(tr ':' '\n' <<< "$node_dirs" | grep -c .)"
    printf '%s:%s' "$node_dirs" "$(cat "$OUT")" > "$OUT"
    echo "prepended $pre_n node-linked dirs to front" >&2
fi

# sanity: the critical libs must be resolvable inside the closure
IFS=':' read -ra dirs < "$OUT"
for lib in libgtk-3.so.0 libXdamage.so.1 libasound.so.2 libX11-xcb.so.1; do
    ok=0
    for d in "${dirs[@]}"; do
        [[ -e "$d/$lib" ]] && { ok=1; break; }
    done
    if ((ok)); then echo "  ok       $lib" >&2; else echo "  MISSING  $lib" >&2; fi
done
