# Camofox session keep-alive — the two reapers

Source of truth for why a long-held `--tools open-page` tab silently ends up
logged out. Verified against `camofox-browser` on this box (Sep 2026).
(The tool was named `refresh-page` until 2026-11-06; the refresh loop
it ran turned out not to be the keep-alive mechanism — the caller's
open cadence is. See the cadence note in references/camofox.md.)

## Which engine runs the tour — measured comparison (2026-11-06)

The keep-alive mechanism is the **open cadence** (round = stops ×
(dwell + gap) must fit inside the target platform's idle tolerance),
and it is engine-agnostic: anything that can open the project
logged-in, hold it for the dwell and close can run a tour. Three
engines were measured on the same open-only job, same RSS method
per row:

| engine | cost while a stop is held | idle cost | Cloudflare passage | verdict |
|---|---|---|---|---|
| **Lightpanda 1.0.3** (`scripts/tour.py --browser lightpanda`, references/lightpanda.md) | ~370–391 MB total (one process, RSS≈PSS) | **zero** — one fresh `serve` per stop, torn down after | interstitial clears by itself in ~7–18 s; 4/4 SHELL in the live tour trial | **proven for the open-only job** — the cheap lane |
| **Camofox** (`scripts/tour.py --browser camofox`; measured in the `camofox.py --tools open-page` era — same server, same per-tab cost) | 550–650 MB per tab **plus** the resident server | ~174–200 MB resident server, always on | the anti-detection Firefox lane; passes what the others cannot | **production engine** — the proven, heavy one |
| Playwright + bundled Chromium | ~1.9–2.1 GB RSS per tab (≈3× a camofox tab like-for-like) | zero | fresh profile 0/7 reached Replit; persistent profile passed once, then stalled repeatedly despite a stored `cf_clearance`; headless blocked outright | **falsified on both axes** — cost and edge; not a tour engine |

Everything below this section (the two reapers, the persistence
plugin, the silent-reopen trap) is **Camofox-specific**: Lightpanda
holds no session state between stops at all — each stop is a fresh
server and a fresh page, kept alive only by the next round's open.

**A rendered shell is not a booted workspace (2026-11-07).** A stop
can log SHELL — page rendered, markers present, post-hold still
shell — while the workspace never starts and the node stays
offline in the netmap: Replit parks blocking dialogs on the page
(the "Keep using Replit?" session dialog, the Starter-limit
upsell), and the workspace boots only once they are closed
(user-verified in a real browser: close the popup, the workspace
boots). Both engines now dismiss popups during the stop (whitelist
controls only — see references/lightpanda.md item 8); the signals
are the stop summary's `popups_dismissed=<n>` and the `popup-wall:`
WARN when a dialog survives every attempt. Judge a wake by the
netmap, never by SHELL alone.

## Failure triage: opaque 500 on `POST /sessions/:userId/cookies`

The client reports `import failed: {'_http_error': 500, '_body': '{"error":"Internal server error"}'}`
(the camofox.py-era wording; the tour's engine logs the same failure as a FATAL cookie-import line)
whenever the server's 500 handler runs with `NODE_ENV=production`: `safeError()`
(server.js) logs the REAL message to the server's stdout and returns the generic
string. The client is innocent — always read the server log first:

```bash
PID=$(pgrep -f 'node server.js' | head -1); ls -l /proc/$PID/fd/1   # where the real error went
grep '"level":"error"' <that file> | tail
```

Two verified causes of that 500 on this box (Sep 2026):

1. **`LD_LIBRARY_PATH` clobbering.** `.replit [userenv.shared]` pins
   `LD_LIBRARY_PATH=/home/runner/workspace/.local/lib`, and `setup.sh --camofox`
   only sets the GTK closure `if [[ -z "${LD_LIBRARY_PATH:-}" ]]` — so the server
   launches WITHOUT gtk-3. Camoufox dies with
   `XPCOMGlueLoad error ... libgtk-3.so.0: cannot open shared object file`, the
   lazy launch fails, and every session-creating call (incl. cookie import)
   returns the masked 500 (classified `browser_launch_timeout`). Fix (v4.6.0):
   setup.sh --camofox APPENDS the closure to any pre-set `LD_LIBRARY_PATH`
   (per-dir idempotent), so the server process always carries the GTK stack
   regardless of what the pinned pool contains. (An earlier layer (a) —
   libpool.sh symlinking the whole closure host-wide — was REMOVED:
   LD_LIBRARY_PATH outranks RUNPATH, so pooled openssl-3.4.1/libcurl-8.14
   copies shadowed the platform builds and broke curl with
   `version OPENSSL_3.5.0 not found`; the pool is strictly additive now —
   staged libatomic only. See libpool.sh header.)

   ⚠ **The append only helps a shell setup.sh itself launched.** If you start
   the server by typing `camofox-browser` in a shell that did not source
   `env.sh`, the append never happens and this exact failure returns. The
   `.replit` **"camofox browser"** workflow used to do precisely that — a
   workflow task is non-interactive, so it carried only the pinned pool and
   Firefox died on every launch (6 consecutive `rp` runs, 2026-10-06). Its task
   now sources the snippet inline; `setup.sh --fix` also writes
   `$XDG_BIN_HOME/launch-camofox-browser` for any other non-interactive
   consumer. **Never run a bare `camofox-browser` from a workflow/Run-button/
   cron shell** — source the snippet or use the shim. `--doctor` gates on both.
2. **Missing `camofox/.env`.** Cookie import is key-gated: with no
   `CAMOFOX_API_KEY` in the SERVER env it answers 403 in production (not 500) —
   write `$XDG_CONFIG_HOME/camofox/.env` with the secret from
   `/run/replit/env/latest.json` (chmod 600) so both server and client
   find it without relying on platform env.

Also note: this repl's workflow server runs on **`:9000`** (workflow env
`CAMOFOX_PORT`), not the `:9377` default — clients dial `CAMOFOX_BASE_URL`,
and a shell without it (or a probe hardcoding
9377) gets connection refused, which the client reports as `_error`, not
`_http_error`.

## The two reapers

Both are `setInterval(..., 60_000)` in `server.js`, so thresholds quantize to
60s and the worst case is `threshold + 60s`.

| reaper | env var | value (package default — setup sets none of these) | what it closes | code |
|---|---|---|---|---|
| tab | `TAB_INACTIVITY_MS` | `300000` (5min) | the tab only | `server.js:6040`, `lib/config.js:149` |
| session | `SESSION_TIMEOUT_MS` | `600000` (10min) | the session | `server.js:5978`, `lib/config.js:116` |
| browser | `BROWSER_IDLE_TIMEOUT_MS` | `300000` (5min) | the whole browser | `server.js:698` |

The **browser** timer is the one people wrongly blame for tabs dying under a
live session: it is armed (package default), but `scheduleBrowserIdleShutdown`
only counts down while `sessions.size === 0` (`server.js:698`) — with any
session alive it never fires. A tab that dies mid-loop is the tab/session
reaper or the health probe, not this timer.

## Why the session reaper is the real hazard

A tab reap does **not** stop at the tab. Once `session.tabGroups.size === 0`
the session reaper closes the whole session (`server.js:6071`), and
`closeSession` calls:

```js
await session.context.close().catch(() => {});   // server.js:~1327
```

The context comes from `b.newContext(contextOptions)` (`server.js:1402`) —
**non-persistent**, no `userDataDir`/`launchPersistentContext`. Closing it
discards the in-memory cookie jar.

**But the login is not gone** — the `persistence` plugin restores it. It
checkpoints `storageState()` to `<profileDir>/<sha256(userId)>/storage-state.json`
on cookie import, session close and shutdown (`plugins/persistence/index.js:139`
/`:155`/`:171`), and re-applies it on the next `session:creating` by mutating
`contextOptions.storageState` (`:109-116`). Verified live — `restoring persisted
storage state` on every fresh boot, and `storage state persisted` with
`reason: cookie_import` after each import. So a reap costs you a re-navigate,
not a logout.

## Why it fails silently

The client's recovery path reopens the tab and keeps printing success:

```python
rr = req(key, "POST", f"/tabs/{tab}/refresh", {"userId": user})
if "_http_error" in rr or "_error" in rr:
    r = req(key, "POST", "/tabs", {...})      # reopen
    tab = r.get("tabId", "")
    print("reopened tab", tab[:8])             # looks fine...
else:
    print(f"refresh ok @ ...")                 # ...and this looks fine too
```

A reaped tab gives refresh a 404 → the client reopens the URL **logged out**.
Both branches print a healthy line, so the failure is invisible in logs.

## What resets the counters

Only a request that *touches the session*:

- `POST /tabs/{tabId}/refresh` bumps **both** `tabState.toolCalls`
  (`server.js:4892`) and `session.lastAccess` (`server.js:4889`).
- **`screenshot` bumps neither** — there is no `toolCalls++` in the screenshot
  handler (`server.js:5248`–`5266`). A screenshot-only loop does **not** keep a
  tab alive, and a `--screenshot` loop without refresh will be reaped.

## Correct configuration

**None — the package defaults rule** (operator decision, 2026-11-06).
`setup.sh --camofox` deliberately does NOT export any of the reaper vars;
`env.sh` carries only port/path exports (`PORT`, the `CAMOFOX_*_DIR` family,
`LD_LIBRARY_PATH`). Earlier revisions of this doc claimed setup applied
900000/1800000/0 overrides — it never did in the shipped code, and the live
servers run the defaults: tab `300000`, session `600000`, browser idle
`300000`. If you want a different value, set it in the server's env yourself;
the tunables are documented in references/camofox.md.

The binding constraint for a tab HELD open is therefore the **tab**
threshold: a session-touching request must land at least every 300s, or
the tab is reaped, then the session, after which the login survives
only via the persistence plugin's restore. There is no client
`--interval` anymore (removed 2026-11-06 with the refresh loop): a
caller either touches a held tab inside that window itself, or — the
fleet-tour pattern — never holds a tab anywhere near that long and
instead re-opens on a round, where the binding clock is the TARGET
platform's idle tolerance, not this reaper.

**Do not** hold a tab and assume it stays alive — a reaped tab empties
the session, the session reaper follows, and the context (with its
in-memory cookie jar) is closed.

## Pitfall: an env file is where an override would hide

Setup sets no reaper defaults, so if a box behaves as if a reaper were
tuned, the value came from the env file the server loads at boot
(`set -a`; first existing wins) or from the platform/workflow env — check
those before believing the defaults are in force. Candidate order:
`$CAMOFOX_ENV_FILE`, `$XDG_CONFIG_HOME/camofox/.env`, `$CAMOFOX_ROOT/.env`.
Check the file it actually picked:

```bash
for f in "${CAMOFOX_ENV_FILE:-}" "${CAMOFOX_ROOT:-${REPL_HOME:-$HOME}/camofox}/.env"; do
    [[ -f "$f" ]] && { echo "using $f"; grep -nE 'TAB_INACTIVITY|SESSION_TIMEOUT' "$f"; break; }
done
```

## How to verify it actually works

**Verify by tab identity, not by screenshot freshness.** Screenshots keep
updating while a tab is being reaped and reopened, so freshness proves nothing.

```bash
# sample several cycles apart; tabId MUST stay constant
curl -s "http://127.0.0.1:9377/tabs?userId=U" \
  | python3 -c "import json,sys; [print(t['listItemId'], t['tabId'][:8], t['title'][:30]) for t in json.load(sys.stdin)['tabs']]"
```

A reap+reopen silently changes `tabId`. Also confirm `title` is the real page
title (e.g. `OmBo - Replit`) and not a login page.

Live env check on a running server:

```bash
PID=$(pgrep -f 'node server.js' | head -1)
tr '\0' '\n' < /proc/$PID/environ | grep -E 'TAB_INACTIVITY|SESSION_TIMEOUT'
```

## Gotchas when restarting

- Cookies **are** persisted (`storage-state.json`, restored on `session:creating`)
  — but **restarting camofox still costs you a re-import** in practice: the
  browser is killed mid-flight, so in-flight checkpoints can be lost
  (`failed to persist storage state` on SIGTERM is common). Pass
  `--cookies <jar.json>` so the loop re-imports on start and heals.
- Replit does **not** auto-restart workflow tasks. Killing a task leaves it dead
  — press **Run** (or restart the workflow) to bring it back.
- `pgrep -f 'camofox-browser/server.js'` **matches your own command line** and
  can return the wrong pid. Prefer `ps -eo pid,args | grep 'node server.js'`.
