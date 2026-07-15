---
name: X2 process-split cancelled
description: Splitting bot+backend into separate OS processes was evaluated and cancelled. Documents the reasoning so it is not re-proposed.
---

## Decision
X2 (split bot process from backend process, separate entrypoints) is **cancelled**.

## Why it was proposed
B6: "a frontend CSS change restarts the bot" — if you restart the backend to serve new `frontend/dist`, the bot loses Telegram connections.

## Why it was cancelled
1. **Dev mode** — `Backend (Dev)` and `Frontend (Dev)` workflows already run independently. Bot never starts in dev. Independence already exists at the workflow level.
2. **Prod mode** — `update.py` does a hard git-reset on every `bash start.sh`, then starts everything fresh. Restarting all layers together **is the deployment model**, not a bug. `update.py` exists specifically to pull latest code before starting.
3. **Cost** — splitting would require two Heroku dynos (web + worker), doubling dyno cost, for a problem that does not exist in the current architecture.
4. **Complexity** — separate entrypoints, a MongoDB command-queue for bot↔backend comms, two start scripts — all added complexity with no operational gain.

**How to apply:** If process-splitting is ever re-raised, revisit this file. The answer is still no unless the deployment model changes away from the `update.py` restart-all pattern.
