---
name: migrate command usage
description: /migrate -n takes the NEW (destination) node_id, not the old one; must run before swapping BOT_TOKEN.
---

## Rule
`/migrate -n <new_node_id>` — the `-n` argument is the **destination** node ID (the first integer in the new BOT_TOKEN).

**Why:** Inside `migrate.py`, `old_node_id = get_node_id()` (the current active value) and `new_node_id = -n argument`. Plans rename docs from `canonical:old → canonical:new`. For this to go in the right direction (old → new), the command must be run **while the OLD BOT_TOKEN is still active** so `get_node_id()` equals the old value.

If you run it AFTER swapping BOT_TOKEN, `get_node_id()` is already the new value and the rename goes in reverse.

**How to apply:**
- Correct workflow: (1) keep old token, (2) `/migrate -n <new_node_id>`, (3) confirm yes, (4) swap token and restart.
- The help text (`HELP_MIGRATE` in `bot/utils/help_messages/services.py`) and the module docstring (`bot/modules/system/migrate.py`) now describe this correctly after the fix.
- The old docs incorrectly said "Old node ID" for the `-n` flag — it is actually the **new** node ID.
