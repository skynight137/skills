---
name: database-model-patterns
<<<<<<< HEAD
description: Use this skill when working on database/models/ — creating or modifying Pydantic models for MongoDB, understanding CollectionModel (id/_id alias), DaemonModel/UtilityModel mixins, field metadata patterns, model utility methods, DbManager singleton, startup order, or ExpirationManager. Covers model conventions, db_manager usage, and startup lifecycle.
=======
description: >-
  Use this skill when working on database/models/ — creating or modifying
  Pydantic models for MongoDB, understanding CollectionModel (id/_id alias),
  DaemonModel/UtilityModel mixins, field metadata patterns, model utility
  methods, DbManager singleton, startup order, or ExpirationManager. Covers
  model conventions, db_manager usage, and startup lifecycle.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Database Model Patterns

---

## CollectionModel — Base for All DB Models

Location: `database/models/base.py`

```python
from database.models.base import CollectionModel

class MyModel(CollectionModel):
    id: int = Field(..., alias="_id")   # inherited — '_id' in MongoDB, 'id' in Python
    name: str
    status: str = "active"
```

**Config:**
```python
model_config = ConfigDict(
    validate_assignment=True,   # re-validates on setattr
    extra="ignore",             # silently drop unknown MongoDB fields
    populate_by_name=True,      # allow both 'id' and '_id' in model_validate()
)
```

**Key rule:** `id` in Python ↔ `_id` in MongoDB via Pydantic alias. Always use `by_alias=True` when dumping for MongoDB:
```python
doc = model.model_dump(by_alias=True)   # {'_id': ..., 'name': ..., ...}
```

`BaseCollection._to_dict()` handles this automatically — never call `model_dump(by_alias=True)` manually in service/endpoint code.

---

## Creating a New Model

```python
# database/models/my_feature.py
from pydantic import Field
from database.models.base import CollectionModel

class MyFeatureModel(CollectionModel):
    id: int = Field(..., alias="_id")
    owner_id: int
    config_key: str = ""
    max_limit: int = Field(default=10, ge=1, le=1000, description="...")
    enabled: bool = True
```

---

## DaemonModel — For Service Config Models

Use when the model represents a service that runs as a background daemon (aria, qbit, youtube, etc.):

```python
from database.models.base import DaemonModel

class AriaModel(DaemonModel):
    id: str = Field(default="aria", alias="_id")   # singleton — fixed string ID
    aria_port: int = Field(default=6800, ...)
    ...
```

Inherits: `timeout`, `daemon_startup_timeout`, `post_daemon_startup_delay`, `max_retries`.

---

## UtilityModel — For Non-Daemon Service Configs

For services that run but don't act as daemons:

```python
from database.models.base import UtilityModel

class RcloneModel(UtilityModel):
    id: str = Field(default="rclone", alias="_id")
    ...
```

---

## CollectionModel Utility Methods

```python
# Field metadata introspection:
<<<<<<< HEAD
MyModel.get_all_keys()                          # ['id', 'name', 'status', ...]
MyModel.get_all_keys(by_alias=True)             # ['_id', 'name', 'status', ...]
=======
MyModel.get_all_keys()                          # ['id', 'name', 'status', ...]  (real field names)
>>>>>>> 2ecb89d (update)
MyModel.get_all_keys(exclude={"id", "status"})

MyModel.get_default_value("status")             # "active"
MyModel.is_boolean("enabled")                   # True / False

<<<<<<< HEAD
=======
# Index-based field lookup (used by settings callbacks to stay under 64-byte limit):
MyModel.get_field_index("max_limit", exclude={"id"})   # → int position in sorted key list
MyModel.get_field_by_index(3, exclude={"id"})          # → field name at that index, or None

# Alias resolution (explicit Field(alias=...) only — no alias_generator):
MyModel.resolve_alias("_id")          # → "id"   (explicit alias → real name)
MyModel.get_alias("id")               # → "_id"  (real name → explicit alias)

>>>>>>> 2ecb89d (update)
# Instance methods:
model.get_value("name")        # getattr with validation
model.get_info("max_limit")    # {"description": ..., "default": ..., "current": ..., "type": ...}
model.update_fields({"name": "New", "status": "inactive"})   # batch setattr

# Field extras (json_schema_extra) filtering:
MyModel.get_keys_by_extra("non_service", True)  # fields tagged with non_service=True

# Input parsing (for bot settings handlers):
parsed = MyModel.parse_input_value("max_limit", "42")   # → int(42)
parsed = MyModel.parse_input_value("allowed_ips", '["1.2.3.4"]')  # → list
```

<<<<<<< HEAD
=======
### Index-Based Callbacks — Key Rule

Settings callbacks encode field identity as a **positional integer index** (position in the sorted `get_all_keys()` list), not as the field name or any hash. This keeps callback data under 64 bytes without alias hashing.

```python
# Building buttons (sender side):
for idx, key in enumerate(model.get_all_keys(exclude={"id"})):
    cb = f"botset {user_id} crud {idx}"   # stores int index

# Decoding on callback (receiver side):
field_name = model.get_field_by_index(int(d3), exclude={"id"})
```

**Rule:** `_to_dict` (in `BaseCollection`) always uses `by_alias=False` — real Python field names are always stored in MongoDB, never short hashes or aliases. See `database-collection-patterns` skill for details.

>>>>>>> 2ecb89d (update)
---

## json_schema_extra — Field Tagging

Use `json_schema_extra` to tag fields for UI or permission grouping:

```python
class MyModel(CollectionModel):
    timeout: float = Field(
        default=60,
        description="Operation timeout",
        json_schema_extra={"non_service": True}    # won't appear in service settings UI
    )
    admin_only: bool = Field(
        default=False,
        json_schema_extra={"requires_dev": True}   # custom tag — checked by UI
    )
```

---

## Polymorphic Models — Discriminated Union

For polymorphic collections (like products), define a discriminated union as the TypeAdapter target:

```python
from typing import Annotated, Union
from pydantic import Field, TypeAdapter

ProductItem = Annotated[
    Union[ProductVIPChatModel, ProductPaidMessageModel, ProductTopupModel, ProductModel],
    Field(discriminator="category")
]

ProductItemAdapter = TypeAdapter(ProductItem)

# In collection._to_model:
def _to_model(self, data: dict) -> ProductItem:
    return ProductItemAdapter.validate_python(data)
```

---

## DbManager — Singleton

Location: `database/__init__.py`

```python
from database import db_manager   # global singleton

# All collections accessible as attributes:
db_manager.wallets        # WalletsCollection
db_manager.products       # ProductsCollection
db_manager.inventory      # InventoryCollection
db_manager.transactions   # TransactionsCollection
<<<<<<< HEAD
db_manager.sessions       # SessionsCollection
=======
db_manager.web_sessions   # WebSessionsCollection  (web app auth sessions, public DB)
db_manager.pyrogram       # PyrogramCollection (Pyrogram MTProto, pyrogram DB)
>>>>>>> 2ecb89d (update)
db_manager.users          # UsersCollection
db_manager.bots           # BotsCollection
db_manager.rss            # RssCollection
db_manager.globals        # GlobalCollection
db_manager.records        # RecordsCollection
db_manager.tasks          # TasksCollection
db_manager.bin            # BinCollection
db_manager.bot_users      # BotUsersCollection
# ... plus service configs: aria, qbit, rclone, telegram, webs, youtube, gdrive, sevenz, ffmpeg, chat_cloner
```

**Get a fresh instance:**
```python
DbManager.get_instance(mongodb_uri)   # returns cached singleton for that URI
```

---

## DbManager Startup Sequence

`await db_manager.startup()` is called once on app boot. Order matters:

<<<<<<< HEAD
1. `globals` loaded first (`ensure_exists=True`) — controls `OVERIDE_CONFIG` flag
=======
1. `globals` loaded first (`ensure_exists=True`) — controls `OVERRIDE_CONFIG` flag
>>>>>>> 2ecb89d (update)
2. Service collections loaded (`ensure_exists=True`) — init from ENV if empty
3. Data collections loaded (`ensure_exists=False`) — load as-is
4. `ensure_indexes()` called for collections needing MongoDB indexes
5. `ExpirationManager.start()` — background expiry loop
6. Change stream sync started for shared collections

---

## ExpirationManager

Runs as background asyncio task. Sole authority for expired inventory cleanup — no MongoDB TTL index on `inventory` to prevent race conditions.

```python
# Access via:
db_manager.expiration_manager.is_running     # bool

# Force stop (sync):
db_manager.expiration_manager.force_stop_sync()

# Graceful async stop (via db_manager.disconnect_async()):
await db_manager.disconnect_async()
```

**What it does per cycle:**
1. Scans all inventory items for expired entries
2. For VIP chat: kicks the user from the Telegram chat
3. For bundles: invalidates BotConfig/UserConfig caches
4. Deletes expired inventory document

**Why not MongoDB TTL?** The TTL index would delete documents before ExpirationManager processes VIP kicks. ExpirationManager must run first.

---

## Disconnect / Shutdown

```python
# From async context (e.g. bot/__main__.py):
await db_manager.disconnect_async()   # awaits stop_sync(), then disconnect()

# From sync context:
db_manager.disconnect()               # fire-and-forget cancel on sync tasks
```

---

## Collection Name Convention

```python
# Always derive collection_name from module name:
COLLECTION_NAME = __name__.rsplit(".", 1)[-1]
# database/collections/wallets.py → "wallets"
# database/collections/my_feature.py → "my_feature"
```

This means MongoDB collection name = Python file name (without `.py`). Maintain consistency.

---

## Database Names

| Collection group | `db_name` |
|-----------------|-----------|
| All standard collections | `"public"` |

All collections use `db_name="public"` by default. Pass a different name to the constructor only if intentionally using a separate database.
