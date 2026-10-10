---
name: replit
description: "Replit sandbox toolkit: platform facts ($HOME wiped on recreate, REPL_HOME/XDG/env channels, rc & git persistence), pulling libs from /nix/store (.replit [nix] packages vs replit.nix vs nix-env, transitive LD_LIBRARY_PATH closure), Playwright on Replit's bundled Chromium (no browser download), and the Camoufox anti-detection Firefox server (Cloudflare/Turnstile/WAF sites, cookie persistence, session keep-alive). Use for anything running ON a Replit/Nix workspace."
version: 4.17.0
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
| persist data/env/rc/git, understand what survives a restart, fix env-var plumbing | `references/platform.md` | `setup.sh`, `dot_replit.py` |
| get a system lib that isn't installed (GTK, libatomic, any .so), debug `cannot open shared object file` | `references/nix.md` | `scripts/setup/generate-closure.sh`, `libpool.sh` |
| drive Playwright without downloading a browser (the box ships Chromium) | `references/playwright-chromium.md` | `$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE`, `start-replit-chromium.sh` |
| open bot-hardened sites (Cloudflare/Turnstile/WAF), keep logged-in Firefox sessions alive, **agent browsing on Hermes (camofox MCP — `browser_exec` is broken here)** | `references/camofox.md` | `setup.sh --camofox` (npm lane), `camofox-browser`, `camofox.py` |
| pick the right browser lane (4 exist: Replit Playwright Chromium, Hermes Chrome 145, agent-browser CLI, Camofox) | `references/browser-lanes.md` | `$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE`, `.hermes/tools/chromium-1208`, `agent-browser`, `:9377` |
| tell whether a browser is being detected as a bot; test sites + how to read them | `references/anti-bot-detection.md` | (test pages: sannysoft, CreepJS, BrowserLeaks, NopeCHA) |
| compare every browser lane on this box (versions, loads, webdriver/stealth, WebGL) — full run report | `references/browser-compare-report.md` | `start-replit-chromium.sh`, `resolve-libs.sh`, `launch-hermes-chrome` |
| bridge CLI coding subscriptions (Codex/Claude Code/Antigravity/Gemini CLI/Kimi/xAI) into OpenAI+Claude APIs on the box | `references/cliproxy.md` | `setup.sh --cliproxy` |
| make an HTTPS client (Python, Node, git, uv) trust the Replit proxy without disabling verification | `references/tls-trust.md` | `setup/rc.sh`, `setup/common.sh` (TLS block) |
| expose a service to a browser (declared ports, port-in-URL, HTTP-only router, Tailscale userspace, `[[workflows]]` wiring, hardcoded binds) | `references/exposing-ports.md` | `.replit` `[[ports]]` / `[[workflows]]` |

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
   the full transitive closure (nix.md §3; `scripts/setup/generate-closure.sh`).
4. **npm is behind a package firewall**; pin `--registry=https://registry.npmjs.org/`.
   It can reject a transitive dependency outright (`403 ... Blocked by Security
   Policy` on a CVE-flagged package), and only the *dev* tree pulls the usual
   offender. This shell also exports `NODE_ENV=production`, and npm then silently
   omits devDependencies — `tsc: command not found` is the tell. Prefix installs
   and builds with `env -u NODE_ENV`.
5. **Replit ships a Playwright-managed Chromium** — `$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE`;
   never `playwright install`.

Prefer **`rg`** over `grep` when searching the box or this repo (recursive,
gitignore-aware, far faster); it is on PATH and also staged under
`$HERMES_HOME/tools/ripgrep-*`. Use `grep` only in scripts that must run
without ripgrep.

## Scripts (entry point in `scripts/`, modules in `scripts/setup/`)

- `setup.sh` — thin entry point: mode/path/version config, then `source`s the
  modules in `scripts/setup/` (`common` → `ui_menu`/`bin`/`hermes_tools`/`fix`/
  `rc`/`doctor`/installers/`cleanup` → `cli`). All wiring helpers resolve via
  `$SCRIPT_DIR`, so every module and `setup/` must sit beside `setup.sh`.
  It is idempotent toolchain/env provisioning (node/uv/python pins, LD
  paths, rc chain); run it after any recreate. `--doctor` verifies installs +
  wiring read-only (exit 2 = wiring gaps); `--fix` rewrites ALL wiring
  with zero downloads/reinstalls — safe after a $HOME wipe or a partial
  recreate. `--doctor --fix` = report then repair. Re-running `--fix` is a
  byte-identical fixed point.
  - **Install isolation:** each tool installs in its own step
    (`run_install_step`); one failing tool warns and the run CONTINUES to the
    rest, then lists the failures and exits non-zero. `--all` no longer aborts
    at the first broken installer.
  - **Clean safety:** `--clean` prints a pre-flight list of exactly what will
    be removed; tools that own user data are protected — `hermes` is backed up
    with its own CLI (`hermes backup`, restorable via `hermes import`), the
    archive copied to `$XDG_CONFIG_HOME/hermes/hermes-backup.zip` (OUTSIDE the
    removed dir) first and left intact if the backup fails (manual-zip
    fallback when the CLI is unavailable); ollama models + camofox server state
    are preserved; cliproxy keeps config/OAuth logins. A bare non-interactive
    `--clean` is REFUSED (use `--clean all -y`).
  Pitfall encoded in the script: `--fix` never execs the `hermes` launcher —
  any subcommand can boot the full source-update cycle (venv sync, npm build,
  GB-scale runtime clone). config.yaml is edited with `yq -i` when available
  (awk fallback), then verified. `--cliproxy` installs CLIProxyAPI (its
  `$CLIPROXY_HOME` follows XDG: `$XDG_CONFIG_HOME/cli-proxy`, honoring a
  legacy `$REPL_HOME/cli-proxy`) — see `references/cliproxy.md`;
  `--clean cliproxy` keeps config + OAuth logins.
  `--camofox` installs the **npm-global** Camofox browser
  (`@askjo/camofox-browser` + `camofox-browser-mcp` on PATH, engine in
  `$XDG_CACHE_HOME/camoufox`), applies the Replit lib closure + WebGL
  auto-skip, and writes a runtime env snippet **plus a launcher shim**
  (`$XDG_BIN_HOME/launch-camofox-browser`) for shells that cannot source it
  — workflows, the Run button, MCP/cron children. **A bare `camofox-browser`
  in those shells dies on `libgtk-3.so.0: cannot open shared object file` and
  surfaces as an opaque 500 on cookie import**; use the snippet or the shim.
  See `references/camofox.md` §"npm-global lane".
- `dot_replit.py` — structural `.replit [userenv]` edits (tomlkit, no regex).
  - Verify the pin after every `--fix`: `write_replit_bashrc` needs tomlkit (from `.venv`, `python3`, or `uv`). On a fresh box none of them has tomlkit, so the function prints `python tomlkit not found, write REPLIT_BASHRC manually` and still returns 0. That is a failure: workflow shells then lack the line and break silently. Check with `grep REPLIT_BASHRC $REPL_HOME/.replit`. Install tomlkit into `.venv` before running `setup.sh --fix` on a fresh machine, or add the line by hand under `[userenv.shared]`.
- `camofox.py` — the scraping CLI (open/nav/eval/screenshot, cookie import,
  keep-alive loop). See camofox.md for its env-file contract.
- `scripts/setup/generate-closure.sh` / `libpool.sh` — transitive lib closure (per-process) + pool healing (additive-only).
- `$XDG_BIN_HOME/launch-camofox-browser` — **generated at install** (not a repo
  file): sources the closure `env.sh`, preflights the install, then execs
  `camofox-browser`. The entry point for any shell that cannot inline the
  snippet — `.replit` workflows, the Run button, cron/MCP children.
- `tests/camofox_mcp_check.sh` — one-shot MCP health probe (waits for REST, runs a
  real stdio handshake, asserts the 11 `camofox_*` tools; exit 0 = live). Used
  by the `.replit` "camofox mcp" workflow — the adapter itself is stdio-only,
  running it standalone just idles forever.

## Maintaining this skill (verify, don't trust the edit tool)

- Changes to this skill's repo go on a feature branch in a `.worktrees/<name>` worktree and open a PR for review. Never commit directly to `main`.
- Test against the live target before committing, and commit only after a passing run. Delete throwaway test scripts and key files first, so the PR holds only the fix.
- Never write a silent fallback (`except ImportError: pass`, a default that hides a failed dependency or trust store). Fail with the name of what is missing; a silent pass hid the real TLS cause here.

When one batch touches many files or repeats an `old_string`, VERIFY the effect
on disk before moving on:

- `rg` the new text (a "failed"/"no match" line can be a benign duplicate-key
  retry) and confirm it appears the expected number of times — twice means the
  edit applied twice.
- Pass **absolute** paths: a `cd` from a previous terminal call persists, so a
  relative path can resolve against the wrong directory.
- Trust base after any edit: `bash -n` on every module (the setup.sh syntax gate
  runs the same check), `shellcheck -S warning` on changed files, and re-run the
  module harness.

## Camofox public access

- With `CAMOFOX_ACCESS_KEY` set, every route except `/health` requires `Authorization: Bearer <access key>`. A browser address bar cannot send that header, so `{"error":"Unauthorized"}` in a browser means the gate works. It is not a fault.
- The global gate checks the access key only; `CAMOFOX_API_KEY` gets 401 on `/tabs`. Cookie import is the reverse: `POST /sessions/<u>/cookies` checks the API key only, so the access key gets 403 there. `camofox.py` sends the access key everywhere except cookie import, which uses the API key.
- Removing the access key opens every route to anyone with the URL. Never do that to clear a 401 on a public server.
- A public test goes through the public URL with a header-capable client (`curl` or `camofox.py`). A localhost pass proves the server works, not the proxy path.
- Keep TLS verification on in every client. Diagnose a public failure in this order: `curl -sS https://<domain>:<port>/health` (verified) first, then `curl -sk` (skip verify). If the verified call fails with curl error 60 and the `-k` call returns 200, the server is fine and this client's trust store lacks the Replit proxy root CA (see the bundle rule below); a `502` from the domain means nothing listens on that port. Run the verified call before naming any cause. A client with verification off proves reachability only; never report it as a pass for auth or the tool path.
- curl and Python can trust different stores on the same box. curl reads `/etc/ssl/certs/ca-certificates.crt`, which holds the Replit proxy root; Python's default context has `cafile=None` and only `capath=/etc/ssl/certs`, so the identical URL fails with `CERTIFICATE_VERIFY_FAILED`. Fix it in the client: `ssl.create_default_context(cafile='/etc/ssl/certs/ca-certificates.crt')` and pass `context=` to every `urlopen`. Confirm the root is in that bundle with a verified `curl` (no `-k`) first. certifi's bundle lacks the proxy root, so `certifi.where()` does not fix it. Do not disable verification; `PYTHONHTTPSVERIFY` is not a Python setting and does nothing. The per-client variable table (Node, Python `urllib`/`httpx`/`requests`, git, uv) and the generator fix are in `references/tls-trust.md`.
- Node has the same split, and `NODE_OPTIONS=--use-system-ca` alone is not enough. `NODE_EXTRA_CA_CERTS` overrides the system store, and the Nix bundle it often points at lacks the proxy root. Set `NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt` for the MCP adapter and any `fetch` client, and keep verification on. Confirm with `fetch(url)` in the same environment before running the adapter.
- `camofox.py` prints "not ready" for every probe failure, including certificate errors. To see the real exception, run `camofox.req(None, 'GET', '/health')` with `CAMOFOX_BASE_URL` set; the `_error` field names the cause.
- The Camofox MCP adapter reports every network failure as `camofox error: fetch failed`, which hides the TLS cause. If `tools/list` works but tool calls fail with that text, the adapter's `fetch` cannot verify the proxy, not the server. Fix the client trust store (above), then rerun the tool call.
- Read a Replit secret into a shell variable with `replit secrets exec --keys NAME -- sh -c 'printf %s "$NAME"'`. The `--` form is required; without it the output is empty and looks like a missing key.
- A key copy in `.hermes/.env` can differ from the Replit secret. When `/tabs` returns 401 with a key you believe is correct, compare SHA-256 prefixes of both values (never print them) before blaming the server.
- A public port must appear in `.replit` `[[ports]]` with matching `localPort` and `externalPort`, and the server must bind `0.0.0.0` on that port. The URL always carries the port (`https://$REPLIT_DEV_DOMAIN:<port>/`) — only one port can be the default, so a bare domain hits 80 and 502s when nothing listens there. The router is HTTP(S)-only, so a non-HTTP protocol (sshd, a DB port) cannot be exposed this way at all. Serve a service on a port nothing else owns: two `.replit` workflows sharing a `waitForPort` cannot both bind. Details: `references/exposing-ports.md`.
- Start the server with its env loaded, never with a bare `node server.js` from a shell that has not sourced `$XDG_CONFIG_HOME/camofox/env.sh`. Without it the browser lacks the GTK/X11 library path and fails with `browserType.launch ... libX11-xcb.so.1`; every tab call then returns `503 browser_launch_timeout`. Load secrets in the same command, e.g. `replit secrets exec --keys CAMOFOX_ACCESS_KEY,CAMOFOX_API_KEY -- sh -c '. $XDG_CONFIG_HOME/camofox/env.sh; node server.js'`, with `CAMOFOX_BIND_HOST=0.0.0.0`, and confirm the port is in `.replit` `[[ports]]`.
- Stop a Camofox server that a `.replit` workflow manages through the workflow in the Replit UI. A `kill` of `node server.js` is undone by the workflow, which relaunches both the server and `camofox-browser-mcp`. Kill by explicit PID only; a `pkill -f` pattern can match the calling shell.
- In a test, a 400 on an empty `/tabs` body means the gate passed. A `503 browser_launch_timeout` is a server-side browser launch failure, separate from auth.
- Separate the gate's status from the target page's status. A gate rejection is the server's own JSON error: `{"error":"Unauthorized"}` (401) or `{"error":"Forbidden"}` (403). A `/tabs` call that passes the gate returns 200, and the target page's status is in the `httpStatus` field (for example 404 or 403 from the site). Read `httpStatus` before blaming auth.
- A cookie-import 403 with the correct client code means the running server's keys differ from the secret. The server reads `CAMOFOX_API_KEY` and `CAMOFOX_ACCESS_KEY` only at startup, so changing a Replit secret does nothing until the server restarts. Compare key lengths (never values) between the secret and the server's environment, then restart the server with the same values and retry.
- A `.replit` workflow runs `camofox.py` from its own path. After a fix merges, pull the clone that path points at; a local clone at an older commit runs the old code and reproduces a fixed bug. Check `git log -1 -- <file>` in that clone before debugging the code.
- `env -i` empties PATH, so a following `timeout python3` fails with `No such file or directory`. Pass the absolute interpreter (`PY=$(command -v python3)`) when running in a clean environment.

## Setup-script env rules (`setup.sh`, `setup/rc.sh`, `setup/common.sh`)

- Export only what the script owns. Replit already provides `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_CACHE_HOME`; re-exporting them adds nothing. `XDG_BIN_HOME` is the one PATH entry the toolchain owns, always `$REPL_HOME/.local/bin`.
- Do not define `XDG_STATE_HOME`. No script reads it, so it is dead config.
- Point `SSL_CERT_DIR` at the system directory (`/etc/ssl/certs`), not `dirname $SYSTEM_CERTIFICATE_PATH`. The Nix store directory has no proxy root, so it disagrees with `SSL_CERT_FILE` (the system bundle).
- Generated `hermes` aliases must call `$XDG_BIN_HOME/hermes`, not bare `hermes`, so they resolve to the managed binary.
- Verify generated rc output before committing: call the emitter directly (`emit_managed_block` with `REPLIT_MODE=true`), `bash -n` the output, grep for the removed names, then source the output in a clean shell and run each alias. A text check passes an alias that cannot run.
- Double-quote any alias whose body uses a variable, so the variable expands at definition: `alias hu="$XDG_BIN_HOME/hermes update --force"`. Single quotes keep `$XDG_BIN_HOME` literal, and the alias then fails when called. In a quoted heredoc (`<<'EOF'`) write `$VAR` bare; a backslash is written into the file as-is.
- Test an alias from a sourced file, not on the line that sources it: bash parses the file's aliases only after that line. Run `shopt -s expand_aliases`, then `source rc.sh`, then the alias on its own line.
- Registry settings in the emitted block are plain exports, not `${VAR:-default}`, so the public registries win over a firewall value set earlier. `PIP_TRUSTED_HOST` is also a plain export.
- `--fix` runs the `setup/` code of the checkout it is launched from. Run it from the branch under test. A `main` checkout re-emits the old block, so the live `.config/bashrc` will not show a fix that is still in review.

## Camofox tuning

There is no env-file template to ship — **the interface is exported vars**
(`CAMOFOX_PORT`, `CAMOFOX_ACCESS_KEY`, `TAB_INACTIVITY_MS`, ...), read from the
shell (or exported before `camofox-browser`):

```bash
CAMOFOX_PORT=9000 CAMOFOX_ACCESS_KEY="$(openssl rand -hex 32)" camofox
```

The Camofox tunables (with defaults) are documented in `references/camofox.md`.

## Installing this skill pack

One skill, one command:

```bash
npx -y skills add skynight137/skills -s replit
```
