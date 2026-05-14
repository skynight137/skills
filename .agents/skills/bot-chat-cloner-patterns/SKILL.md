---
name: bot-chat-cloner-patterns
description: Use this skill when working on the chat_cloner module (bot/modules/chat_cloner.py, bot/service/chat_cloner.py). Covers arguments, operation modes, source topic filtering, and multi-destination config.
---

# Bot — Chat Cloner Patterns

Reference for the Chat Cloner system in `bot/modules/chat_cloner.py`.

---

## File Structure

```
bot/modules/chat_cloner.py          # CloneChat task class — arg parsing & task setup
bot/service/chat_cloner.py          # CloneChatManager — execution logic
bot/config/chat_cloner.py           # ChatClonerConfig (UtilityConfig + ChatClonerModel)
database/collections/chat_cloner.py # DB persistence
bot/plugins/special.py              # Plugin: filters.command + filters.sudo
bot/utils/bot_commands.py           # Commands: clone_chat = ["clonech", "cc"]
```

---

## Key Classes

| Class | Responsibility |
|-------|----------------|
| `CloneChat` | Extends `TaskConfig`; parses args, validates chats, submits task |
| `CloneChatManager` | Executes cloning; handles all operation modes |
| `CloneChatService` | `BaseService` subclass; builds `CloneChatManager` |
| `CloneChatConfig` | Per-bot config (extends `UtilityConfig`) |

---

## Arguments Reference

| Flag | Format | Description |
|------|--------|-------------|
| `-sc` | `chat_id`, `chat_id:thread_id`, `chat_id:tid1,tid2,...` | Source chat — see topic filtering below |
| `-dc` | `chat_id`, `chat_id:thread_id`, `users`, `allusers`, `members[:chat_id]` | Destination chat |
| `-mid` | `start-end` or `single` | Message ID range (default: `1-10`) |
| `-ft` | `video\|photo\|document\|...` | Filter by message type (pipe-separated) |
| `-sz` | `min-max` (e.g. `1MB-500MB`) | Filter by file size range |
| `-md` | `chat:thread;filter;size,chat2;filter2;size2` | Multi-destination config |
| `-rep` | `{"old": "new"}` or `none` | Text replacement dict, or `none` to strip captions |
| `-sync` | flag | Topic structure sync mode |
| `-f` | flag | Force run (no sleep between messages) |
| `-w` | `bot_id` | Override worker bot |

---

## Source Topic Filtering (`-sc`)

| Format | Behaviour |
|--------|-----------|
| `-sc chat_id` | Clone entire chat (all messages in range) |
| `-sc chat_id:thread_id` | Clone only messages from that one topic |
| `-sc chat_id:tid1,tid2,tid3` | Clone only from listed topics (for use with `-sync`) |

**Without `-sync`**: `_clone_single_destination()` skips messages whose `message_thread_id` is not in the filter list.

**With `-sync`**: `_setup_topic_sync()` fetches all source topics, keeps only those in the filter, creates/maps them in destination.

---

## Operation Modes

| Mode | Trigger | Handler |
|------|---------|---------|
| Single destination | Default (no `-md`, no `-sync`) | `_clone_single_destination()` |
| Multi-destination | `-md` flag | `_clone_multi_destination()` |
| Topic sync | `-sync` flag | `_clone_topic_sync()` |
| Broadcast | `-dc users` / `allusers` / `members` | `_clone_broadcast()` |

---

## `iter_users` — Cursor Timeout Hazard & Keyset Pagination Fix

`BotUsersCollection.iter_users` must iterate ALL users for a bot, which can be tens of
thousands. A naïve `collection.find(...).batch_size(1000)` approach opens **one long-lived
server-side cursor**. MongoDB keeps that cursor alive with a default 10-minute idle timeout.

### Why a single cursor stops mid-iteration

| Step | Clock |
|------|-------|
| `find()` — MongoDB returns first batch (≈1 000–1 001 docs) + cursor ID | t = 0 |
| Caller processes each doc with `asyncio.sleep(send_delay)` | +0.76 s per user |
| Local buffer exhausted, Motor calls `getMore` for batch 2 | t ≈ 760 s (12.7 min) |
| Server cursor expired (default 10 min idle) → `CursorNotFound` | iteration stops |

The exception escapes `iter_users`, is swallowed by the outer `except Exception` in the
clone loop, and the task exits cleanly reporting `COMPLETED` at ~1 001 / 22 881.

`no_cursor_timeout=True` is **not** the fix — it requires elevated MongoDB privileges and
in some driver/server combinations causes the cursor to return only 1 document.

### Fix — keyset pagination (fresh cursor per batch)

```python
async def iter_users(self, bot_id: int, batch_size: int = 1000) -> AsyncIterator[int]:
    last_id = None
    while True:
        query: dict = {"bot_id": bot_id}
        if last_id is not None:
            query["_id"] = {"$gt": last_id}
        docs = await (
            self.collection.find(query, projection={"user_id": 1})
            .sort("_id", ASCENDING)
            .limit(batch_size)
            .to_list(batch_size)
        )
        if not docs:
            break
        for doc in docs:
            yield doc["user_id"]
        last_id = docs[-1]["_id"]
```

Each `find(...).limit(batch_size).to_list(...)` completes in milliseconds — no cursor sits
idle on the server. The `_id` bookmark advances the window forward for the next batch.
This is applied to both `iter_users` and `iter_all_users` in
`database/collections/bot_users.py` and covers `-dc users`, `-dc allusers`, and broadcast.

---

## `allusers` Client Filter Rule

When `-dc allusers` is used, **only bot accounts** (`client.is_bot() == True`) are allowed to send messages.
User clients (`is_bot() == False`) are excluded at **two layers**:

1. **Population** (`bot/modules/special/chat_cloner.py`): `client_to_user_count` is built by iterating
   `bot_manager.get_all_clients()` and skipping any client where `not bot_client.is_bot()`.

2. **Execution guard** (`bot/service/chat_cloner.py`, `_clone_to_allusers`): any client that is
   not connected OR `not bot_client.is_bot()` is added to `user_bots_info` and skipped during send.

> **Important:** `start_menu`'s `client.user_tracker.record_user()` runs for every client type.
> Users recorded under a user-client are simply never reached by `allusers` because user clients
> are filtered out before querying `bot_users.get_user_count()`. No change to `record_user` is needed.

---

## `_clone_to_allusers` — Send Architecture

### Core invariant
User IDs are **partitioned by `client_id`** in the DB. `iter_users(client_id)` yields only that
bot's own users. Therefore each `(client, user)` pair is independent — no cross-client invalid-peer
caching is needed or correct.

### Per-message flow
```
worker.get_messages(source_chat_id, current_msg_id)   # fetched ONCE by main worker
    ↓ source_message.empty? → skipped_count += 1, continue
    ↓ text message? → text is already available, no download needed
    ↓ media message? → _download_media_to_path() called ONCE, file_path reused by all clients/users
    ↓ no text AND file_path is None? → skipped_count += 1, WARNING logged, continue
      (covers: too large >50MB, download failed, unsupported type — poll/contact/location/etc.)

for bot_client in active_clients:
    async for user_id in iter_users(client_id):   # bot_id is the filter key
        await _send_via_client(bot_client, source_message, user_id, file_path)
        # on failure: log debug, failed_count += 1, continue — no peer ID caching
```

### Critical: pre-validate message before user loop
If `source_message.text` is falsy AND `file_path` is `None`, **skip the entire message** with
`skipped_count += 1` and a WARNING. Do NOT enter the user loop — doing so would mark all
N users as failed (e.g. 46k failures in 5 seconds) for a problem that is per-message, not per-user.

### Why `get_messages()` is NOT called on other bot clients
The source message may live in a private chat that only the main worker bot is in. Other bots
cannot call `get_messages` for it. Instead, the main worker's `source_message` object already
contains the full content (text / media metadata), and media is downloaded once by the main worker
and sent from each bot client as a pre-uploaded file.

### `_send_via_client(bot_client, source_message, user_id, file_path)`
```python
# text message
if source_message.text:
    result = await bot_client.send_message(chat_id=user_id, text=text)

# media message (file already downloaded)
if file_path:
    return await self._send_media_file(bot_client, user_id, file_path, source_message, replace_dict)

# any exception → log debug, return False → caller increments failed_count
```
- **No `get_messages` call** — content already in `source_message`.
- **On failure**: returns `False`, caller increments `failed_count` and continues.
- No `_invalid_peer_ids` caching in this path — failures are per-(client, user) pair.

### `_invalid_peer_ids` — removed
This attribute has been removed. There is no persistent invalid-peer cache in any clone mode.
On `PEER_ID_INVALID` exception: `skipped_count += 1`, log at DEBUG, continue to next user.
Rationale: user IDs are per-bot, so a user being invalid for one send does not mean they are
permanently invalid across all messages or bot clients.

### `_has_sendable_content(message) → bool`
```python
return bool(message.text) or any(getattr(message, attr, None) for attr in MEDIA_ATTRS)
```
Used in ALL three clone methods **before** the per-user loop to skip messages that have no known
sendable content (poll, contact, location, service message, etc.).
- `users` / `members`: check before the user iterator
- `allusers`: the `file_path is None` check after download already covers this case; `_has_sendable_content` is also used for consistency

### Error string rule
All Pyrogram error checks use `getattr(e, "MESSAGE", str(e))` per project rule #11 — never `str(e)` alone.

---

## Media Group Support (`copy_media_group`)

When `message.media_group_id` is set, `_copy_message` automatically dispatches to `_copy_media_group_internal` instead of `copy_message`. This copies the entire album atomically with a single API call.

### Decision table

| `message.media_group_id` | `replace_dict` | Copy method used |
|--------------------------|----------------|------------------|
| None | any | `copy_message` (single message) |
| set | None / `"none"` | `copy_media_group` (whole album) |
| set | `dict` | `copy_message` per-message (fallback; preserves text replacement) |

### Deduplication — `seen_group_ids`

In a sequential message-ID loop (single, multi, topic-sync), multiple IDs in the range may share the same `media_group_id`. `_copy_message` accepts an optional `seen_group_ids: set | None`:

- **Not None** (single/multi-dest/topic-sync loops): first encounter copies the group and adds the `group_id` to the set; subsequent encounters return `0` → caller increments `skipped_count`.
- **None** (per-user loops — members, users): no deduplication; each user receives the full group independently.

```python
# Single destination
seen_group_ids: set[int] = set()
count = await self._copy_message(message, dest, seen_group_ids)
if count == 0:
    skipped_count += 1
else:
    self.success_count += count
    for _ in range(count):
        await self._record_successful_clone()

# Multi-destination — each dest has its own set
seen_group_ids_map: dict[str, set[int]] = {
    config["dest_chat_formatted"]: set() for config in dest_configs
}
dest_seen = seen_group_ids_map[config["dest_chat_formatted"]]
count = await self._copy_message(message, config["dest_chat_formatted"], dest_seen)

# Per-user (members/users) — pass no seen_group_ids (None default)
count = await self._copy_message(message, str(user_id))
success_count += count
for _ in range(count):
    await self._record_successful_clone()
```

### `_copy_media_group_internal` signature

```python
async def _copy_media_group_internal(
    self, message, dest_chat_id: int, dest_thread_id: int | None
) -> int:
    # Returns: number of messages in the copied group (≥1)
    # Uses captions="" when replace_dict == "none"
```

### Cost accounting
Each message in the group counts as one clone for billing. The caller calls `_record_successful_clone()` `count` times (one per group message returned).

---

## Cost Deduction Flow

Chat cloner cost deduction is **standardized through `TaskPolicy.deduct_destination_cost`** — the same entry point used by upload and GDrive/rclone clone tasks.

```
CloneChatManager._record_successful_clone()
    → _accumulated_cost += per-message cost
    → _deduct_accumulated_cost()         # batched mid-clone (threshold-based)

TaskListener.on_clone_complete() / on_clone_error()
    → policy.deduct_destination_cost(completed_index)
        → isinstance(state, CloneChatState)?
            → state._obj._deduct_accumulated_cost(force=True)   # final flush
        → return True
    → policy.unlock_task_balance()
```

**Key rules:**
- `CloneChatManager.start_cloning()` does **not** call `_deduct_accumulated_cost(force=True)` itself — no `try/finally` cost block.
- The final `force=True` flush is triggered by `policy.deduct_destination_cost()` when `is_clone_chat=True` and `state` is a `CloneChatState`.
- `_deduct_accumulated_cost(force=True)` calls `policy.unlock_task_balance()` internally; the subsequent call in the listener is idempotent (returns 0).
- On error, `on_clone_error()` also calls `policy.deduct_destination_cost()` → same flush path applies.
- `test_mode`: `policy.deduct_destination_cost()` returns `True` early before reaching the `is_clone_chat` branch — deduction is skipped entirely.

---

## Example Usage

```
# Clone messages 1–500 from a channel to another
/cc -sc -1001234567890 -dc -1009876543210 -mid 1-500

# Clone only one topic
/cc -sc -1001234567890:456 -dc -1009876543210:789 -mid 1-200

# Multi-destination with filter
/cc -sc -100123 -dc -100456:0;video,-100789;photo -mid 1-100

# Topic sync (mirror topic structure)
/cc -sc -100123:1,2,3 -dc -100456 -sync
```
