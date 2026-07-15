---
name: base-collection-lru
description: Use when choosing a cache strategy for a new BaseCollection subclass, deciding whether to pass max_size, or working on users/wallets collections where LRU mode and MongoDB fallback on cache miss are active.
enabled: true
---

# BaseCollection LRU Mode

## Overview

`BaseCollection` supports two cache strategies, selected at construction time via `max_size`.

| `max_size` | Cache type | Fallback on miss |
|---|---|---|
| `0` (default) | `dict` — full-load, unbounded | Returns `None` (no DB call) |
| `> 0` | `Cache(maxsize=max_size)` | `find_one` on MongoDB, repopulates LRU |

`Cache` lives in `utils/lru_cache.py`. It is a unified LRU + optional-TTL cache — both reads and writes update the access order. `LRUCache` and `TTLCache` remain as backward-compatible aliases.

---

## When to Use LRU Mode

Use `max_size=N` when **all three** conditions hold:

1. The collection grows **unboundedly** (e.g. every user/wallet gets a document)
2. Access is almost always **by primary key** (`get(id)`) — no secondary indexes
3. You can tolerate a **MongoDB round-trip on a cold read** (the first access for an evicted doc)

**Do NOT use LRU mode with `IndexedCollection`.**  
Secondary indexes require complete cache coverage — an evicted doc leaves stale `doc_id` entries in the index; `get_by_index()` silently returns partial results.

---

## Which Collections Use LRU

| Collection | `max_size` | Notes |
|---|---|---|
| `UsersCollection` | `1024` | ~1 MB at 1 KB/doc average |
| `WalletsCollection` | `1024` | ~1 MB at 1 KB/doc average |
| Everything else | `0` | Bounded, DB-direct, or `IndexedCollection` |

---

## How to Opt a Collection In

```python
class MyCollection(BaseCollection[MyModel]):
    def __init__(self, client, db_name="public", collection_name=COLLECTION_NAME):
        super().__init__(
            client, db_name, collection_name,
            model_class=MyModel,
            max_size=1024,   # enables LRU + MongoDB fallback
        )
```

---

## get() Behaviour Under LRU

```
cache hit  → deep copy, return                  (zero I/O, lock released)
cache miss + _lru_mode=False  → None            (full-load collections)
cache miss + _lru_mode=True   → find_one MongoDB
                              → _to_model()
                              → insert into LRU
                              → deep copy, return
```

The lock is released **before** the MongoDB I/O so other coroutines are not blocked during the fetch.

---

## LRU Iteration Warning

`get_all()`, `get_ids()`, and `snapshots` have been **removed** from `BaseCollection`.
Iterating `self.cache` in LRU mode returns only the hot in-process subset — it does **not** represent all MongoDB documents. Never use cache iteration as a census.

Use `count_documents({})` for the authoritative total count; query MongoDB directly for full scans.

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Adding `max_size` to an `IndexedCollection` subclass | Remove it — indexes require full coverage |
| Iterating the cache to enumerate all users/wallets | Use `count_documents({})` or query MongoDB directly |
| Setting `max_size` on a singleton/config collection | Leave at `0` — these are already small and bounded |
| Calling `get_all()` or `get_ids()` | Both removed — they returned incomplete results in LRU mode |
