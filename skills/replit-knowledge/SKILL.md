---
name: replit-knowledge
description: "Replit sandbox platform facts (no Nix): $HOME wiped on recreate, work lives in $REPL_HOME, XDG_*_HOME pre-set by the platform, .replit/.bashrc config, npm package firewall, REPL_* env vars, replit shutdown. Use before persisting data, choosing paths, or debugging wiped-data / npm-404 on Replit."
version: 1.0.0
license: MIT
platforms: [linux]
compatibility: "Replit workspaces (/home/runner containers)."
metadata:
  hermes:
    tags: [Replit, sandbox, persistence, XDG, REPL_HOME, npm, replit-shutdown]
    related_skills: [replit-nix, camofox-on-replit, replit-playwright-chromium]
---

# Replit sandbox: what the platform does to you

Field-verified (2026-09-02/03) — platform facts only. How to actually pull
packages out of `/nix/store` (replit.nix, nix-env, closures) is the
**`replit-nix`** skill.

## 1. What survives a restart (the #1 gotcha)

- `$HOME` (`/home/runner`) is **wiped on container recreate**.
- The **workspace persists** — `$REPL_HOME` (`/home/runner/workspace` on this
  box). That is the default working dir and the only home for durable files.
- `replit shutdown`, wiping `$HOME`, deleting `replit.nix` — none of these
  touch **`/nix/store`** (it persists outside all three, until GC). See
  `replit-nix` for what that means for libs.

Rules:

- Never store persistent data in `$HOME`.
- **XDG is pre-set by the platform** — on Replit, `XDG_*_HOME` point at
  workspace paths (verified: `XDG_DATA_HOME=/home/runner/workspace/.local/share`
  — check with `printenv | grep XDG_`). Don't override them; just use
  `$XDG_DATA_HOME` in your tooling. On non-Replit machines the XDG spec
  defaults (`$HOME/.config` etc.) apply and the same code works — that's why
  scripts should fall back to the *spec* defaults, not hardcoded paths, when
  the vars are unset.
- Tool install dirs (engines, runtimes) belong in `$XDG_DATA_HOME/<tool>/`
  (uv-style): one dir per tool, `rm -rf` one dir to reset. Never scatter tool
  dirs across the workspace root.
- Config for "how to set this up again" belongs in a repo on the workspace
  (this skills repo is one such).

## 2. Working dir & the `REPL_*` env vars

`$REPL_HOME` = the workspace = default cwd. Everything durable goes under it.
The platform injects a large set of `REPL_*` / `REPLIT_*` vars — list them
anytime with:

```bash
printenv | rg 'REPL'
```

The ones that matter:

| Var | Meaning |
|-----|---------|
| `$REPL_HOME` | workspace dir (persisted; default cwd) |
| `$REPL_OWNER` / `$REPL_USER` / `$REPLIT_USER` | account name (all the same) |
| `$REPL_ID` | repl UUID; `$REPL_SLUG` (e.g. `workspace`) |
| `$REPLIT_DOMAINS` / `$REPLIT_DEV_DOMAIN` | public `<repl>.<cluster>.replit.dev` |
| `$REPLIT_BASHRC` | the workspace `.bashrc` actually sourced by shells |
| `$REPLIT_NIX_CHANNEL` | nixpkgs channel this repl builds against (e.g. `stable-25_05`) |
| `$REPLIT_LD_AUDIT` / `$REPLIT_RTLD_LOADER` | the custom dynamic loader (see `replit-nix` §3) |
| `$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE` | store Chromium for Playwright (see `replit-playwright-chromium`) |
| `$REPLIT_RUN_PATH` | `/run/replit` (per-user run state) |

Rest are identity/cluster/p2p tokens — don't echo them into logs.

## 3. Configuration files

- **`.replit`** — TOML. `modules = ["nodejs-24"]` (language runtime),
  `[nix] channel = "stable-25_05"` (the channel `replit.nix` builds
  against), `[userenv.shared] KEY=VALUE` (env for every shell, incl.
  registry pins), `[[ports]] localPort/externalPort` (publishing),
  `entrypoint`, `run`.
- **`replit.nix`** — workspace-root Nix deps; mechanics in `replit-nix`.
- **`.bashrc`** — sourced via `REPLIT_BASHRC` (see `.replit`). Put
  `export`s here for per-shell persistence.

## 4. npm / package managers — the package firewall

The sandbox pins package registries through a **package firewall**
(`NPM_CONFIG_REGISTRY` → `package-firewall.replit.local`, also yarn/pip/go
pins in `[userenv.shared]`). Firewall metadata works but some tarballs 404,
and **env pins beat CLI flags** (`--registry` loses to
`npm_config_registry`). Two verified fixes:

```bash
unset NPM_CONFIG_REGISTRY npm_config_registry; npm install
# or
npm install --registry=https://registry.npmjs.org/
```

pip analog: `PIP_INDEX_URL` is already pinned to pypi.org in
`[userenv.shared]` on this workspace (works as-is); if you hit a firewall
pip mirror, set `PIP_INDEX_URL=https://pypi.org/simple/` explicitly.

## 5. Processes & ports

- `replit shutdown` stops the container; the workspace survives, `$HOME`
  does not, `/nix/store` does not change.
- Daemons: run **on demand** (start when needed, kill when done) — no
  always-on background watchers unless the user asks; containers die and
  nothing restarts them.
- `[[ports]]` in `.replit` maps local→external for HTTP publishing; plain
  `curl 127.0.0.1:<port>` works for local verification.

## Quick diagnostic table

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| data/tooling gone after restart | it lived in `$HOME` | §1: move under `$REPL_HOME` + XDG anchors |
| `npm ERR ... 404` on tarballs | package firewall | §4: unset pins or explicit `--registry` |
| "which nix channel is this repl on?" | — | `echo $REPLIT_NIX_CHANNEL` |
| new env var not in shell | set in a stale shell | open a fresh shell (or `.replit` rebuild) |
