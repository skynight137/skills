---
name: bot-node-reassignment-patterns
description: Use this skill when working on multi-VPS node heartbeat, NodeStatusCollection, auto-start-on-reassignment, or the "Reassign Node" UI in Bot Configuration. Covers NodeStatusModel, upsert pattern, heartbeat loop, Change Stream auto-start hook (BotsCollection._on_bot_assigned), reassign_node menu flow, callback schema, do_reassign sequence, and staleness thresholds.
---

# Bot Node Reassignment Patterns

Multi-VPS feature: move a bot from one node to another without touching the target node manually.

---

## 1. NodeStatusModel (`database/models/node.py`)

```python
class NodeStatusModel(CollectionModel):
    id: int = Field(..., alias="_id")      # node_id (main bot Telegram ID)
    last_seen: datetime                    # UTC, default = now
    hostname: str | None = None
    bot_count: int = 0
```

`_id` **is** the node_id — one document per VPS, not namespaced.

---

## 2. NodeStatusCollection (`database/collections/nodes.py`)

```python
class NodeStatusCollection(BaseCollection[NodeStatusModel]):
    sync_across_nodes: ClassVar[bool] = True   # every node sees all heartbeats live
```

### upsert — use mode="python" for native BSON DateTime

```python
async def upsert(self, model: NodeStatusModel) -> None:
    data = model.model_dump(mode="python", by_alias=True)  # datetime stays as datetime
    doc_id = data.pop("_id")
    await self.collection.replace_one({"_id": doc_id}, {"_id": doc_id, **data}, upsert=True)
    async with self.lock:
        self.cache[doc_id] = model
```

**Do NOT use `mode="json"`** — that converts datetime to ISO string, breaking MongoDB BSON DateTime storage.

### get_all_nodes — sync, snapshot-safe

```python
def get_all_nodes(self) -> list[NodeStatusModel]:
    nodes = list(self.snapshots.values())
    nodes.sort(key=lambda n: n.last_seen, reverse=True)
    return nodes
```

### Registration in `database/__init__.py`

```python
# _initialize_managers
self.nodes = NodeStatusCollection(client)

# startup shared sync list
_shared_collections = [..., "bots", "nodes"]

# disconnect / disconnect_async cleanup lists — same
```

---

## 3. TelegramService Heartbeat (`bot/service/telegram.py`)

Three methods hang off `TelegramService`:

### _publish_node_heartbeat

```python
async def _publish_node_heartbeat(self) -> None:
    node_id = self._main_bot_id
    if node_id is None: return           # single-VPS mode → no-op
    nodes_col = getattr(self.db_manager, "nodes", None)
    if nodes_col is None: return

    bot_count = sum(
        1 for c in self.bot_manager.get_all_clients(exclude_main_bot_id=True).values()
        if c.is_connected
    )
    hostname = socket.gethostname()  # wrapped in try/except
    model = NodeStatusModel(**{"_id": node_id, "last_seen": datetime.now(timezone.utc),
                                "hostname": hostname, "bot_count": bot_count})
    await nodes_col.upsert(model)
```

### _heartbeat_loop

```python
async def _heartbeat_loop(self) -> None:
    while True:
        try:
            await asyncio.sleep(60)
            await self._publish_node_heartbeat()
        except asyncio.CancelledError:
            break
        except Exception:
            self._logger.exception("Heartbeat loop error (continuing)")
```

### _start_assigned_bot (auto-start on reassignment)

```python
async def _start_assigned_bot(self, bot_id: int) -> None:
    if self.bot_manager.get_client(bot_id): return   # already registered
    bot_data = self.db_manager.bots.snapshots.get(bot_id)
    if not bot_data: return

    client = await self.build_client(bot_id, bot_token=..., session_string=...)
    await asyncio.wait_for(client.start(), timeout=10.0)
```

### Hook-up in _start_client

```python
self.db_manager.bots.register_on_bot_assigned(self._start_assigned_bot)
await self._load_clients_from_database()
await self._publish_node_heartbeat()
self._heartbeat_task = asyncio.create_task(self._heartbeat_loop(), name="node-heartbeat")
```

### cleanup_tasks

```python
if self._heartbeat_task and not self._heartbeat_task.done():
    self._heartbeat_task.cancel()
    with suppress(asyncio.CancelledError):
        await self._heartbeat_task
    self._heartbeat_task = None
```

---

## 4. Auto-Start Hook (`database/collections/bots.py`)

`BotsCollection` fires a callback when a bot lands in the local cache for the first time — which is how a reassigned bot auto-starts on the target node.

```python
def register_on_bot_assigned(self, callback: Callable[[int], Awaitable[Any]]) -> None:
    self._on_bot_assigned = callback

async def _apply_remote_change(self, change: dict) -> None:
    ...
    # only if bot is new to this node's cache:
    async with self.lock:
        is_new_to_node = bot_id not in self.cache
    await super()._apply_remote_change(change)
    if is_new_to_node and self._on_bot_assigned:
        asyncio.create_task(self._on_bot_assigned(bot_id), name=f"auto-start-assigned-bot-{bot_id}")
```

The callback fires AFTER `super()._apply_remote_change` so the bot is in cache when the task runs.

---

## 5. Reassign Node UI (`bot/modules/settings/bots/_bot_manage.py`)

### Callback schema

```
bot_manage <user_id> <bot_id> reassign_node           → show picker menu
bot_manage <user_id> <bot_id> do_reassign <target_id> → execute reassignment
```

### Button placement (manage action only in multi-VPS mode)

```python
if get_node_id() is not None:
    buttons.callback_button(
        "🌐 Reassign Node",
        f"{CallbackPrefix.BOT_MANAGE} {identity} reassign_node",
        style=ButtonStyle.DEFAULT,
    )
```

### Staleness thresholds (UI health indicators)

| Age | Icon | Button style |
|-----|------|--------------|
| < 2 min | 🟢 | `SUCCESS` |
| 2–10 min | 🟡 | `DEFAULT` |
| > 10 min | 🔴 | `DANGER` |

### Reassignment sequence (order is critical)

```
1. await user_bot_config.update_fields({"node_id": target_node_id})
   ↑ DB write FIRST — triggers Change Stream on target node
   ↑ Target fires _on_bot_assigned → auto-starts the client

2. await user_bot.bot_manager.stop_client(bot_id)
   ↑ Stop local Pyrogram session

3. await user_bot.bot_manager.unregister_client(bot_id)
   ↑ Remove from local _clients dict only — does NOT delete DB document
   ↑ Use unregister_client, NOT remove_client (which deletes from DB)
```

### Guards before executing do_reassign

```python
if get_node_id() is None:          → "multi-VPS only"
if bot.node_id != current_node_id: → "connect to that node"
if target == current_node_id:      → "already on this node"
```

### Timezone safety when computing age

```python
last_seen = node.last_seen
if last_seen.tzinfo is None:
    last_seen = last_seen.replace(tzinfo=timezone.utc)   # Motor may strip tz
age_s = int((datetime.now(timezone.utc) - last_seen).total_seconds())
```

---

## 6. Imports needed in `_bot_manage.py`

```python
from datetime import datetime, timezone
from database.node import get_node_id
from ._constants import ..., db_manager
```

`db_manager` is exported from `_constants.py` (already present: `db_manager = telegram_service.db_manager`).
