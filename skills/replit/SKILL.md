---
name: replit
description: "Replit sandbox toolkit: platform facts ($HOME wiped on recreate, REPL_HOME/XDG/env channels, rc & git persistence), pulling libs from /nix/store (replit.nix vs nix-env, transitive LD_LIBRARY_PATH closure), Playwright on Replit's bundled Chromium (no browser download), and the Camoufox anti-detection Firefox server (Cloudflare/Turnstile/WAF sites, cookie persistence, session keep-alive). Use for anything running ON a Replit/Nix workspace."
version: 4.2.0
license: MIT
platforms: [linux]
compatibility: "Replit workspaces (/home/runner containers) with nix. Camofox additionally needs Node >= 18 and GTK3/ALSA/X11 libs in /nix/store — gate: R=\"$(nix eval --raw nixpkgs#gtk3 2>/dev/null)\"; [ -e \"$R/lib/libgtk-3.so.0\" ] && echo warm (~10s; never glob /nix/store/*/lib/* on this box)."
metadata:
  hermes:
    tags: [Replit, sandbox, nix, persistence, XDG, REPL_HOME, bashrc, git, env, secrets, playwright, chromium, camofox, camoufox, scraping, cloudflare]
---

# Replit toolkit — one skill, four lanes

Everything here is specific to running **on a Replit/Nix workspace**. The
platform breaks normal Linux assumptions ($HOME wiped, /nix/store GC, npm
firewall), and each lane below is a verified playbook for one job.

**Read `references/platform.md` first if you are new to the box** — every
other lane assumes its persistence rules.

| You want to… | Read | Scripts |
|---|---|---|
| persist data/env/rc/git, understand what survives a restart, fix env-var plumbing | `references/platform.md` | `setup.sh`, `replit_userenv.py` |
| get a system lib that isn't installed (GTK, libatomic, any .so), debug `cannot open shared object file` | `references/nix.md` | `generate-closure.sh`, `libpool.sh` |
| drive Playwright without downloading a browser (the box ships Chromium) | `references/playwright-chromium.md` | `ensure_browser.sh`, `monitor.sh`, `browser_monitor.py` |
| open bot-hardened sites (Cloudflare/Turnstile/WAF), keep logged-in Firefox sessions alive | `references/camofox.md` | `start-camofox.sh`, `camofox.py` |

Hermes-on-Replit recovery specifically (uv `--locked` trailing-slash failures,
PM-staged node needing libatomic): `references/hermes-on-replit.md`.

## The platform in five facts (detail in platform.md)

1. **`$HOME` (`/home/runner`) is wiped on recreate; `$REPL_HOME`
   (`/home/runner/workspace`) is persistent.** Anything you want to survive
   lives under the workspace. The XDG vars are pre-set into the workspace, but
   do not trust that implicitly — check with `printenv | grep XDG_`.
2. **Everything system-level comes from `/nix/store`, and store paths get GC'd.**
   A path that worked yesterday may not exist today; long-lived things need a
   durable copy outside the store (see nix.md, hermes-on-replit.md).
3. **`$REPLIT_LD_LIBRARY_PATH` is never enough** for GUI browsers — you need
   the full transitive closure (nix.md §3; `generate-closure.sh`).
4. **npm is behind a package firewall**; pin `--registry=https://registry.npmjs.org/`.
5. **Replit ships a Playwright-managed Chromium** — `$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE`;
   never `playwright install`.

## Scripts (flat, all in `scripts/`)

- `setup.sh` — idempotent toolchain/env provisioning (node/uv/python pins, LD
  paths, rc chain); run it after any recreate.
- `replit_userenv.py` — structural `.replit [userenv]` edits (tomlkit, no regex).
- `start-camofox.sh` — one-command provision + launch of the Camoufox server.
- `camofox.py` — the scraping CLI (open/nav/eval/screenshot, cookie import,
  keep-alive loop). See camofox.md for its env-file contract.
- `generate-closure.sh` / `libpool.sh` — transitive lib closure + shared pool.
- `ensure_browser.sh` — idempotent CDP launcher for the bundled Chromium.
- `monitor.sh` / `browser_monitor.py` — opt-in :5000 screenshot relay.

## camofox.env.example

Every Camoufox-server tunable with its default; copy to `$CAMOFOX_ROOT/.env`
(see camofox.md).

## Installing this skill pack

One skill, one command:

```bash
npx -y skills add skynight137/skills -s replit
```
