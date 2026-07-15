---
name: database-collection-patterns
<<<<<<< HEAD
description: Use this skill when working on database/collections/ — creating a new collection, adding query methods, working with BaseCollection or IndexedCollection, understanding cache/lock patterns, node_specific multi-VPS behavior, change stream sync, or secondary in-memory indexes. Covers CRUD, load, ensure_indexes, and how collections relate to DbManager.
=======
description: >-
  Use this skill when working on database/collections/ — creating a new
  collection, adding query methods, working with BaseCollection or
  IndexedCollection, understanding cache/lock patterns, node_specific multi-VPS
  behavior, change stream sync, or secondary in-memory indexes. Covers CRUD,
  load, ensure_indexes, and how collections relate to DbManager.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Database Collection Patterns

---

## Collection Class Hierarchy

```
<<<<<<< HEAD
BaseCollection[T]
└── IndexedCollection[T]      # adds secondary in-memory indexes (O(1) lookups)
    ├── ProductsCollection     # indexes: owner_id, owner_category
    ├── InventoryCollection    # index: wallet_id
    └── ...
```

=======
BaseCollection[T]                          # full-load cache + optional LRU mode
├── UsersCollection                        # LRU (max_size=1024, ≈1 MB)
├── WalletsCollection                      # LRU (max_size=1024, ≈1 MB)
├── WebSessionsCollection                  # no cache — all reads go to MongoDB directly
└── IndexedCollection[T]                   # full-load + secondary in-memory indexes (O(1) lookups)
    ├── ProductsCollection                 # indexes: owner_id, owner_category
    ├── InventoryCollection                # index: wallet_id
    ├── RssCollection                      # indexes: bot_id, user_id, bot_user_name
    └── TasksCollection                    # index: bot_id
```

### Cache mode decision guide

| Scenario | Pattern | Reason |
|---|---|---|
| Singleton / small bounded set | `BaseCollection`, default | Full-load; always fits in RAM |
| Unbounded, by-ID access only | `BaseCollection(max_size=N)` | LRU eviction; MongoDB fallback on miss |
| Bounded, secondary index needed | `IndexedCollection` | Full-load required for index completeness |
| Always DB-direct reads | `BaseCollection`, no LRU | Bypasses cache in all methods |

>>>>>>> 2ecb89d (update)
---

## Creating a New Collection

```python
# database/collections/my_feature.py
from typing import ClassVar
from database.collections.base import BaseCollection
from database.models.my_feature import MyFeatureModel

COLLECTION_NAME = __name__.rsplit(".", 1)[-1]  # "my_feature"

class MyFeatureCollection(BaseCollection[MyFeatureModel]):
    node_specific: ClassVar[bool] = False       # True = per-VPS document namespace
    sync_across_nodes: ClassVar[bool] = False   # True = enable change stream watcher

    def __init__(self, client, db_name: str = "public", collection_name: str = COLLECTION_NAME):
        super().__init__(client, db_name, collection_name, model_class=MyFeatureModel)
```

**Flags:**

| Flag | Default | Meaning |
|------|---------|---------|
| `node_specific` | `False` | Documents stored under `"<id>:<node_id>"` in MongoDB; cache uses canonical `id` |
| `sync_across_nodes` | `False` | Start a MongoDB change stream watcher for cross-VPS cache sync |

---

## CRUD — Inherited from BaseCollection

All methods write to **both** MongoDB and the in-memory cache atomically (lock-protected):

```python
# Insert — returns (InsertOneResult, model)
result, model = await db_manager.my_feature.insert_one(MyFeatureModel(...))

# Update — full model or partial dict; upserts if not found
result, model = await db_manager.my_feature.update_one(doc_id, model_or_dict)

# Replace — replaces entire document
result, model = await db_manager.my_feature.replace_one(doc_id, model)

# Delete one — returns (DeleteResult, old_model | None)
result, old = await db_manager.my_feature.delete_one(doc_id)

# Delete many — filter dict; empty dict = delete all
result, deleted = await db_manager.my_feature.delete_many({"owner_id": wallet_id})

# Count (hits MongoDB directly):
n = await db_manager.my_feature.count_documents({"status": "active"})
```

**Cloud-first delete:** MongoDB is updated first; cache is only updated after DB success.

---

## Cache Read Methods

```python
<<<<<<< HEAD
# Get by ID (from cache — no DB call):
model: MyFeatureModel | None = await db_manager.my_feature.get(doc_id)

# All documents (shallow copy of cache dict):
all_items: dict = await db_manager.my_feature.get_all()

# All IDs:
ids: list = await db_manager.my_feature.get_ids()

# Snapshot (same as get_all but property — no lock):
snap: dict = db_manager.my_feature.snapshots
```

=======
# Get by ID — cache hit returns deep copy; LRU miss falls back to MongoDB:
model: MyFeatureModel | None = await db_manager.my_feature.get(doc_id)

# All documents in cache (deep copy snapshot — may be partial under LRU):
all_items: dict = await db_manager.my_feature.get_all()

# All IDs currently in cache:
ids: list = await db_manager.my_feature.get_ids()

# Snapshot property (same as get_all — no lock):
snap: dict = db_manager.my_feature.snapshots
```

**LRU mode note:** When `max_size > 0`, `get()` adds a MongoDB fallback on cache miss. `get_all()` / `get_ids()` / `snapshots` return only what is currently in the LRU — not all documents in MongoDB. Use `count_documents()` for the authoritative total count.

>>>>>>> 2ecb89d (update)
---

## Model ↔ Dict Conversion

```python
# dict → model (via model_class.model_validate):
model = collection._to_model(doc_dict)

<<<<<<< HEAD
# model → dict (by_alias=True maps 'id' → '_id' for MongoDB):
doc_dict = collection._to_dict(model)
doc_dict = collection._to_dict(model, exclude={"id"})   # for update_one / replace_one
```

=======
# model → dict (real field names; 'id' remapped to '_id' for MongoDB):
doc_dict = collection._to_dict(model)
doc_dict = collection._to_dict(model, exclude={"id"})   # for replace_one (id excluded)
```

**Critical:** `_to_dict` uses `model_dump(by_alias=False)` — real Python field names are always stored in MongoDB. The only alias remapping that happens is `id → _id`. Do NOT change this to `by_alias=True`.

>>>>>>> 2ecb89d (update)
---

## update_one — Model vs Dict

```python
# Full model (preferred — replaces all fields):
await collection.update_one(wallet_id, wallet_model)
# → uses $set with all fields minus 'id'; caches model directly

# Partial dict (efficient — only changes listed fields):
await collection.update_one(wallet_id, {"balance": 100.0, "status": "active"})
# → uses $set with only those fields; re-fetches full model from cache/DB to update
```

---

## IndexedCollection — Secondary Indexes

Use when you need O(1) lookup by a non-primary-key field:

```python
from database.collections.base import IndexedCollection

class MyCollection(IndexedCollection[MyModel]):
    def __init__(self, client, db_name="public", collection_name=COLLECTION_NAME):
        super().__init__(client, db_name, collection_name, model_class=MyModel)
        self.register_index("owner_id", lambda m: m.owner_id)
        self.register_index("owner_category", lambda m: (m.owner_id, m.category))  # composite

    def get_by_owner(self, owner_id: int) -> list[MyModel]:
        return self.get_by_index("owner_id", owner_id)  # O(1)

    def get_by_owner_and_category(self, owner_id: int, category: str) -> list[MyModel]:
        return self.get_by_index("owner_category", (owner_id, category))  # O(1) composite
```

**Important:** `register_index` must be called in `__init__` before any data is loaded. Indexes are maintained automatically on all CRUD operations.

<<<<<<< HEAD
=======
**`IndexedCollection.update_one` lock contract:** The implementation acquires `self.lock` briefly to snapshot `old_model` before the `await`, then re-acquires after the `await` to perform the add-new/remove-old index swap atomically. Never call `_add_to_indexes` / `_remove_from_indexes` outside a lock — concurrent readers see a half-swapped state otherwise. When subclassing, override `_apply_remote_change` to invalidate any derived secondary indexes (like `_telegram_feeds_by_chat` in RssCollection) after calling `super()`.

>>>>>>> 2ecb89d (update)
---

## ensure_indexes — MongoDB Index Creation

Always call in `DbManager.startup()` for collections that need MongoDB indexes:

```python
async def ensure_indexes(self) -> None:
    from pymongo import ASCENDING, DESCENDING, IndexModel
    try:
        indexes = [
            IndexModel([("wallet_id", ASCENDING)], name="idx_wallet_id"),
            IndexModel([("doc_id", DESCENDING)], name="idx_doc_id"),
        ]
        await self.collection.create_indexes(indexes)
    except Exception as e:
        self._logger.error(f"Failed to ensure indexes: {e}")
```

Migration pattern — drop old indexes first:
```python
from pymongo.errors import OperationFailure
try:
    await self.collection.drop_index("old_index_name")
except OperationFailure:
    pass  # Already dropped or never existed
```

---

## load() — Startup Initialization

Called by `DbManager.startup()` for each collection:

```python
await collection.load(ensure_exists=False)   # just load from DB into cache
await collection.load(ensure_exists=True)    # load; if empty, initialize with defaults from ENV/config.py
```

`ensure_exists=True` triggers the config hierarchy: **DB → config.py → ENV → Model defaults**.

<<<<<<< HEAD
`OVERIDE_CONFIG` (from `db_manager.globals.overide_config`) forces a re-initialization from ENV even if data exists in DB.
=======
`OVERRIDE_CONFIG` (from `db_manager.globals.override_config`) forces a re-initialization from ENV even if data exists in DB.
>>>>>>> 2ecb89d (update)

---

## Change Stream Sync (multi-VPS)

When `sync_across_nodes = True`, the collection watches MongoDB change stream and propagates remote writes to the local cache.

```python
await collection.start_sync()   # starts background task
await collection.stop_sync()    # cancels it cleanly
```

**Override `_apply_remote_change`** to add custom logic on remote events:

```python
async def _apply_remote_change(self, change: dict) -> None:
    # Custom pre-processing (e.g. cache invalidation for bundle types)
    ...
    # Always call parent after custom logic:
    await super()._apply_remote_change(change)
```

Standard behaviour: `insert/update/replace` → `cache[model.id] = model`, `delete` → `cache.pop(doc_id)`.

<<<<<<< HEAD
=======
**Monotonic guard:** `_apply_remote_change` compares the incoming document's `created_at`
against the currently cached model before applying an `insert/update/replace`. Older Change
Stream events are dropped instead of overwriting a fresher local write — needed because in
multi-VPS mode a local `update_one` updates the cache immediately, and the corresponding CS
event can arrive later carrying stale data if another node wrote in between.

>>>>>>> 2ecb89d (update)
---

## node_specific — Multi-VPS Document Namespacing

When `node_specific = True`, each VPS writes to `"<id>:<node_id>"` in MongoDB while the in-memory cache always uses canonical `id`. All callers remain unchanged — only the DB `_id` differs.

```python
# Internal: _get_doc_id(canonical_id) returns "<id>:<node_id>" when node_specific=True
db_id = collection._get_doc_id(config_id)   # e.g. "services:5432836963"
```

`load()` has backwards-compat fallback: if the namespaced doc isn't found, it falls back to the shared doc (migration path).

---

<<<<<<< HEAD
## Composite Document IDs

```python
# For collections that need multi-key IDs (e.g. bot + user):
doc_id = BaseCollection.make_document_id(bot_id, user_id)   # "123:456"
bot_id, user_id = BaseCollection.parse_document_id(doc_id)  # (123, 456)
```

---
=======
>>>>>>> 2ecb89d (update)

## Registering in DbManager

After creating a collection, register it in `database/__init__.py`:

```python
from database.collections.my_feature import MyFeatureCollection

class DbManager:
    def _initialize_managers(self, client):
        ...
        self.my_feature = MyFeatureCollection(client)
```

Then add to the `startup()` load list:
```python
collections_to_load = [
    ...
    ("my_feature", False),   # or True if singleton config
]
```

And call `ensure_indexes()` in startup if needed:
```python
if self.my_feature:
    await self.my_feature.ensure_indexes()
```
