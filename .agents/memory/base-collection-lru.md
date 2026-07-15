---
name: BaseCollection LRU + Redis L2 cache — four collection archetypes
description: Three-tier cache wired into BaseCollection; four archetypes by access pattern and growth profile; InventoryCollection is Type 4 (by-index, unbounded) — must use query-result cache, NOT IndexedCollection.
---

## Three-tier read path

```
L1  in-process Cache / dict      zero latency, count-bounded or full
L2  local Redis TTL (_cache_ttl) ~0.1–0.5 ms, memory-bounded by maxmemory
L3  MongoDB                      source of truth, unconditional fallback
```

## Four archetypes

### Type 1 — By-ID, bounded (bots, globals, single-doc configs)
- L1: plain `dict` (full load at startup), no L2/L3 after startup
- `max_size=0`, `_cache_ttl=0`

### Type 2 — By-ID, unbounded (users, wallets)
- L1: `Cache(maxsize=1024)` keyed by doc id
- L2: local Redis `col:<name>:<id>` with TTL (opt-in via `_cache_ttl`)
- L3: MongoDB `find_one` on double miss → populates L1+L2
- Change-stream push: `_apply_remote_change` → L1+L2

### Type 3 — By-index, bounded (products, records, tasks, rss_feeds)
- L1: plain `dict` (full mirror — complete index coverage required)
- No L2 — partial Redis on `IndexedCollection` produces wrong `get_by_index` results
- `max_size=0`, `_cache_ttl=0`

### Type 4 — By-index, unbounded → query-result cache (inventory)

**Problem**: `InventoryCollection` on `IndexedCollection` grows unbounded — all purchases ever × all users in process RAM. LRU cannot be added because partial coverage silently drops items from `get_by_index()` results.

**Why IndexedCollection is wrong for inventory**: MongoDB already has `idx_wallet_expired (wallet_id, expired_at)` covering all wallet queries. The in-process secondary index duplicates the MongoDB index and grows unboundedly.

**Recommended pattern (not yet implemented)**:
- Cache unit: `wallet_id → list[InventoryModel]` (query result, not individual doc)
- L1: `Cache(maxsize=N)[wallet_id, list[InventoryModel]]` — bounded by distinct wallets accessed recently
- L2: local Redis `inv:<wallet_id>` → serialized list, TTL=300s
- L3: MongoDB `find({"wallet_id": X})` with compound index on miss
- Write invalidation: any write for wallet X evicts L1[wallet_id] + Redis `inv:<wallet_id>`
- LRU is safe because a miss re-queries MongoDB for the correct, complete answer

**Status**: analysis done; `InventoryCollection` still on `IndexedCollection` pending conversion.

**How to apply**:
- New collection that is by-index AND can grow with user count → Type 4, not Type 3
- Do NOT add `_cache_ttl` to any `IndexedCollection` subclass
- Type 3 is only safe when the total document count is bounded (operator-controlled catalog, config, active tasks)

## Which collections opt in to each type

| Collection | Type | max_size | _cache_ttl |
|---|---|---|---|
| `UsersCollection` | 2 | 1024 | 3600 s |
| `WalletsCollection` | 2 | 1024 | 1800 s |
| `ProductsCollection` | 3 | 0 | 0 |
| `RecordsCollection` | 3 | 0 | 0 |
| `TasksCollection` | 3 | 0 | 0 |
| `RssFeedsCollection` | 3 | 0 | 0 |
| `InventoryCollection` | **4 (pending)** | — | — |
| Everything else (configs) | 1 | 0 | 0 |

## Local Redis config (recommended)

```
maxmemory 64mb
maxmemory-policy allkeys-lru
REDIS_URL=redis://127.0.0.1:6379  (local per-VPS, not cloud)
```

Cloud Redis free tier (~256 MB, ~25–30 connections) is unsuitable:
4 VPS nodes × pool size exhausts connections; peers alone (1M × 500 B) exceeds 256 MB.
Local Redis is per-VPS L2 only — cross-node consistency via MongoDB Change Streams.

## Exclusive L2 — one tier, not two

`utils/redis_peer_cache.py` selects exactly one L2 tier at startup:

| `REDIS_URL` | Active L2 | On miss |
|---|---|---|
| Set | Redis | → L3 MongoDB directly |
| Unset | In-process LRU/TTL | → L3 MongoDB directly |

No "write to both" path exists. Writing to in-process while Redis is configured wastes RAM and causes stale reads after restart.

In-process stores (only when Redis is unset):
- `PeerCache._local` — `Cache(maxsize=10_000)` keyed `(bot_id, peer_id)`
- `AccessCache._local` — `Cache(maxsize=4_096, ttl=10)` keyed `(client_id, user_id)`

Access TTL (10 s) is a security requirement — without it a cached "sudo"/"auth" survives until LRU evicts it (hours). Redis enforces via SETEX; in-process via monotonic clock in unified Cache.

## Redis key namespaces

| Namespace | Key | TTL |
|---|---|---|
| Peer cache | `p:<bot_id>:<peer_id>` | 4 h |
| Access check | `ac:<client_id>:<user_id>` | 10 s |
| Collection L2 | `col:<collection>:<doc_id>` | per-collection |
| Inventory query *(planned)* | `inv:<wallet_id>` | 300 s |

All share `_get_redis()` from `utils.redis_peer_cache` — one pool per process.

## Cache iteration under LRU (Type 2)

`get_all()`, `get_ids()`, and `snapshots` have been **removed** from `BaseCollection`.
Iterating the cache in LRU mode returns only the hot in-process subset, not all MongoDB documents.
Use `count_documents()` for authoritative totals; query MongoDB directly for full scans.
