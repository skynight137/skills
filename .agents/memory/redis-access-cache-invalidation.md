---
name: Redis access cache invalidation sites
description: Where and how to call access_cache.invalidate/invalidate_many when bot permissions change, and the get_chat_members limit=0 convention.
---

## Rule

When multiple users are affected by one permission mutation, use `access_cache.invalidate_many(client_id, user_ids)` — it issues one pipelined Redis DEL for all keys instead of N parallel round-trips.
Use `access_cache.invalidate(client_id, user_id)` only for single-user eviction.

Both methods evict the Redis 10-second TTL cache so the next command sees the new role/blacklist state immediately.

**Why:** `check_user_access` in `role.py` caches approved access levels (dev/owner/sudo/auth) in Redis for 10 seconds to absorb burst commands. Without invalidation, a newly blacklisted user can still pass the cache check for up to 10 seconds after being blocked.

**How to apply:**
- The canonical call site is `_chat_permissions()` in `bot/modules/admin/chat_permission.py`, which handles all user-level permission mutations (`addsu`, `rmsu`, `bl`, `ubl`, `blg`, `ublg`).
- Pattern: collect `_invalidate_user_ids` during the mutation loop, then call `await access_cache.invalidate_many(client_id, _invalidate_user_ids)` after the loop. The helper silently no-ops on empty list.
- Import: `from utils.redis_peer_cache import access_cache`
- Do NOT use `asyncio.gather` + `access_cache.invalidate` in a loop — use `access_cache.invalidate_many` instead.
- Chat-based auth mutations (`auth`/`unauth`) cannot be invalidated by user_id — the 10s TTL is acceptable there.
- Rejections (None) are never cached by design, so blacklist enforcement is always immediate for users not yet in the cache.

## get_chat_members limit semantics (critical)

`limit` in `get_chat_members` is the **total cap on members returned**, NOT the page/chunk size.

```python
total = abs(limit) or (1 << 31) - 1   # limit=0 → unlimited
limit = min(200, total)                # internal chunk always ≤ 200 automatically
```

- `limit=0` (default) → fetches ALL members in automatic chunks of up to 200.
- `limit=200` → only returns the FIRST 200 members total — breaks Chat Cloner `-dc members` and kick-all flows.

**Rule:** Use the default `limit=0` wherever all members must be iterated. Never pass `limit=200` to "optimise" — the internal chunking is already done for you.
