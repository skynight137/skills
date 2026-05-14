# Database Module Skill

Use this skill whenever working with the `database/` module — reading/writing collections, adding models, creating collections, fixing bugs related to cache, expiration, multi-VPS sync, or MongoDB indexes.

**Full reference:** `database/Readme.md`

---

## Quick Mental Model

```
DbManager (database/__init__.py)
  └── XxxCollection (database/collections/xxx.py)   ← CRUD + cache
        └── XxxModel (database/models/xxx.py)        ← Pydantic v2 schema
```

Everything goes through `db_manager` — never instantiate collections directly:

```python
from database import db_manager

item  = await db_manager.inventory.get(inv_id)
items = db_manager.inventory.get_by_wallet(wallet_id)    # O(1) indexed
_, m  = await db_manager.inventory.insert_one(model)
_, m  = await db_manager.inventory.update_one(id, {"balance": 100})
_, m  = await db_manager.inventory.delete_one(id)
```

---

## Critical Rules — Read Before Writing Anything

### 1. Cloud-First Always

Every write must hit MongoDB **before** touching the local cache:

```python
# WRONG
self.cache.pop(id)
await self.collection.delete_one({"_id": id})

# CORRECT (already how BaseCollection.delete_one works)
result = await self.collection.delete_one({"_id": id})
self.cache.pop(id, None)
```

`BaseCollection` methods enforce this — only break the pattern if you bypass the ORM.

### 2. inventory.id ≠ item.id

```python
inv: InventoryModel

inv.id       # token_hex(5) — the inventory document's own _id (unique per purchase)
inv.item.id  # the product's _id in the products collection
```

Use `inv.id` for all CRUD on the inventory collection.
Use `inv.item.id` only when navigating to the product page or logging the product reference.

### 3. Never Use MongoDB TTL on `inventory`

The inventory collection must NOT have `expireAfterSeconds` on `expired_at`.
`ExpirationManager` is the sole cleanup authority — it must run VIP kicks **before** deletion.
A TTL race would evict items from cache before ExpirationManager sees them.

Current indexes (set by `InventoryCollection.ensure_indexes()`):
- `idx_wallet_id` — `wallet_id ASC` (no TTL)
- `idx_expired_at` — `expired_at ASC` (no TTL, query performance only)

### 4. Safe Cache Iteration

```python
# UNSAFE — RuntimeError if another coroutine mutates cache during iteration
for m in collection.cache.values(): ...

# SAFE — always snapshot first
for m in collection.snapshots.values(): ...
for m in list(collection.cache.values()): ...
```

### 5. Bundle Invalidation After Inventory Changes

When adding/updating/removing `bot_bundle` or `user_bundle` inventory items:

```python
from bot.config import BotConfig, UserConfig

if item.category == "bot_bundle":
    BotConfig.invalidate(wallet_id)
elif item.category == "user_bundle":
    UserConfig.invalidate(wallet_id)
```

Skipping this leaves the config singleton stale until the next restart.

---

## Adding a New Model

1. Create `database/models/mymodel.py` extending `CollectionModel`:

```python
from pydantic import Field
from database.models.base import CollectionModel

class MyModel(CollectionModel):
    id: str = Field(..., alias="_id")
    wallet_id: int
    data: str = ""
```

2. Create `database/collections/mymodel.py`:

```python
from pymongo import ASCENDING, IndexModel
from database.collections.base import BaseCollection   # or IndexedCollection
from database.models.mymodel import MyModel

COLLECTION_NAME = __name__.rsplit(".", 1)[-1]

class MyModelCollection(BaseCollection[MyModel]):
    def __init__(self, client, db_name="public", collection_name=COLLECTION_NAME):
        super().__init__(client, db_name, collection_name, model_class=MyModel)

    async def ensure_indexes(self) -> None:
        indexes = [IndexModel([("wallet_id", ASCENDING)], name="idx_wallet_id")]
        await self.collection.create_indexes(indexes)
```

3. Register in `database/__init__.py`:
   - Import at top
   - Instantiate in `DbManager.__init__()`
   - Add to load list and call `ensure_indexes()` in startup sequence

---

## Adding a Secondary In-Memory Index

Use `IndexedCollection` when you frequently filter a large collection by a field:

```python
from database.collections.base import IndexedCollection

class MyCollection(IndexedCollection[MyModel]):
    def __init__(self, client, db_name, collection_name):
        super().__init__(client, db_name, collection_name, model_class=MyModel)
        self.register_index("wallet_id", lambda m: m.wallet_id)
        # Composite index
        self.register_index("wallet_category", lambda m: (m.wallet_id, m.category))

    def get_by_wallet(self, wallet_id: int) -> list[MyModel]:
        return self.get_by_index("wallet_id", wallet_id)
```

Indexes are rebuilt on `load()` and maintained automatically on every write.

---

## Multi-VPS Patterns

### Node Identity

```python
from database.node import get_node_id

node_id = get_node_id()   # int (bot token prefix) | None (single-VPS)
```

Initialize before startup:
```python
from database import node as db_node
db_node.init_from_env()
```

### Per-Node Documents (`node_specific = True`)

Set on service daemon collections where each VPS has its own config:

```python
class QbitCollection(BaseCollection[QbitModel]):
    node_specific: ClassVar[bool] = True
```

MongoDB `_id` becomes `"canonical_id:node_id"`. Cache key stays `"canonical_id"`. All callers unchanged.

### Cross-Node Sync (`sync_across_nodes = True`)

Set on shared data collections (inventory, wallets, products, etc.). Requires MongoDB Replica Set.
Change streams automatically keep caches synchronized across VPS nodes.

```python
class InventoryCollection(IndexedCollection[InventoryModel]):
    sync_across_nodes: ClassVar[bool] = True
```

---

## ExpirationManager

Located at `database/expiration.py`. Started automatically on `db_manager.startup()`.

Each cycle (default 600 s):
1. Deduct credit uptime for connected bot wallets
2. Scan `wallet_config.inventory` for items where `expired_at <= now`
3. For `vip_chat`: kick user from Telegram group (skip + retry if bot not connected)
4. Delete expired inventory document
5. Invalidate `UserConfig` / `BotConfig`

No extra configuration needed — node-aware by design (only processes local bots).

Manual control:
```python
await db_manager.expiration_manager.start()
await db_manager.expiration_manager.stop()
await db_manager.expiration_manager.restart()
```

---

## ensure_indexes() — Migration Pattern

When changing an existing MongoDB index (e.g. removing TTL), you must drop the old index first or `create_indexes` will raise `IndexKeySpecsConflict`:

```python
from pymongo.errors import OperationFailure

async def ensure_indexes(self) -> None:
    try:
        try:
            await self.collection.drop_index("old_index_name")
        except OperationFailure:
            pass  # didn't exist — safe to ignore

        indexes = [IndexModel([("field", ASCENDING)], name="new_index_name")]
        await self.collection.create_indexes(indexes)
    except Exception as e:
        self._logger.error(f"Failed to ensure indexes: {e}")
```

---

## Startup Sequence Reference

```
db_manager.startup()
  1. globals.load(ensure_exists=True)         ← must be first (overide_config flag)
  2. records, bin, users, bots, rss, wallets, products, inventory, tasks  ← .load()
  3. Service collections (aria, qbit, …)      ← .load(ensure_exists=True)
  4. inventory.ensure_indexes()               ← migration + index creation
  5. products.ensure_indexes()
  6. sessions / transactions / bot_users / bots / rss .ensure_indexes()
  7. expiration_manager.start()
  8. start_sync() for shared collections
```

---

## DictStore — int↔str Key Conversion

MongoDB cannot store integer dict keys. `BotModel.auths` and `rss_chats` use `DictStore`:

```python
from database.utils import DictStore

encoded = DictStore.encode({-1001234: None})   # {"-1001234": None}  — save to Mongo
decoded = DictStore.decode({"-1001234": None}) # {-1001234: None}   — restore in Python
```

---

## Common Bugs Checklist

| Symptom | Likely Cause | Fix |
|---|---|---|
| VIP kicks not running | TTL index racing ExpirationManager | Remove `expireAfterSeconds` from `idx_expired_at` |
| Wrong inventory deleted | Using `product_id` instead of `inv.id` | Distinguish `inv.id` vs `inv.item.id` |
| Bundle limits not updated after purchase | Missing `BotConfig.invalidate()` | Call invalidate after inventory change |
| `RuntimeError: dictionary changed size` | Iterating `cache.values()` directly | Use `collection.snapshots` or `list(cache.values())` |
| `IndexKeySpecsConflict` on startup | Index name exists with different options | Drop old index first in `ensure_indexes()` |
| Service collection overrides ENV not applied | `overide_config` is False | Set `GlobalModel.overide_config = True` or check ENV precedence |
| Cache stale after remote write on another node | `sync_across_nodes` not set | Enable change stream sync for the collection |
| Node-specific doc not found | Missing `node_specific = True` | Add flag and run migration |
