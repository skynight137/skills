# Camofox session keep-alive — the two reapers

Source of truth for why a long `--tools refresh-page` loop silently ends up
logged out. Verified against `camofox-browser` on this box (Sep 2026).

## The two reapers

Both are `setInterval(..., 60_000)` in `server.js`, so thresholds quantize to
60s and the worst case is `threshold + 60s`.

| reaper | env var | code default | set by `start-camofox.sh` | what it closes | code |
|---|---|---|---|---|---|
| tab | `TAB_INACTIVITY_MS` | `300000` (5min) | `900000` (15min) | the tab only | `server.js:6040`, `lib/config.js:149` |
| session | `SESSION_TIMEOUT_MS` | `600000` (10min) | `1800000` (30min) | the session | `server.js:5978`, `lib/config.js:116` |
| browser | `BROWSER_IDLE_TIMEOUT_MS` | `300000` | **`0` → disabled** | the whole browser | `server.js:698` |

The **browser** timer is the one people wrongly blame: `start-camofox.sh:78`
exports `BROWSER_IDLE_TIMEOUT_MS=0`, and `scheduleBrowserIdleShutdown` returns
early on `BROWSER_IDLE_TIMEOUT_MS <= 0` (`server.js:698`). On this box it is
**never armed**, so `closeSession` does *not* start a 5-minute browser countdown.

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

`start-camofox.sh` exports (override via env):

```bash
export TAB_INACTIVITY_MS="${TAB_INACTIVITY_MS:-900000}"    # 15min
export SESSION_TIMEOUT_MS="${SESSION_TIMEOUT_MS:-1800000}" # 30min
```

Then the loop period only has to stay under 900s. `--interval 240` gives ~2min
margin under the session threshold's 900s worst case.

**Do not** just raise `--interval` under the 5min tab reaper and call it done —
that leaves the session reaper live, which is the one that drops the login.

## Pitfall: the env file re-source can clobber your exports

`start-camofox.sh` loads an env file with `set -a` **after** setting
the defaults. Any `TAB_INACTIVITY_MS` / `SESSION_TIMEOUT_MS` in that file wins.
Candidate order (first existing): `$CAMOFOX_ENV_FILE`, `$CAMOFOX_ROOT/.env`,
`$HERMES_HOME/.env`. Check the file it actually picked:

```bash
for f in "${CAMOFOX_ENV_FILE:-}" "${CAMOFOX_ROOT:-$XDG_DATA_HOME/camofox}/.env" \
         "${HERMES_HOME:-$HOME/.hermes}/.env"; do
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
