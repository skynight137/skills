# Replit + Nix: use the store's libs

Field-verified (2026-09-02/03). Scope: everything about pulling packages out of
`/nix/store` at runtime. Platform facts (persistence, `$HOME` wipes, XDG,
registry firewall, `.replit`) live in **`references/platform.md`**.

## 1. The three-layer model

Anything that needs a non-baseline shared lib (GTK, X11, ALSA, …) has
exactly three layers. Missing any layer = failure:

| Layer | What it is | Cost |
|-------|-----------|------|
| **L1 — store must CONTAIN the libs** | `.replit [nix] packages` (recommended) or a root `replit.nix`, or `nix-env -iA`, or a warm store from a prior build | packages/replit.nix: one-time, async rebuild; nix-env: immediate, lost on container recreate |
| **L2 — the full transitive closure as `LD_LIBRARY_PATH`** | generated file: `nix path-info --recursive <root>` per top package, keep paths shipping `lib/`, exclude base-provided families | ~2s to generate |
| **L3 — the loader sees L2** | `export LD_LIBRARY_PATH="$(cat file)"` before launch (or a wrapper does it) | free |

**L1 is the part people skip** — "the sandbox must have the libs" is the
assumption that fails. **L2 is the part everyone gets wrong** — see §3.

Gate before doing anything — resolve the store path; never glob
`/nix/store/*/lib/*` (it never finishes on a warm 700k-entry store):

```bash
R="$(nix eval --raw nixpkgs#gtk3 2>/dev/null)"; [ -e "$R/lib/libgtk-3.so.0" ] && echo warm
```

Empty = cold store → §2.

## 2. Getting packages into the store: `.replit [nix]` (recommended) vs `replit.nix` vs `nix-env`

**Recommended lane: the root `replit.nix`** — declare every store package
there. Packages added in `.replit [nix] packages` were observed to drop
`cacert`, which left TLS without a CA bundle, so `.replit` is NOT the default.

```nix
# replit.nix (workspace root)
{pkgs}: {
  deps = [
    pkgs.cacert          # CA bundle -> SYSTEM_CERTIFICATE_PATH -> SSL_CERT_FILE
    pkgs.gtk3            # Camofox: libmozgtk.so -> libgtk-3.so.0
    pkgs.alsa-lib        # Camofox
    pkgs.xorg.libXdamage # Camofox
    pkgs.xorg.xvfb       # Camofox virtual display + GLX
    # ...the rest of the workspace toolchain
  ];
}
```

Verify before relying on it: `nix-instantiate --parse replit.nix` (syntax) and
`nix eval` each `pkgs.<attr>` name against the pinned channel. Keep `replit.nix`
tracked in git; a staged deletion of it is a regression, not a cleanup.

`.replit [nix] packages` is the **alternate** lane. Use it only if the
`replit.nix` form is unavailable on the platform, and re-check `cacert` after
every rebuild.

The runtime mechanism is still the store, not the declaration site: a
workspace whose store a prior build filled works without either file (verified
T0–T3 matrix). A fresh container with an empty store needs the declaration,
which is why `replit.nix` is the one to keep.

`nix-env` is the immediate, non-persistent option:

```bash
nix-env -iA nixpkgs.gtk3 nixpkgs.alsa-lib nixpkgs.xorg.libXdamage
```

Changes to `[nix] packages` (or `replit.nix`) trigger an **async rebuild**; the
sandbox env (PATH, `REPLIT_LD_LIBRARY_PATH`) only reflects the new build after
the rebuild and a fresh shell. The channel is `[nix] channel` in `.replit`
(`$REPLIT_NIX_CHANNEL`). Verify package names at search.nixos.org for the
**pinned** channel, not latest.

**`pkgs.cacert` matters twice over:** it supplies the CA bundle *and* exports
`SYSTEM_CERTIFICATE_PATH`, which `setup.sh`'s managed rc block consumes to set
`SSL_CERT_FILE`/`SSL_CERT_DIR`/`NIX_SSL_CERT_FILE`/`NODE_EXTRA_CA_CERTS`. Keep
`cacert` in the `packages` list or TLS fetches lose their trust anchor.

## 3. `$REPLIT_LD_LIBRARY_PATH` alone is NEVER enough

Replit's dynamic loader (`replit_rtld_loader`, active via `LD_AUDIT` —
`$REPLIT_LD_AUDIT`) searches ONLY the dirs in `LD_LIBRARY_PATH` — no
ldconfig, no fallback. Replit populates `REPLIT_LD_LIBRARY_PATH` with the
**top-level `lib` dirs of the declared packages only** (24 dirs on this
box: the packages themselves + their direct deps). The transitive closure — `libX11-xcb.so.1`,
`libxcb`, `pango`, `cairo`, `gdk-pixbuf`, `harfbuzz`, `freetype`, … (100+
dirs for GTK3) — is invisible to it.

Symptom matrix (all observed):

| Setup | Result |
|-------|--------|
| cold store, nothing | dies on first lib: `libgtk-3.so.0: cannot open shared object file` |
| store warm, only `$REPLIT_LD_LIBRARY_PATH` exported | dies deep: `libX11-xcb.so.1: cannot open shared object file` |
| store warm + generated closure | works |

**The fix is always the same: generate the closure.** For GTK3 the
This skill ships `scripts/setup/generate-closure.sh` (verified,
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
| `X.so.N: cannot open shared object file` — first lib a stack needs | L1: cold store | §2: add to `.replit [nix] packages` (or `replit.nix` / nix-env), then continue |
| same error — a DEEP transitive lib (e.g. `libX11-xcb`) | L2: only top-level dirs exported | §3: generate the closure |
| node crashes with `undefined symbol: ...` after export | closure shadowing base libs (old sqlite/openssl) | §3: exclude base families, prepend node's own linked dirs |
| `nix eval` parse error | `.` instead of `#` | `nixpkgs#gtk3` |
| new nix dep not visible | rebuild not finished / stale shell | wait for rebuild, open a fresh shell |
