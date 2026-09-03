---
name: camofox-on-replit
description: "One-command anti-detection Firefox scraping server (Camoufox) on a Replit/Nix sandbox. Use when you need to open/verify bot-hardened sites (Cloudflare/Turnstile/WAF-protected, DuckDuckGo, etc.) that plain Chromium can't pass, or when the user wants a persistent headed-Firefox session with CDP. Provisions, provisions libs, and launches everything in a single script."
version: 3.0.0
license: MIT
platforms: [linux]
compatibility: "Node >= 18 + nix on a Replit sandbox. GTK3/ALSA/X11 libs must EXIST in /nix/store — via replit.nix (recommended), nix-env, or a warm store from a prior build. 2-second gate: ls /nix/store/*/lib/libgtk-3.so.0"
metadata:
  hermes:
    tags: [Camoufox, Firefox, anti-detection, Replit, Nix, CDP, scraping, Cloudflare, headless]
    related_skills: [replit-nix, replit-knowledge, replit-playwright-chromium]
---

# Camofox on Replit — one command

`camofox-browser` (jo-inc) is a small HTTP server that drives a
**Camoufox** browser — a Firefox build patched for anti-detection
(fingerprint, WebRTC, canvas, Turnstile). Sites that block plain Chromium
regularly load here. Server API on `:9377` (JSON; `GET /health`,
`POST /tabs` with `{userId, sessionKey, url}`, CDP endpoints — see the
repo's `openapi.json`).

This skill is **self-contained**: `SKILL.md` + `scripts/` in one folder,
installs via `npx skills add`. Nix/closure mechanics live in the
**`replit-nix`** skill (same repo) — platform facts (persistence, XDG
pre-set, firewall) live in the **`replit-knowledge`** skill — this one just
uses them.

## Fast path — one prompt, works end-to-end

Everything (clone, lib closure, npm deps, 1.3GB engine, server) happens
inside one script. Run:

```bash
bash scripts/start-camofox.sh          # from this skill dir (no other setup)
```

Background the server (it never exits), then verify:

```bash
curl -s http://127.0.0.1:9377/health
# -> {"status":"ok","browserConnected":false,...}   (browser is LAZY — see below)
curl -s -m 90 -X POST http://127.0.0.1:9377/tabs \
  -H 'Content-Type: application/json' \
  -d '{"userId":"t","sessionKey":"t","url":"https://duckduckgo.com/"}'
# -> tab JSON with real DuckDuckGo content = anti-detection layer is working
```

`browserConnected:false` right after start is **normal** — the browser
launches on first tab create, and the first launch can take ~60-90s
(headless Firefox + uBlock). Use `-m 90` on that first `/tabs` call.
The browser also **idle-shuts-down after a few minutes of no tab activity**
(observed ~2-6 min); the server keeps running, and the next `/tabs`
relaunches it (fast — engine is cached). Old tabIds die with each browser
restart; create a fresh tab.

If the script refuses early with `ERROR: no store root for libgtk-3.so.0`,
your `/nix/store` is **cold** (fresh container, GTK never installed there)
— see *Cold store* below. On every other sandbox the store is warm and
this one command is the entire setup.

## What the script does — fixed steps, self-verifying

No "looks done" marker guessing: every run performs the same deterministic
steps, and each command verifies its own result.

| Step | Cost | Behavior on re-run |
|------|------|-----------|
| clone `jo-inc/camofox-browser` | fast | re-clones only when the repo is absent |
| python venv → `$CAMOFOX_ROOT/venv` | fast | healthy venv present; rebuilt otherwise (no python is guaranteed on a bare workspace PATH — `source .venv/bin/activate` is no longer needed; the venv is self-provisioned via `uv` and stays inside the single root) |
| generate lib closure → `LD_LIBRARY_PATH.txt` | fast | regenerates only if a store path vanished (cold store = loud failure, before the slow steps) |
| `npm install` (with `CAMOFOX_SKIP_DOWNLOAD=1`) | seconds | lockfile-pinned no-op when correct, repairs a partial tree; postinstall's hidden engine download is disabled — the fetch-bin step owns the engine |
| `npm run fetch-bin` (engine, ~1.3GB fonts+GeoIP) | ~2s / 1.3GB | **always runs**; `camoufox-js fetch` self-verifies — "up to date!" = no re-download, version bump or partial engine = re-fetch into the fixed `$ENGINE` |
| `exec node server.js` → `:9377` | — | — |

A re-run reuses everything already on disk in seconds; a broken install
self-heals instead of leaking into the server start.

## Layout — ONE directory, one reset

Everything lives under `$XDG_DATA_HOME/camofox/` — no configuration needed:
on Replit the platform pre-sets `XDG_DATA_HOME` to a **workspace** path
(persistent; verify with `printenv | grep XDG_`), and on any other machine
the XDG spec default applies (`~/.local/share/camofox`, uv-style). A
user-set `XDG_DATA_HOME` is always honored.

```
$XDG_DATA_HOME/camofox/
├── camofox-browser/   repo (node_modules, LD_LIBRARY_PATH.txt)
├── venv/              python (uv picks the interpreter; self-provisioned)
├── camoufox/          engine = CAMOUFOX_INSTALL_DIR (re-fetchable)
└── state/             server state: cookies/ profiles/ uploads/ traces/
```

- **Reset everything:** `rm -rf "$XDG_DATA_HOME/camofox"` then re-run
  `start-camofox.sh`. That's the whole cleanup story.
- **Python:** a bare workspace PATH has no guaranteed `python3` (it only
  appears once some venv is activated). The script self-provisions a
  dedicated venv into `$CAMOFOX_ROOT/venv` via `uv` and puts it on `PATH` —
  so `source .venv/bin/activate` is no longer needed; the single command
  `bash scripts/start-camofox.sh` is all you need, from any directory.
- **Why state is NOT inside `camoufox/`:** `npx camoufox-js fetch`
  `rm -rf`s the engine dir whenever it (re)downloads a version — state
  there would vanish on an engine bump. Sibling dirs; same single root.
- **Naming:** `camofox` = the server (jo-inc/camofox-browser);
  `camoufox` = the engine (daijro/camoufox Firefox build). Don't mix.

## Why this works on Replit (the three non-obvious facts)

1. **Libs must exist in `/nix/store` — how they got there is
   interchangeable.** `replit.nix` (recommended; auto-applies on every
   rebuild), `nix-env -iA`, or a warm store from a prior build all work
   identically at runtime. `replit shutdown` + wiping `$HOME` does NOT
   clear `/nix/store`, which is why a "fresh" workspace usually still
   has GTK. 2-second gate before anything else:
   `ls /nix/store/*/lib/libgtk-3.so.0` — non-empty = proceed.
2. **`$REPLIT_LD_LIBRARY_PATH` alone is never enough.** It holds only the
   ~8 top-level lib dirs of the declared packages; Firefox's X11 closure
   (libX11-xcb, libxcb, pango, cairo, … ~100+ dirs) is transitive and
   lives in stores the Replit loader never searches. That's what
   `generate-closure.sh` builds into `LD_LIBRARY_PATH.txt` — the engine
   loading fine and then dying on `libX11-xcb.so.1: cannot open shared
   object file` is the exact signature of using only the 8 dirs.
3. **`$HOME` is wiped on container recreate; the workspace is not.**
   On Replit the platform pre-sets `XDG_*_HOME` to workspace paths
   (verify: `printenv | grep XDG_`), so everything the script writes under
   `$XDG_DATA_HOME/camofox/` survives restarts; elsewhere the script falls
   back to the XDG spec defaults.

Full depth (the verified T0/T1/T2/T3 matrix, `replit.nix` vs `nix-env`,
npm package-firewall, `/nix/store` warm/cold mechanics, the `LD_AUDIT`
loader) is in the **`replit-nix`** skill — load it when something here
fails or you're setting up a different Replit workload.

## Doing it by hand

`start-camofox.sh` does the whole setup itself (same fixed paths, same
fixed steps — see its header). To inspect or run individual steps by
hand, each script works standalone with explicit arguments:

```bash
CAMOFOX_ROOT="$XDG_DATA_HOME/camofox"
git clone https://github.com/jo-inc/camofox-browser "$CAMOFOX_ROOT/camofox-browser"
uv venv "$CAMOFOX_ROOT/venv"
(cd "$CAMOFOX_ROOT/camofox-browser" && CAMOFOX_SKIP_DOWNLOAD=1 npm i --registry=https://registry.npmjs.org/ && npm run fetch-bin)
bash scripts/generate-closure.sh "$CAMOFOX_ROOT/camofox-browser/LD_LIBRARY_PATH.txt"
bash scripts/start-camofox.sh   # fast self-verification pass, then launches :9377
```

The closure/loader mechanics *why* each step exists: the `replit-nix`
skill. Env overrides: `CAMOFOX_ROOT`, `CAMOFOX_REPO_DIR`,
`CAMOUFOX_INSTALL_DIR`, `CAMOFOX_STATE_DIR`, `CAMOFOX_PORT` (default
9377), `CAMOFOX_ACCESS_KEY` (optional auth).

## Cold store (brand-new container, GTK never installed there)

The generator fails loud at step 2 — before the slow steps. Gate:
`ls /nix/store/*/lib/libgtk-3.so.0`. If that misses, pick ONE:

```bash
# Option A (recommended — persists across container recreates):
# replit.nix at workspace root, then wait for the Replit rebuild:
#   {pkgs}: { deps = [ pkgs.gtk3 pkgs.alsa-lib pkgs.xorg.libXdamage ]; }

# Option B (works in the live container only; lost on recreate):
nix-env -iA nixpkgs.gtk3 nixpkgs.alsa-lib nixpkgs.xorg.libXdamage
```

Then re-run `start-camofox.sh`. The `replit-nix` skill explains why each
option behaves as it does (T0–T3 matrix).

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `browserConnected:false` after start | lazy launch — normal | POST `/tabs` with `-m 90`; first launch ~60-90s |
| `Tab no longer exists (browser was restarted)` | browser idle-shutdown after a few minutes of no activity; server is fine | create a new tab — browser relaunches, engine cached |
| `libgtk-3.so.0: cannot open shared object file` | store is COLD | *Cold store* section |
| `libX11-xcb.so.1: cannot open shared object file` | running with only `$REPLIT_LD_LIBRARY_PATH` (8 dirs) | let the script load `LD_LIBRARY_PATH.txt` (don't hand-export the 8 dirs) |
| `ERESOLVE` / `npm warn` during install | harmless peer warnings | ignore |
| tarball 404s from npm | Replit package-firewall registry | `--registry=https://registry.npmjs.org/` (the script sets this) |
| engine dir suddenly empty | engine version bump → `fetch-bin` re-extracted (it wipes first) | expected; re-run `start-camofox.sh` |
| state (cookies/profiles) empty | someone set `CAMOUFOX_INSTALL_DIR` to the state dir, or state was inside `camoufox/` | keep them siblings under the single root (default layout) |

## Verification (done)

- `GET /health` → `status:ok`
- first `POST /tabs` (DuckDuckGo) returns page content (proves the
  anti-detection stack, not just a browser, loaded)
- second `POST /tabs` with the same `sessionKey` reuses the profile
  (proves persistence under `state/profiles/`)

## Files in this skill

- `SKILL.md` — this file.
- `scripts/start-camofox.sh` — the entry point (provision + launch).
- `scripts/generate-closure.sh` — the LD_LIBRARY_PATH closure builder
  (called by start-camofox.sh; usable standalone with an output path).

Nix/closure depth (cold store, T-matrix, loader mechanics): the
`replit-nix` skill.
