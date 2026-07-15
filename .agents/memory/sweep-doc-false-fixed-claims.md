---
name: Sweep doc false "Fixed" claims
description: How the N-30 sweep finding was marked Fixed without the code ever landing, and how to catch this before trusting a sweep doc.
---

## What happened

`docs/superpowers/sweep-2026-07-08.md` marked N-30 ("no startup deadline for
daemon processes") as `✅ Fixed`, describing a `_startup_timeout` property on
`BaseService` plus `asyncio.wait_for(...)` wrapping around `_start_daemon()` /
`_start_client()` in `start()`. That code does not exist anywhere in
`bot/service/base.py` — the claim was false (either a hallucinated summary or
a fix that was reverted/never committed).

Investigation showed the underlying concern is already handled differently:
`database/models/base.py` defines a per-service `daemon_startup_timeout`
field, and `aria2.py`, `qbittorrent.py`, and `webserver.py` each pass it into
their own subprocess/launch calls. So every concrete daemon already enforces
its own startup deadline — a generic base-class wrapper would be redundant
for these and actively wrong for any service whose init legitimately takes
longer than a one-size-fits-all timeout.

**Why:** a sweep doc's `✅ Fixed` status is a claim about a past session's
diff, not a fact about current code. Sessions can hallucinate a fix summary,
or a fix can be reverted/dropped in a later rebase without the doc being
updated.

**How to apply:** before trusting any `✅ Fixed` entry as ground truth (e.g.
before building on top of it, or before telling a user something is handled),
grep for the specific symbol/property/function name named in the fix
description. If it's not there, downgrade the entry to `⏭ Deferred` (or
`❌ Invalid`) with a note on what was found instead, rather than silently
believing the doc.
