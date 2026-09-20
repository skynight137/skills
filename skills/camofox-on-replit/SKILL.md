---
name: camofox-on-replit
description: "One-command anti-detection Firefox scraping server (Camoufox) on a Replit/Nix sandbox. Use when you need to open/verify bot-hardened sites (Cloudflare/Turnstile/WAF-protected, DuckDuckGo, etc.) that plain Chromium can't pass, or when the user wants a persistent headed-Firefox session with CDP. Provisions libs and launches everything in a single script."
version: 3.2.0
license: MIT
platforms: [linux]
compatibility: "Node >= 18 + nix on a Replit sandbox. GTK3/ALSA/X11 libs must EXIST in /nix/store — via replit.nix (recommended), nix-env, or a warm store from a prior build. Gate: R=\"$(nix eval --raw nixpkgs#gtk3 2>/dev/null)\"; [ -e \"$R/lib/libgtk-3.so.0\" ] && echo warm  (~10s; never glob /nix/store/*/lib/* on this box)"
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

## Pick the cheapest lane first

Four ways to fetch web content here, cheapest first. Reach for Camofox only
when the lanes above it are *actually* blocked — it costs a cold browser
launch (~20s, sometimes 60-90s).

| Lane | Use for | Cost |
|------|---------|------|
| `web_search` | finding URLs / answering a question | no browser |
| `web_extract(url)` | reading a page you already have the URL for | no browser, markdown |
| `browser_exec` | clicking, typing, JS, logins on ordinary sites | one Chromium tab |
| **Camofox `:9377`** | **the above returned a bot wall** | ~20s cold launch |

Recognize a block by its signature, not by "the page was empty": under
`browser_exec` a WAF-blocked page shows a placeholder title (an emoji-prefixed
hostname) with `document.body.innerText` at **length 0** — that is a block
page, not an empty document. Through Camofox the *same URL* returns the real
document, so treat "short/empty body on a site that should have text" as the
trigger to escalate a lane.

### Measured: search/extract backend vs Camofox (Sep 2026, this box)

The backend behind `web_search`/`web_extract` decides whether a WAF even
matters — **a keyed Firecrawl or keyless Exa often passes Cloudflare on its
own, so Camofox is not always the escalation.** Verified against the same
URLs, same session:

| Target | Firecrawl (keyed) | Exa (keyless) | Camofox | `browser_exec` |
|---|---|---|---|---|
| example.com | ✅ 167 B | ✅ 178 B | ✅ 129 B | ✅ |
| **g2.com** (Cloudflare) | ✅ **8.3 KB real** | ✅ 3.1 KB real | ✅ 4.9 KB real | ❌ `🐴` 0 B |
| **glassdoor.com** (CF+Turnstile) | ✅ **8.4 KB real** | ✅ 3.1 KB real | ❌ challenge page, 777 B | ❌ |
| news.ycombinator.com | ✅ 15 KB | ✅ 3 KB | — | ✅ |
| type/click/submit a form | ❌ | ❌ | ✅ | ✅ |

Read the two rows that disagree:

- **`web_extract` does NOT reliably return the challenge page.** With a keyed
  backend it returned full real content on *both* Cloudflare sites — beating
  Camofox on Glassdoor, which Camofox only got as `Just a moment...`. The
  earlier "silently returns the challenge page" claim holds for *keyless*
  backends under throttling, not for keyed ones. **Check length AND look for
  challenge markers (`Just a moment`, `Humans only`, `Enable JavaScript`)
  before trusting either lane.**
- **Camofox's unique card is interaction, not fetching.** It is the only lane
  that types and submits (`POST /tabs/<id>/type` + `/press`), and the only one
  that keeps a real session. If the task is "read a page", a keyed
  search/extract backend is cheaper and often more successful; escalate to
  Camofox when you must *drive* the page or when every backend is throttled.

Firecrawl/Exa expose only `search` + `extract` — no crawl/map/batch surface
through Hermes' tools.

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
The browser can also **restart out from under a live session** — the 60s active
health probe (`server.js:6978`) fails, calls `restartBrowser`, and
`closeAllSessions` + `closeBrowserFully` kill in-flight requests. Old tabIds die
with each restart; create a fresh tab. `BROWSER_IDLE_TIMEOUT_MS=0` (the script's
default) disables the *idle* path, so a restart always means the probe — see
*Frozen vs dead browser* under Troubleshooting.

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
   has GTK. Gate before anything else — resolve the store path, never glob the
   whole store (a `/nix/store/*/lib/*` glob never finishes on a warm 700k-entry
   store):

   ```bash
   R="$(nix eval --raw nixpkgs#gtk3 2>/dev/null)"; [ -e "$R/lib/libgtk-3.so.0" ] && echo warm
   ```
2. **`$REPLIT_LD_LIBRARY_PATH` alone is never enough.** It holds only the
   top-level lib dirs of the declared packages (24 on this box); Firefox's X11 closure
   (libX11-xcb, libxcb, pango, cairo, … ~100+ dirs) is transitive and
   lives in stores the Replit loader never searches. That's what
   `generate-closure.sh` builds into `LD_LIBRARY_PATH.txt` — the engine
   loading fine and then dying on `libX11-xcb.so.1: cannot open shared
   object file` is the exact signature of using only those top-level dirs.
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
9377), `CAMOFOX_ACCESS_KEY` (optional auth), `CAMOFOX_ENV_FILE`
(optional env file — see below).

**No agent framework required.** The skill never hard-requires Hermes or any
other tool. An env file is only *optional* convenience for `CAMOFOX_API_KEY`:
both `start-camofox.sh` and `camofox.py` load the first existing of
`$CAMOFOX_ENV_FILE` → `$CAMOFOX_ROOT/.env`, then fall back to the
`CAMOFOX_API_KEY` process env var. No implicit home dirs are searched. No key
at all is fine — it just means unauthenticated mode (only an issue when the
server runs `NODE_ENV=production`, where cookie import then 403s).

Every tunable, with the Camofox default it overrides, is listed in
[`camofox.env.example`](camofox.env.example). Copy it to `$CAMOFOX_ROOT/.env`
(or point `$CAMOFOX_ENV_FILE` at it) and uncomment only what you want to
change — the script's own values are the same recommendations, and commenting
one out there accepts the Camofox default instead.

## Cold store (brand-new container, GTK never installed there)

The generator fails loud at step 2 — before the slow steps. Gate (never glob
`/nix/store/*/lib/*`; it never finishes on a warm 700k-entry store):

```bash
R="$(nix eval --raw nixpkgs#gtk3 2>/dev/null)"; [ -e "$R/lib/libgtk-3.so.0" ] && echo warm
```

If that misses, pick ONE:

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

### Where Replit workflow logs actually go

**Not `/tmp`.** Each workflow run gets a run-id directory under the workspace:

```
<workspace>/.local/state/workflow-logs/<runId>/<workflow>.shell.exec.<taskIdx>
```

`<taskIdx>` is the index of the task inside that workflow (a 2-task workflow
writes `.0` and `.1`). Files are appended live, so `tail -f` works. The
authoritative mapping of a *running* process to its log is the bootstrap's fds —
`ls -l /proc/<bootstrapPid>/fd | grep workflow-logs` — which is immune to
guessing run-ids. `runId` changes on every Run, so old dirs are previous runs'
history; an `<empty>` dir means that task was skipped or never started.

Useful greps:
- `grep -rh "import failed\|timed out" .local/state/workflow-logs/` — client-side failures
- `grep -rh "cookie import failed\|port in use\|has been closed" .local/state/workflow-logs/` — server-side
- `grep -rl "port in use" .local/state/workflow-logs/` — duplicate servers fighting for :9377

| Symptom | Cause | Fix |
|---------|-------|-----|
| `browserConnected:false` after start | lazy launch — normal | POST `/tabs` with `-m 90`; first launch ~60-90s |
| `Tab no longer exists (browser was restarted)` | **not** idle-shutdown (`BROWSER_IDLE_TIMEOUT_MS=0` disables that) — the 60s active health probe failed and called `restartBrowser` → `closeAllSessions` + `closeBrowserFully`, killing in-flight work | re-create the tab; see *Frozen vs dead browser* |
| `POST /sessions/<u>/cookies` never returns (client dies at its own 300s timeout) | browser is **frozen**, not dead — the route awaits `getSession`/`addCookies` (`server.js:473-474`) with no server-side timeout | `pkill -9 -f camoufox-bin` (a *dead* browser 500s instantly), then re-import; see *Frozen vs dead browser* |
| a failed run's log just **stops** at `listening on :9377`, error missing | client `print()`s are block-buffered when stdout is a pipe (no TTY); and `session:created` (`plugins/persistence/index.js:120`) awaits the state restore, so a wedged browser never reaches the route's `req` log line | run the CLI as `python3 -u` (or `PYTHONUNBUFFERED=1`) |
| first `POST /tabs` on a Cloudflare site returns `httpStatus:403` (e.g. g2.com, glassdoor.com) | CF frontdoor challenges the cold profile; the URL may even be rewritten to a `__cf_chl_rt_tk` token | **retry the same sessionKey** — the second attempt usually returns `navigationOk:true` with full content (verified: g2.com 403 → 200 on retry, real reviews loaded) |
| `libgtk-3.so.0: cannot open shared object file` | store is COLD | *Cold store* section |
| `libX11-xcb.so.1: cannot open shared object file` | running with only `$REPLIT_LD_LIBRARY_PATH` (24 dirs on this box) | let the script load `LD_LIBRARY_PATH.txt` (don't hand-export the top-level dirs) |
| `ERESOLVE` / `npm warn` during install | harmless peer warnings | ignore |
| tarball 404s from npm | Replit package-firewall registry | `--registry=https://registry.npmjs.org/` (the script sets this) |
| engine dir suddenly empty | engine version bump → `fetch-bin` re-extracted (it wipes first) | expected; re-run `start-camofox.sh` |
| `CAMOFOX_PORT=NNNN` ignored, server still on the built-in fallback (9377) | the var must reach `node server.js`; `lib/config.js:129` reads `process.env.CAMOFOX_PORT \|\| PORT \|\| '9377'`, so a shell-local assignment is invisible | the script `export`s it (fixed in v3.0.1) — if you set it yourself use `export CAMOFOX_PORT=NNNN` |

### Frozen vs dead browser — the 5-minute stall

`POST /sessions/:userId/cookies` has **no server-side timeout**. `server.js:473-474`
awaits `getSession(userId)` then `session.context.addCookies(...)` unbounded. On a cold
session `getSession` builds a context and restores the storage state (measured
1.5–16s for a 696 KB state). The failure mode is a **frozen** browser, not a dead one:

| Browser state | Import result |
|---|---|
| healthy | 200 in ~0.1–2.3s |
| SIGKILL'd (dead) | 500 immediately — `Target page, context or browser has been closed` |
| SIGSTOP'd (frozen) | **pends forever** — verified still pending at 120s; only the client's own timeout ends it |

Real-use consequence: `scripts/camofox.py:51` uses `urlopen(timeout=300)`, so the client
blocks 5 minutes, `req()` returns `{"_error": ...}`, and `import_cookies()`
(`camofox.py:102-104`) calls `sys.exit(1)` — **the keep-alive loop never starts**.
In the server log this is a `POST /sessions/<u>/cookies` res with `"status":500` and
`"ms"` in the ~316000 range (a 316s request, not a crash).

Cheap triage: `pgrep -f camoufox-bin`, then grep the server log for `restarting browser`
/ `health probe failed`. If those appear, the probe is killing the browser — not the import.

Two server-side contributors worth knowing:
- the probe skips in-flight ops **only while** `timeSinceSuccess < 120000`
  (`server.js:6984`); past 2 minutes it probes anyway (`:6990-6992`) and restarts under
  live work;
- `healthState.lastSuccessfulNav` is refreshed only by the probe itself (`:7001`),
  `restartBrowser` (`:827`) and `:628`/`:790` — never by a successful cookie import,
  tab op or screenshot, so a healthy long-lived session always looks stale.

Ruled out — don't re-chase these: cookie payload validity (all cookies pass
individually *and* as one batch; `__Host-` names are fine), concurrency (2 and 3
simultaneous POSTs to the same user all return 200), and cold start (200 in 1.5s).
If a hand-rolled payload 500s, check that `path` is present — the real client always
sends it (`camofox.py:84-85`) and omitting it is what makes a payload look invalid.

Also: `session empty after tab reaper, closing` fires right after a cookie import
because an import opens no tab — that is benign. Several runs also log
`failed to persist storage state` on SIGTERM (checkpoints in flight when the server is
killed), which is how an import can look "lost" after a restart.

## Cookie import + session keep-alive

Authenticated scraping without ever typing a password: export the site's
cookies to a JSON file (EditThisCookie / browser-dev-tools format: objects
with `name, value, domain, path, expirationDate, httpOnly, secure,
sameSite`), then import them into a Camofox session. All values stay on
disk — never print cookie contents to the chat/terminal.

**One CLI does everything** — `scripts/camofox.py`:

```bash
cd ~/workspace/skynight137-skills/skills/camofox-on-replit

python3 scripts/camofox.py --user list        # list accounts (cookie jars)
python3 scripts/camofox.py --session list      # list live sessions (open tabs)
python3 scripts/camofox.py                     # bare = both summaries

# import (or re-import) cookies into an account
python3 scripts/camofox.py --cookies /path/cookies.json --user rl

# open + keep-alive loop, reusing persisted cookies (no --cookies needed)
python3 scripts/camofox.py --tools refresh-page \
  --url 'https://replit.com/@me/MyProject' --user rl \
  --session live-session --interval 180

# screenshot currently-open tab(s) to PNGs and exit (one-shot, no loop)
python3 scripts/camofox.py --screenshot shots/ --user rl --session live-session
```

- `--wait N` (default 180): polls `GET /health` until the server is up
  before acting. **Required** — `start-camofox.sh` can take minutes (npm
  install + engine fetch + browser boot), and Replit `waitForPort` only
  gates the *provision* task, not parallel consumers, so command-too-early
  → `Errno 111 Connection refused`. Run it even on first shell entry.
- `--env FILE` (optional): read `CAMOFOX_API_KEY` from here. When omitted, the
  CLI picks the first **existing** of `$CAMOFOX_ENV_FILE` then
  `$CAMOFOX_ROOT/.env`; with neither it falls back to the `CAMOFOX_API_KEY`
  process env var. No implicit home dirs, no agent framework. No file and no
  key just means unauthenticated mode (fine unless `NODE_ENV=production`,
  which then 403s). See `camofox.env.example` for a template.
  Python does not expand `$VAR` in strings — resolve with
  `os.environ.get("CAMOFOX_ENV_FILE")`, never a literal `$CAMOFOX_ENV_FILE`.
- `--state DIR` default `$XDG_DATA_HOME/camofox/state`: on-disk data dir
  (cookies/profiles/traces); only list modes read it. Default is already
  right — leave it alone unless you moved the server's state manually.
- Full flag set: `--cookies --user --session --tools --url --interval` +
  `--screenshot --full-page --wait --env --state`. `--user list` /
  `--session list` are listing sentinels; a bare invocation prints both.

`--cookies` is optional and only needed to (re)import; **cookies persist
per `--user` on disk** (`state/profiles/<sha256(userId)>/storage-state.json`,
real userId recorded in the sibling `meta.json`) and auto-reload across
restarts, so one import per account is enough.

- Endpoint: `POST /sessions/{userId}/cookies` with `{"cookies":[...]}`.
- **`NODE_ENV=production` disables loopback import without a key** — set
  `CAMOFOX_API_KEY` in the env; the CLI sends `Authorization: Bearer <key>`.
  403 means the *server* started without the key (`start-camofox.sh` loads an
  env file on boot — `$CAMOFOX_ENV_FILE`, then `$CAMOFOX_ROOT/.env`, first
  existing wins — to prevent this).
- `__Host-` cookies are host-only (no domain in the export) but the
  validator hard-requires `domain`; pass the site domain anyway (e.g.
  `replit.com`) — the browser accepts them.

**Keep-alive** — the reapers (all `setInterval(..., 60_000)`, so thresholds
quantize to 60s and worst case is `threshold + 60s`):

| reaper | env | code default | `start-camofox.sh` | closes | evidence |
|---|---|---|---|---|---|
| tab | `TAB_INACTIVITY_MS` | 300000 (5min) | 900000 (15min) | tab only | `server.js:6040`, `lib/config.js:149` |
| session | `SESSION_TIMEOUT_MS` | 600000 (10min) | 1800000 (30min) | session → `context.close()` | `server.js:5978`, `lib/config.js:116` |
| browser | `BROWSER_IDLE_TIMEOUT_MS` | 300000 | **0 → disabled** | whole browser, only when `sessions.size === 0` | `server.js:698` |

The browser timer is **never armed on this box** — the script exports `0` and
`server.js:698` returns early on `<= 0`. Don't blame it for restarts.

Only a request that *touches the session* resets both — `POST /tabs/{tabId}/refresh`
bumps `tabState.toolCalls` **and** `session.lastAccess` (`server.js:4892`/`:4889`).
**`screenshot` bumps neither** (no `toolCalls++` between `server.js:5248`–`5266`),
so a screenshot-only loop does NOT keep a tab alive.

**The session reaper is the real hazard, not the tab one.** A tab reap empties
the session (`server.js:6071`); the session reaper then closes it. **Cookies
survive this** — the `persistence` plugin checkpoints `storageState()` to
`<profileDir>/<sha256(userId)>/storage-state.json` on cookie import, session
close and shutdown (`plugins/persistence/index.js:139`/`:155`), and restores it
on the next `session:creating` (`:109`). Verified live: `restoring persisted
storage state` on every fresh server boot.

So the failure mode is **not** a silent logout. It is a **race on browser
liveness**: the plugin restores state *into a new context*, and if the browser
is dead or frozen, the import fails — see *Frozen vs dead browser* for the two
distinct shapes (dead → instant `Target page, context or browser has been
closed`; frozen → the request pends with no server-side timeout).

**Do not blame the idle timers on this setup.** `start-camofox.sh:78` exports
`BROWSER_IDLE_TIMEOUT_MS=0`, and `scheduleBrowserIdleShutdown` returns early on
`BROWSER_IDLE_TIMEOUT_MS <= 0` (`server.js:698`) — so the browser idle timer is
**never armed here**, and `closeSession` does *not* hand the browser to a
countdown. The timers that remain live are the tab and session ones:

| timer | env | code default | set by `start-camofox.sh` | effect |
|---|---|---|---|---|
| browser | `BROWSER_IDLE_TIMEOUT_MS` | 300000 | **0 → disabled** | closes the whole browser; only armed when `sessions.size === 0` (`server.js:698`) |
| session | `SESSION_TIMEOUT_MS` | 600000 | 1800000 | closes the session; `0` genuinely disables (`server.js:5978`) |
| tab | `TAB_INACTIVITY_MS` | 300000 | 900000 | reaps the tab only |

The `health probe failed` in that symptom line is **not** an idle timer firing —
it is the 60s active probe (`server.js:6978`) failing and calling
`restartBrowser` → `closeAllSessions` + `closeBrowserFully`, which kills
in-flight requests. A restart under a live loop is always the probe.

`start-camofox.sh` applies `TAB_INACTIVITY_MS=900000` and
`SESSION_TIMEOUT_MS=1800000` as **overrides of Camofox's own defaults** (300000
and 600000). Re-checked after the env-file load — `$CAMOFOX_ENV_FILE` then
`$CAMOFOX_ROOT/.env`, first existing wins — which can clobber them. With those
set, the
loop period just needs to stay comfortably under 900s. Use `--tools refresh-page`
with **`--interval 240`**. Cron is the wrong tool (1/min floor + fresh process
each tick); a long-running loop is right.

Verify it is actually working by **tab identity, not freshness**: screenshots
keep updating even while the tab is being reaped and reopened. Sample
`GET /tabs?userId=U` and confirm `tabId` is unchanged across several cycles —
a reap+reopen changes it.

### Screenshot

`--screenshot DIR` captures the **currently-open** tab(s) and exits — it does
not open a URL. Naming: `<user>__<session>[_n].png`. Without `--session` it
shots every live tab for that user (indexed `_0`... when >1).

- Endpoint `GET /tabs/{tabId}/screenshot?userId=X&fullPage=true` returns
  **raw PNG bytes, not JSON** — read it as binary, never `json.loads`.
- `--full-page` defaults on; `--no-full-page` for viewport-only (faster on
  lazy-rendered pages).

**`--screenshot` + `--tools refresh-page` compose** into a keep-alive loop
that also snapshots each cycle (this is what the `.replit` "alive" workflow
uses). They are NOT mutually exclusive — combined, they run the loop and
screenshot on every tick, overwriting the same file (no disk growth):

```
t=0      open (page loads) → screenshot
t=180    screenshot (settled page) → refresh
t=360    screenshot → refresh ...
```

Screenshot runs **before** the refresh in each cycle, so it captures the
fully-loaded page from the previous reload, not a half-loaded one. `--screenshot`
alone (no `--tools`) stays one-shot + exit.

- Order matters: screenshot-before-refresh = shoot the settled page.
  Screenshot-after-refresh would catch the page mid-reload.
- `--tools <name>` requires `--url`; missing it exits 1 with a clear message.
- The loop reopens the tab automatically (same `--session`) if a refresh
  fails and the tab was reaped, so it self-heals across long runs.

### Output conventions

List output is column-aligned with a gap between every field (`USER` 12,
`SESSION` 20, numbers right-aligned, fixed `   ` before `DOMAINS`). Keep
header and row format strings identical when editing — mismatched widths are
the usual cause of the columns running together.

### `--session` vs `--user`

- **`--user`** = account/identity: own cookie jar + own
  `state/profiles/<hash>/` dir. Separate accounts by `--user`; their
  cookies never mix.
- **`--session`** = a label for a *group of tabs* inside one user (API
  `listItemId`). Carries no auth. Same `--session` on re-open reattaches to
  the group; `DELETE /tabs/group/:listItemId` clears the whole group.
- Same user, **different URL** → give each loop its own `--session` (and
  its own process); same `--session` reattaches instead of opening a new tab.

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
- `scripts/camofox.py` — unified cookie-import / list / keep-alive CLI.

Nix/closure depth (cold store, T-matrix, loader mechanics): the
`replit-nix` skill.
