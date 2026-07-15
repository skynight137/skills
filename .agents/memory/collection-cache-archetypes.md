---
name: Collection cache archetype mismatches
description: Three confirmed doc/code mismatches for missions, records, tasks — with root causes and correct fixes.
---

## missions — Readme said "Full dict", actual is direct DB

`MissionsCollection` extends `BaseCollection` but has **no `load()` step in startup** and
**no in-memory cache**. All methods (`get`, `get_by_bot`, `get_active_by_bot`, `add`, `update`, `remove`)
hit MongoDB directly. `missions` appears only in the `_index_coros` gather in `startup()` for
`ensure_indexes()` — not in `collections_to_load`.

**Fixed**: Readme now shows "—" for cache and direct-DB note. `db-cache-strategy.md` adds Type 5.

## records + tasks — IndexedCollection with no registered secondary indexes

Both `RecordsCollection` and `TasksCollection` extend `IndexedCollection[T]` but call
`register_index()` zero times. They pay per-write lock + full-dict overhead for no benefit.

**Correct base class**: `BaseCollection` with `max_size=0` (full dict, no index maintenance cost).
The full-dict cache is still needed:
- `records` — hot path in Telegram filters: `cache.get(user_id)` presence check
- `tasks` — write-through during task lifecycle (inserts on start, deletes on complete)

**RecordsCollection — implemented**: only store docs for blacklisted users.
- `ublg` → `delete_one(uid)` (was `update_one(uid, {"blacklisted": False})`).
- Filter check: `user_id in records.cache` (no field read) — in both `role.py` and `service.py`.
- Existing `blacklisted=False` docs in MongoDB may need a one-time cleanup: `db.records.deleteMany({blacklisted: false})`
- `records.cache` is a plain `dict` (IndexedCollection, max_size=0) — `in` check is O(1).

**access_cache ordering fix (role.py)**: blacklist checks (`client.blacklists` + `records.cache`) now run
BEFORE the `access_cache.get()` call, not after. O(1) lookups; correct by construction even if
invalidation is delayed. Cache invalidation in `chat_permission.py` is still present as a belt-and-braces.

**service.py _mstore bug fix**: `return None` → `return False` on global blacklist path (line 93).

## missions — query-result TTL cache implemented

`BaseCollection.Cache(max_size=N)` is an LRU keyed by document `_id` (individual doc cache).
`get_active_by_bot(bot_id)` is a **list query** — BaseCollection LRU gives zero benefit to it.

**Implemented solution** (`database/collections/missions.py`):
```python
self._query_cache: TTLCache = TTLCache(maxsize=500, ttl=60.0)
# Redis L2: key "ml:<bot_id>", TTL 60 s (via get_redis() from utils.redis_peer_cache)
```
Tier: Redis if `REDIS_URL` set, else in-process `TTLCache`. Same exclusive-L2 pattern as peers/access.
Invalidate on `add()`, `update(mission_id, bot_id, **fields)`, `remove(mission_id, bot_id)`.
`bot_id` is now a required arg on `update()` and `remove()` — callers updated in `owner_manage.py`.

LRUCache/TTLCache are now named subclasses of Cache in `utils/lru_cache.py`:
- `LRUCache(maxsize)` — pure LRU, no TTL
- `TTLCache(maxsize, ttl)` — LRU + mandatory TTL (raises if ttl <= 0)
- All existing Cache(maxsize) call sites updated to LRUCache; Cache(maxsize, ttl=T) → TTLCache
- `_get_redis` renamed to `get_redis` (public) — importable from any layer
