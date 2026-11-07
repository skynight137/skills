# Lightpanda — the lightweight CDP engine for keep-alive tours

Lightpanda is a single static headless-browser binary that speaks CDP
(`lightpanda serve`). In this skill it exists for ONE job: the
session keep-alive tour — the unified `scripts/tour.py`, a
SHARED ready-to-run script serving both machine kinds (`--machine muse|repl`,
pinned at the call site; default auto-detect), with
`--browser lightpanda` (the default engine; `--browser camofox` runs
the same tour, same verdicts, against the camofox server) — where a
fleet of Replit workspaces is held inside its idle tolerance by an
open cadence — open a project logged-in, hold the tab for the dwell,
close, next (the mechanism is the cadence, not the engine; see
references/session-keepalive.md for the measured engine comparison).
This reference covers the Lightpanda engine of that tour.

Pick it over Camofox when the job is open-and-hold only: ~380 MB
per stop and **zero idle cost** (no resident server), against
Camofox's 550–650 MB per tab plus a ~174–200 MB resident server.
Pick Camofox when the target fights back (Cloudflare/Turnstile/WAF
fingerprinting, interactive browsing, MCP): it is the anti-detection
Firefox and remains the fleet-proven production engine.

## Install

```bash
bash setup.sh --lightpanda    # alias -lp; NOT part of --all
bash setup.sh --doctor        # probes `lightpanda version` + the tour venv
bash setup.sh --clean lightpanda   # binary + venv go; config + jar stay
```

The lane is explicit-only (like `--llm-wiki`): a tour host opts in.
The installer pins **Lightpanda 1.0.3** (`LIGHTPANDA_VERSION` in
setup.sh). The release publishes **no checksum asset**, so
`setup/lightpanda.sh` carries the per-arch size + SHA256 pins
computed from the official downloads:

| arch | asset | bytes | sha256 |
|---|---|---|---|
| x86_64 | `lightpanda-x86_64-linux` | 77403464 | `53eb34da…82e8b0` |
| aarch64 | `lightpanda-aarch64-linux` | 74485832 | `20a5348b…d78549` |

A download that fails the size or hash check dies before anything is
placed. The pins move with the version: bump `LIGHTPANDA_VERSION`
without refreshing them and the install refuses, loudly, by design.

Probe trap: the binary has **no `--version` flag** (unknown command,
exit 1). The version probe is the subcommand: `lightpanda version`
prints `1.0.3`.

Venv prerequisite: creating the tour venv needs **uv** or a
**venv-capable python3** (one that brings `venv` + `ensurepip`) on
PATH. A fresh Replit join shell has neither — the lane preflights
this and dies *before* downloading anything, naming the remedy: run
`bash setup.sh --uv` first, then re-run `--lightpanda`. (A healthy
existing venv exempts a re-run.) Mind which creator made the venv:
a **uv-created venv ships no pip**, so playwright is installed with
`uv pip install --python <venv python>`; a `python3 -m venv` venv
carries its own pip and uses it. The installer picks by whether the
venv actually has pip.

### Layout — `$LIGHTPANDA_HOME` (`$XDG_CONFIG_HOME/lightpanda`)

| path | what |
|---|---|
| `lightpanda` | the engine binary (symlinked into `$XDG_BIN_HOME`) |
| `venv/` | tour client venv: python + playwright **client library only** (`connect_over_cdp`; no browser download — the engine is the browser), pinned to `LIGHTPANDA_PLAYWRIGHT_VERSION` |
| `.env` | operator tour config (never written by setup) |
| `.env.example` | fill-in template, refreshed by every `--lightpanda` run |
| `cookies.json` | default login jar (`TOUR_COOKIES` overrides; fallback `LP_COOKIES`) |
| `logs/` | per-stop server logs (`lp-server-<project>.log`) |

`--clean lightpanda` removes the binary, the symlink and the venv.
`.env` and the cookie jar are operator data and are **preserved**
(delete `$LIGHTPANDA_HOME` by hand to wipe them) — the same rule as
Camofox server state.

## Tour config

Fleet "big env" rule: a var already set in the **system environment
wins**; `$LIGHTPANDA_HOME/.env` only fills gaps. `tour.py` logs
one `config: <VAR>: from …` line per var at startup — name + source
only — so a run's config is auditable, never silent. The tour's vars
are `TOUR_*`; the lp-tour-era `LP_*` names are honoured as fallbacks
for one release, so existing captain `.env` files keep working
untouched.

| var | default | meaning |
|---|---|---|
| `TOUR_LINKS` (fallback `LP_LINKS`) | — (required) | comma/whitespace-separated project URLs, in stop order. Put the tour's own host FIRST: a pilot that opens itself first heals itself before touring the others |
| `TOUR_MACHINE` | auto-detect | machine kind (`muse`\|`repl`); `--machine` wins over it. Selects the machine-shaped defaults (engine-home XDG base, jar + log-dir defaults); auto-detect mirrors `setup.sh`: REPL_HOME set → repl, else muse |
| `TOUR_COOKIES` (fallback `LP_COOKIES`) | `$LIGHTPANDA_HOME/cookies.json` | login jar (browser-export or Playwright JSON) for an account that can open every link |
| `TOUR_DWELL_S` | 60 | seconds the tab is held per stop |
| `TOUR_GAP_S` | 0 | sleep between stops (tab closed) |
| `TOUR_MAX_EARLY_FAILURES` | 3 | consecutive non-SHELL stops before `*** tour ABORTED` + exit 1; a SHELL stop resets the count; 0 = never |
| `TOUR_POLL_S` (fallback `LP_POLL_S`) | 150 | budget for the shell marker to appear |
| `TOUR_BASE_PORT` (fallback `LP_BASE_PORT`) | 19401 | first CDP port; stop *i* uses base+*i* |
| `TOUR_MAX_ROUNDS` (fallback `LP_MAX_ROUNDS`) | 0 | 0 = tour forever |
| `TOUR_ONLY` (fallback `LP_ONLY`) | — | run only the stop whose last path segment matches |
| `TOUR_JAR_WRITEBACK` (fallback `LP_JAR_WRITEBACK`) | off | `1` = after each SHELL stop, merge the live session's cookies back into the jar (atomic, merge-only, fail-open), so the session keeps what it earns — notably a `cf_clearance` — across stops and rounds instead of re-facing Cloudflare from a static jar. If the engine refuses cookie read-back, it disables itself for that process and the tour carries on |
| `LIGHTPANDA_BIN` | `$LIGHTPANDA_HOME/lightpanda`, then PATH | engine override |

Round time is `len(TOUR_LINKS) × (TOUR_DWELL_S + TOUR_GAP_S)` — the
round must fit inside the target platform's idle tolerance with
margin (see the staged dwell ladder in session-keepalive.md).

## Running it

```bash
bash scripts/tour.sh --browser lightpanda --machine repl --check   # preflight: config sources, binary, jar
bash scripts/tour.sh --browser lightpanda --machine repl           # the tour (stdout = the tour log)
```

`tour.sh` is a justified shim, not a wrapper: it assembles the
env the program cannot assemble for itself — the venv's greenlet
needs `libstdc++.so.6` from the nix store on `LD_LIBRARY_PATH`
**before** python starts (nix boxes only; skipped where no nix
store exists), and it resolves the venv python. All
logic lives in `tour.py`.

For a `.replit` workflow, point the task at `scripts/tour.sh`
with `--browser`/`--machine` pinned in the args, and
redirect stdout to a file under `$REPL_HOME/logs/` (workflow
consoles never stream runtime logs — references/exposing-ports.md);
workflow names and wiring stay the operator's, as with every other
tool in this skill.

## The mechanics (proven — do not improvise around them)

1. **One fresh `lightpanda serve` per stop**, spawned for that stop
   and torn down after it. Zero idle cost is the whole point; a
   resident server throws it away.
2. **Server output goes to a per-stop log FILE, never a pipe.** An
   undrained PIPE wedges the server silently (the first trial's
   240 s hang was this harness bug, not the engine).
3. **Cookies plant ONLY via the native `--cookie` loader**, with
   the jar converted to a CDP cookie array (the loader also accepts
   Netscape format; the tour standardizes on the array). Playwright's
   `Storage.setCookies` fails against Lightpanda with
   `BrowserContextNotLoaded` — CDP cookie planting does not work,
   do not switch to it. The jar is re-converted **every round**, so
   a re-imported jar is picked up without restarting the tour.
4. **Always navigate via `ctx.new_page()`.** The default CDP page is
   a non-navigable STARTUP session; navigating it goes nowhere.
5. **Poll for the shell marker** (`Files` / `Invite` / `Console` /
   `Shell` / `Personal workspace` / the project name, on a
   >200-char body). Cloudflare's interstitial clears **by itself**
   in ~7–18 s; time-to-shell observed 13–25 s. Never click through
   the interstitial.
6. **Verdicts per stop:** `SHELL` / `LOGGED-OUT-WALL` (visible text
   contains both `Log in` and `Sign up`, confirmed by a second probe
   5 s later — the camofox `--fail-text` discipline) / `CF-STALL`
   (poll budget spent on the `Just a moment...` title) / `ERROR` /
   `UNKNOWN`. After a SHELL verdict the tab is held for the full
   dwell and re-probed — `still-shell` is logged, and the engine's
   peak RSS for the stop is sampled from `/proc/<pid>/smaps_rollup`.
7. **Teardown is verified**: leftover `lightpanda serve` processes
   are killed before and after every stop, and a signal to the tour
   kills the live server with it.
8. **Blocking popups are dismissed during the stop** (2026-11-07):
   after the SHELL verdict, before the dwell, and again before the
   post-hold sample, the engine clicks a blocking dialog away —
   ONLY a whitelisted dismiss control (a close/dismiss aria-label
   or title, or an exact `×` / `✕` / `Close` / `Dismiss` /
   `No thanks` / `Not now` / `Maybe later` text); affirmative
   controls (`Upgrade`, `Keep using`, …) are vetoed and never
   clicked. This is load-bearing, not cosmetic: Replit parks the
   "Keep using Replit?" dialog and the Starter-limit upsell on the
   page, and **the workspace does not boot until they are closed**
   — a stop that only opens the page logs SHELL while the node
   stays offline in the netmap. SHELL alone therefore does NOT
   prove a boot; read the stop summary's `popups_dismissed=<n>`,
   and a `popup-wall:` WARN line when a limit/upsell dialog is
   still standing after every dismissal attempt (the tour cannot
   clear it — that is an account-side wall, not a tour failure).

## Evidence and caveats

Measured 2026-11-06 on the jafibaw wing (full write-up in the fleet
notes; comparison table in references/session-keepalive.md):

- Decisive single run (pilot `repl-cfx` → `repl-11`): cookies
  planted via the native loader, page rendered logged-in,
  Cloudflare cleared in ~7 s, time-to-shell 16.6 s, full 60 s hold
  with the shell still up after, footprint one process at
  297–380 MB RSS≈PSS, clean teardown.
- Live tour trial (same pilot, 4 stops, dwell 60 s / gap 0): round 1
  verified **4/4 SHELL**, per-stop RSS peaks 373–391 MB — and the
  user then let the tour run unattended as the wing's keepalive.

Caveats, plainly: the decisive run is **n=1 on one target** and
verification is **marker-level** (the same standard the other lanes
were judged by). Repeat reliability across days and behaviour on
other accounts' fleets were unproven when this lane landed; Camofox
remains the proven production engine, and this lane earns trust the
same way it did — by running.

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `BrowserContextNotLoaded` on cookie work | you planted cookies over CDP — use the native `--cookie` loader (mechanic 3) |
| server starts but never answers, no error | its stdout is an undrained pipe — redirect to a per-stop log file (mechanic 2) |
| navigation silently does nothing | you navigated the default CDP page — `ctx.new_page()` first (mechanic 4) |
| every stop is `LOGGED-OUT-WALL` | the jar is stale/expired — re-export it from the account's browser session and drop it at `TOUR_COOKIES`; the tour picks it up next round |
| `CF-STALL` on one stop | Cloudflare did not clear inside `TOUR_POLL_S` this time; transient stalls happen — the breaker only aborts on *consecutive* failures |
| tour dies at start: `lightpanda binary missing` | run `bash setup.sh --lightpanda` (or `--fix` to restore the symlink) |
| `--lightpanda` dies at start: `neither uv nor a venv-capable python3` | fresh join shell — run `bash setup.sh --uv` first, then re-run `--lightpanda` |
| `No module named pip` inside the tour venv | the venv was created by uv (uv venvs ship no pip) — reinstall via `uv pip install --python <venv>/bin/python playwright==…`, or just re-run `bash setup.sh --lightpanda` (4.34.1+ picks the installer by the venv) |
| venv python dies on `libstdc++.so.6` | you ran `tour.py` directly — run it via `tour.sh`, which assembles `LD_LIBRARY_PATH` |
| `lightpanda --version` exits 1 | by design — the probe is `lightpanda version` |
