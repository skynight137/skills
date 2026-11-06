# Examples — replit skill

Real-world scripts built **on top of** the replit skill's machinery
(`scripts/camofox.py`, the camofox-browser server) — the kind of thing an
operator ends up writing per box: keep-alive loops, sequential tours,
cookie-fed sessions.

**These are not installed with the skill.** The skills installer ships
only the `skills/<name>/` trees; this directory sits outside them on
purpose, as a browsable reference in the repo. Copy a script into your
workspace, adapt the marked placeholders (user id, cookie file, links),
and run it yourself — nothing here is wired into `setup.sh`.

| Script | What it does |
|---|---|
| `refresh-page-keepalive.sh` | Keep ONE page alive: import cookies once, loop `refresh-page` with the upsell dismiss + login checker armed, screenshot per cycle, close the session group on exit. |
| `cfx-refresh-tour.sh` | Keep MANY pages alive on a small box: tour full links one tab at a time (open → short dwell → close → next, back-to-back — one full round fits a single ~5-min survival window, and the host's own link goes first as a self-heal stop), per-link logs and screenshots. This is the pattern that replaced running one IDE tab per project in parallel (≈600 MB each). |

Both assume the server is already running (see the skill's
`references/camofox.md`) and follow its settled rules:

- `--interval 180` — under the package-default tab reaper
  (`TAB_INACTIVITY_MS=300000`, 60s tick) with real margin; 300 races it.
- Site specifics travel as caller data (`--dismiss`, `--fail-text`
  needles); the client stays generic.
- Detail goes to a log file; the console keeps a summary only.
