---
name: replit-nix
description: "Replit + Nix: getting system libs from /nix/store — replit.nix vs nix-env, warm/cold store, the full transitive LD_LIBRARY_PATH closure (REPLIT_LD_LIBRARY_PATH alone is never enough), nix eval/path-info gotchas. Use when a Replit workload needs shared libs (GTK/X11/ALSA/...) or 'cannot open shared object file' appears."
version: 2.0.0
license: MIT
platforms: [linux]
compatibility: "Replit workspaces (Nix-managed containers, /home/runner)."
metadata:
  hermes:
    tags: [Replit, Nix, nix-store, replit.nix, nix-env, LD_LIBRARY_PATH, closure]
    related_skills: [replit-knowledge, camofox-on-replit, replit-playwright-chromium]
---

# Replit + Nix: use the store's libs

Field-verified (2026-09-02/03). Scope: everything about pulling packages out of
`/nix/store` at runtime. Platform facts (persistence, `$HOME` wipes, XDG,
registry firewall, `.replit`) live in the **`replit-knowledge`** skill.

## 1. The three-layer model

Anything that needs a non-baseline shared lib (GTK, X11, ALSA, …) has
exactly three layers. Missing any layer = failure:

| Layer | What it is | Cost |
|-------|-----------|------|
| **L1 — store must CONTAIN the libs** | `replit.nix` (recommended) or `nix-env -iA` or a warm store from a prior build | replit.nix: one-time, async rebuild; nix-env: immediate, lost on container recreate |
| **L2 — the full transitive closure as `LD_LIBRARY_PATH`** | generated file: `nix path-info --recursive <root>` per top package, keep paths shipping `lib/`, exclude base-provided families | ~2s to generate |
| **L3 — the loader sees L2** | `export LD_LIBRARY_PATH="$(cat file)"` before launch (or a wrapper does it) | free |

**L1 is the part people skip** — "the sandbox must have the libs" is the
assumption that fails. **L2 is the part everyone gets wrong** — see §3.

L1 2-second gate before doing anything:

```bash
ls /nix/store/*/lib/libgtk-3.so.0   # or the soname you need
```

Empty = cold store → §2.

## 2. replit.nix vs nix-env

```bash
# A: replit.nix at workspace root — auto-applies on every Replit rebuild,
#    survives container recreates (recommended):
{pkgs}: { deps = [ pkgs.gtk3 pkgs.alsa-lib pkgs.xorg.libXdamage ]; }
#   … then WAIT for the rebuild before testing.

# B: nix-env — immediate, but the ~/.nix-profile is lost when the container
#    is recreated from its template (experiments only):
nix-env -iA nixpkgs.gtk3 nixpkgs.alsa-lib nixpkgs.xorg.libXdamage
```

Both are runtime-equivalent: they put the same packages into `/nix/store`.
**The runtime mechanism is the store, not the install method** — a workspace
whose store a prior build filled works with neither file present (verified
T0–T3 matrix); a truly fresh container with an empty store fails with
`replit.nix` deleted.

`replit.nix` changes trigger an **async rebuild**; the sandbox env (PATH,
`REPLIT_LD_LIBRARY_PATH`) only reflects the new build after the rebuild and
a fresh shell. The channel it builds against: `[nix] channel` in `.replit`
(`$REPLIT_NIX_CHANNEL`). Verify package names at search.nixos.org for the
**pinned** channel, not latest.

## 3. `$REPLIT_LD_LIBRARY_PATH` alone is NEVER enough

Replit's dynamic loader (`replit_rtld_loader`, active via `LD_AUDIT` —
`$REPLIT_LD_AUDIT`) searches ONLY the dirs in `LD_LIBRARY_PATH` — no
ldconfig, no fallback. Replit populates `REPLIT_LD_LIBRARY_PATH` with the
**top-level `lib` dirs of the declared packages only** (~8: the packages
themselves + a few direct deps). The transitive closure — `libX11-xcb.so.1`,
`libxcb`, `pango`, `cairo`, `gdk-pixbuf`, `harfbuzz`, `freetype`, … (100+
dirs for GTK3) — is invisible to it.

Symptom matrix (all observed):

| Setup | Result |
|-------|--------|
| cold store, nothing | dies on first lib: `libgtk-3.so.0: cannot open shared object file` |
| store warm, only `$REPLIT_LD_LIBRARY_PATH` exported | dies deep: `libX11-xcb.so.1: cannot open shared object file` |
| store warm + generated closure | works |

**The fix is always the same: generate the closure.** For GTK3 the
`camofox-on-replit` skill ships `scripts/generate-closure.sh` (verified,
~140 dirs). The generic recipe, for other stacks:

```bash
ROOT="$(nix eval --raw nixpkgs#gtk3)"        # note: # not .
nix path-info --recursive "$ROOT" | while read -r p; do
  [[ -d "$p/lib" ]] && echo "$p/lib"
done | sort -u | paste -sd: - > /tmp/closure.txt
# then: export LD_LIBRARY_PATH="$(cat /tmp/closure.txt)"
```

Gotchas found the hard way (all still true):

- **Exclude base-provided families** (`glibc`, `gcc`, `libgcc`, `ncurses`,
  `readline`, `binutils`) from the closure — stale nix copies shadow the
  base's newer libs. For Node specifically this breaks it
  (`undefined symbol: sqlite3session_attach` from an old sqlite in the GTK
  closure; `tcsetattr: Inappropriate ioctl` when a glibc dir sneaks before
  exec). Prepend the *base Node binary's own linked store dirs* (from `ldd`
  on the real `/nix/store/*/bin/node`) instead.
- **`command -v node` is a bash wrapper, not an ELF** — target `*/bin/node`
  under the store for `ldd`/file inspection.
- **`nix eval` uses `#`, not `.`**: `nixpkgs#gtk3` (not `nixpkgs.gtk3`);
  `nix-env -iA` uses `.`.
- Regenerate after any store change (rebuild/GC swaps store hashes).
- `nix path-info --recursive` is the fast closure tool; a `find` over
  `/nix/store` takes >5 min and is pointless.

## Quick diagnostic table

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| `X.so.N: cannot open shared object file` — first lib a stack needs | L1: cold store | §2: replit.nix or nix-env, then continue |
| same error — a DEEP transitive lib (e.g. `libX11-xcb`) | L2: only top-level dirs exported | §3: generate the closure |
| node crashes with `undefined symbol: ...` after export | closure shadowing base libs (old sqlite/openssl) | §3: exclude base families, prepend node's own linked dirs |
| `nix eval` parse error | `.` instead of `#` | `nixpkgs#gtk3` |
| new replit.nix dep not visible | rebuild not finished / stale shell | wait for rebuild, open a fresh shell |
