---
name: replit
description: "Replit sandbox toolkit: platform facts ($HOME wiped on recreate, REPL_HOME/XDG/env channels, rc & git persistence), pulling libs from /nix/store (replit.nix vs nix-env, transitive LD_LIBRARY_PATH closure), Playwright on Replit's bundled Chromium (no browser download), and the Camoufox anti-detection Firefox server (Cloudflare/Turnstile/WAF sites, cookie persistence, session keep-alive). Use for anything running ON a Replit/Nix workspace."
version: 4.12.0
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
| open bot-hardened sites (Cloudflare/Turnstile/WAF), keep logged-in Firefox sessions alive, **agent browsing on Hermes (camofox MCP — `browser_exec` is broken here)** | `references/camofox.md` | `setup.sh --camofox` (npm lane), `start-camofox.sh`, `camofox.py` |
| bridge CLI coding subscriptions (Codex/Claude Code/Antigravity/Gemini CLI/Kimi/xAI) into OpenAI+Claude APIs on the box | `references/cliproxy.md` | `setup.sh --cliproxy` |

Hermes-on-Replit recovery specifically (uv `--locked` trailing-slash failures,
official Node ≥22 tarballs needing libatomic): `references/hermes-on-replit.md`.

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

## Scripts (entry point in `scripts/`, modules in `scripts/setup/`)

- `setup.sh` — thin entry point: mode/path/version config, then `source`s the
  modules in `scripts/setup/` (`common` → `ui_menu`/`bin`/`hermes_tools`/`fix`/
  `rc`/`doctor`/installers/`cleanup` → `cli`). All wiring helpers resolve via
  `$SCRIPT_DIR`, so every module and `setup/` must sit beside `setup.sh`.
  It is idempotent toolchain/env provisioning (node/uv/python pins, LD
  paths, rc chain); run it after any recreate. `--doctor` verifies installs +
  wiring read-only (exit 2 = wiring gaps); `--fix` rewrites ALL wiring
  (rc block, userenv, shim, ~/.profile, hermes shell_init_files, libatomic)
  with zero downloads/reinstalls — safe after a $HOME wipe or a partial
  recreate. `--doctor --fix` = report then repair. Re-running `--fix` is a
  byte-identical fixed point.
  Pitfall encoded in the script: `--fix` never execs the `hermes` launcher —
  any subcommand can boot the full source-update cycle (venv sync, npm build,
  GB-scale runtime clone). config.yaml is edited textually + verified instead.
  `--cliproxy` installs CLIProxyAPI (CLI OAuth → API bridge) — see
  `references/cliproxy.md`; `--clean cliproxy` keeps config + OAuth logins.
  `--camofox` installs the **npm-global** Camofox browser
  (`@askjo/camofox-browser` + `camofox-browser-mcp` on PATH, engine in
  `$XDG_CACHE_HOME/camoufox`), applies the Replit lib closure + a GPU-less
  WebGL-skip (auto-detected), and writes a `camofox` launcher — the
  npm-lane alternative to the `start-camofox.sh` git-clone lane. See
  `references/camofox.md` §"npm-global lane".
- `replit_userenv.py` — structural `.replit [userenv]` edits (tomlkit, no regex).
- `start-camofox.sh` — one-command provision + launch of the Camoufox server.
- `camofox.py` — the scraping CLI (open/nav/eval/screenshot, cookie import,
  keep-alive loop). See camofox.md for its env-file contract.
- `generate-closure.sh` / `libpool.sh` — transitive lib closure (per-process) + pool healing (additive-only).
- `camofox_mcp_check.sh` — one-shot MCP health probe (waits for REST, runs a
  real stdio handshake, asserts the 11 `camofox_*` tools; exit 0 = live). Used
  by the `.replit` "camofox mcp" workflow — the adapter itself is stdio-only,
  running it standalone just idles forever.
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
