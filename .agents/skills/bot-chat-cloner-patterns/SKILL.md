---
name: bot-chat-cloner-patterns
<<<<<<< HEAD
description: Use this skill when working on the chat_cloner module (bot/modules/chat_cloner.py, bot/service/chat_cloner.py). Covers arguments, operation modes, source topic filtering, and multi-destination config.
=======
description: >-
  Use this skill when working on the chat_cloner module
  (bot/modules/chat_cloner.py, bot/service/chat_cloner.py). Covers arguments,
  operation modes, source topic filtering, and multi-destination config.
enabled: true
>>>>>>> 2ecb89d (update)
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
<<<<<<< HEAD
| `-dc` | `chat_id`, `chat_id:thread_id`, `users`, `allusers`, `members[:chat_id]` | Destination chat |
=======
| `-dc` | `chat_id`, `chat_id:thread_id`, `users`, `bots`, `channels`, `supergroups`, `groups`, `members[:chat_id]`, `admin`, `creator` | Destination chat |
>>>>>>> 2ecb89d (update)
| `-mid` | `start-end` or `single` | Message ID range (default: `1-10`) |
| `-ft` | `video\|photo\|document\|...` | Filter by message type (pipe-separated) |
| `-sz` | `min-max` (e.g. `1MB-500MB`) | Filter by file size range |
| `-md` | `chat:thread;filter;size,chat2;filter2;size2` | Multi-destination config |
| `-rep` | `{"old": "new"}` or `none` | Text replacement dict, or `none` to strip captions |
| `-sync` | flag | Topic structure sync mode |
<<<<<<< HEAD
| `-f` | flag | Force run (no sleep between messages) |
| `-w` | `bot_id` | Override worker bot |
=======
| `-f` | flag | Force run (batched — N sends then one sleep, then N more; no sleep every message) |
| `-w` | `bot_id` | Override worker bot |
| `-all` | flag | Broadcast peer target across ALL bot clients instead of just current one (dev only, 3× cost) |
| `-ec` | `bot_id1 bot_id2 ...` | Exclude specific bot client IDs from `-all` broadcast (space-separated, dev only) |

### `-dc admin` / `-dc creator` — Dialog Chat Targets (UserBot only)

Both targets snapshot the UserBot's dialog list at task-setup time and clone to every matching chat.

| Target | Filter | Access restriction |
|--------|--------|--------------------|
| `admin` | `chat.admin_privileges is not None` | UserBot worker required |
| `creator` | `getattr(chat, "is_creator", False)` | UserBot worker required |

- Worker **must** be a UserBot — regular bots cannot call `get_dialogs()` (MTProto only).
- Guard fires at `_setup_clone_chat` time with `TaskConfigError` if `worker.is_bot()`.
- Collected IDs stored in `task_config.dialog_chat_ids: list[int]`.
- Service dispatched via `_clone_to_dialog_chats()` — iterates per destination chat, uses independent `seen_group_ids` sets for media-group deduplication.
- Cost: standard 1× multiplier.
>>>>>>> 2ecb89d (update)

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

<<<<<<< HEAD
=======
## `-sync` — Smart Detection, Worker Dispatch & Edge Cases

### Source chat type detection (`_setup_topic_sync` step 1)

| Source type | `source_is_forum` | Action |
|-------------|------------------|--------|
| `ChatType.CHANNEL` | (any) | Flat sync — return early, `topic_map = {}` |
| Group / SUPERGROUP | `False` | Flat sync — return early, `topic_map = {}` |
| SUPERGROUP | `True` | Proceed with topic enumeration |

Uses `source_chat.type` (`ChatType` enum) and `source_chat.is_forum` (bool).

### Bot worker guard (`_setup_topic_sync` step 2)

When source is a forum supergroup, `worker.is_bot()` is checked **before** calling `get_forum_topics`. Bots cannot enumerate forum topics via MTProto (`BOT_METHOD_INVALID`). A `ChatCloneError` is raised immediately — no silent fallback.

> Caller must use a UserBot worker (`-w <userbot_id>`) when source is a forum.

### Destination topics — `_get_destination_topics_map` return contract

| Return value | Meaning |
|--------------|---------|
| `dict[str, int]` (possibly `{}`) | Destination IS a forum. Empty dict = fresh forum, no topics yet → create all. |
| `None` | Destination does NOT support topics (channel, non-forum, perm error) → caller decides. |

Previous design returned `{}` in both cases, making it impossible to distinguish "not a forum" from "fresh forum". The `None` sentinel fixes this.

### Destination `None` result (`_setup_topic_sync` step 4)

| `-f` flag | Behavior |
|-----------|----------|
| Not set | Raise `ChatCloneError` — propagates to TaskManager (fast stop, no swallowed errors) |
| Set | `topic_map = {}`, log warning, `send_log`, return → `_clone_with_sync` does flat sync |

### Worker iteration method (`_clone_with_sync`)

| Worker | Iteration | `-mid` required? |
|--------|-----------|-----------------|
| UserBot | `get_chat_history` (min/max bounds) | No (full history if omitted) |
| Bot | `get_messages` (explicit range loop) | **Yes — abort if missing** |

### Unmapped message (`_sync_process_message`)

When `topic_map` is populated but a specific `msg_thread_id` has no mapping:

| `-f` flag | Behavior |
|-----------|----------|
| Not set | Skip message |
| Set | Send to root chat |

When `topic_map` is empty (flat sync — channel/non-forum source, or dest not a forum + `-f`):
all messages go to root (`message_thread_id=None`), no per-message check needed.

### `_sync_process_message` helper

Per-message logic extracted from `_clone_with_sync` into a private method to avoid duplicating the full loop body across bot and userbot branches. Returns `tuple[int, int, int]` — `(skipped_count, failed_count, force_batch_count)`. Both callers pass and receive these counters explicitly (no nonlocal or closure state).

### Exception propagation — no swallowed errors

`_setup_topic_sync` has NO outer try/except. Errors from:
- `get_forum_topics` (source) — propagate directly to TaskManager
- `ChatCloneError` (dest not a forum + no `-f`) — propagates directly to TaskManager

Only `create_forum_topic` (per individual topic) is wrapped in try/except — a single topic creation failure should not abort the entire sync.

---

>>>>>>> 2ecb89d (update)
## Operation Modes

| Mode | Trigger | Handler |
|------|---------|---------|
| Single destination | Default (no `-md`, no `-sync`) | `_clone_single_destination()` |
| Multi-destination | `-md` flag | `_clone_multi_destination()` |
<<<<<<< HEAD
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
=======
| Topic sync | `-sync` flag | `_clone_with_sync()` |
| Bot users | `-dc users` | `_clone_to_peers(PeerType.USER)` |
| Bot bots | `-dc bots` | `_clone_to_peers(PeerType.BOT)` |
| Bot channels | `-dc channels` | `_clone_to_peers(PeerType.CHANNEL)` |
| Bot supergroups | `-dc supergroups` | `_clone_to_peers(PeerType.SUPERGROUP)` |
| Bot groups | `-dc groups` | `_clone_to_peers(PeerType.GROUP)` |
| All peers (any type) | `-dc <peer_target> -all` | `_clone_to_peers_by_all_clients()` |
| Members | `-dc members[:<chat_id>]` | `_clone_to_members()` |
| Dialog chats | `-dc admin` / `-dc creator` | `_clone_to_dialog_chats()` |

---

## `iter_peers` / `get_peer_count` — Peer Collection Source

Peer-based clone targets (`-dc users/bots/channels/supergroups/groups`) and
`-dc allusers` use **`PyrogramCollection`** (the Pyrogram MTProto peer
cache) instead of `BotUsersCollection`.

### Why peers instead of `bot_users`

| Collection | Written when | Scope |
|------------|-------------|-------|
| `bot_users` | User sends `/start` only | Only explicit opt-in users |
| `peers_<bot_id>` | **Every** MTProto exchange (start, any message in managed group, admin action, inline query, …) | All peers the bot has ever exchanged with |

`UserInteractionTracker` + `bot_users` is **kept** for `is_new_user` detection in
`start_menu` (referral / XMissions system). Only the broadcast/clone targeting uses peers.

### Supported peer types

| `-dc` target | `PeerType` | Notes |
|-------------|-----------|-------|
| `users` | `PeerType.USER` (`"user"`) | Human users; blacklist applied |
| `bots` | `PeerType.BOT` (`"bot"`) | Telegram bot accounts |
| `channels` | `PeerType.CHANNEL` (`"channel"`) | Broadcast channels |
| `supergroups` | `PeerType.SUPERGROUP` (`"supergroup"`) | Supergroups / megagroups |
| `groups` | `PeerType.GROUP` (`"group"`) | Basic groups |

`BroadcastTarget.to_peer_type(dest_chat)` returns a typed `PeerType` value (a `StrEnum` so it is
directly comparable to plain strings). `PeerType` lives in `bot.utils.constants.tasks` and is
re-exported from `bot.utils.constants`.

### `PyrogramCollection.iter_peers` — keyset pagination

Peer documents: `{ _id: peer_id (int), type: str, access_hash, … }`.

**Peer ID sign convention** (critical — getting this wrong silently yields 0 results):

| Peer type | `_id` sign | Example |
|-----------|-----------|---------|
| `"user"`, `"bot"` | **positive** | `1234567890` |
| `"channel"`, `"supergroup"`, `"group"` | **negative** | `-2156516489` |

IDs are stored as the negation of the MTProto `channel_id` / `chat_id`, matching
Pyrogram's `peer.id` property. Pyrogram's `resolve_peer` handles negative IDs
correctly — it maps them back to `InputPeerChannel(channel_id=abs(id), access_hash=...)`.

**Keyset pagination must start at `-(2**62)`**, not `0`. Starting at `0` causes
`_id > 0` to filter out every channel/supergroup/group peer, so `iter_peers` yields
nothing for those types even though `get_peer_count` returns the correct non-zero count.

```python
# database/collections/pyrogram.py
async def iter_peers(self, bot_id: int, peer_type: str, batch_size: int = 1000) -> AsyncIterator[int]:
    col = self.get_peers_collection(bot_id)
    last_id: int = -(2**62)  # must be negative — channels/supergroups have negative _id
    while True:
        docs = await (
            col.find({"type": peer_type, "_id": {"$gt": last_id}}, {"_id": 1})
>>>>>>> 2ecb89d (update)
            .sort("_id", ASCENDING)
            .limit(batch_size)
            .to_list(batch_size)
        )
        if not docs:
            break
        for doc in docs:
<<<<<<< HEAD
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

=======
            yield doc["_id"]
        last_id = docs[-1]["_id"]

async def get_peer_count(self, bot_id: int, peer_type: str) -> int:
    col = self.get_peers_collection(bot_id)
    return await col.count_documents({"type": peer_type})
```

### Why keyset pagination (same reason as `BotUsersCollection`)

A naïve `collection.find(...).batch_size(1000)` opens **one long-lived server-side cursor**.
MongoDB's default 10-minute idle timeout expires mid-iteration when each send includes a
`send_delay` sleep — the task silently exits at ~1 001 / 22 881 users reporting `COMPLETED`.

Keyset pagination issues a fresh `find().limit(batch_size).to_list()` per batch —
each completes in milliseconds. No cursor stays open on the server between batches.

---

## `-all` Flag — Dev-Only Restriction

`-all` is **restricted to dev** at arg-parse time. It applies to any peer-based `-dc` target
(`users`, `bots`, `channels`, `supergroups`, `groups`) and activates `_clone_to_peers_by_all_clients()`.

```python
# bot/modules/mirror_leech/chat_cloner.py — _setup_clone_chat()
elif dest_chat == BroadcastTarget.USERS:
    if args.get(ArgFlags.ALL, False):
        if self.user_id != self.client.dev_id:
            raise TaskConfigError("❌ `-all` flag is restricted to dev only.")
        self.is_by_all_clients = True
        self.target_peer_type = PeerType.USER
        ...
# same pattern in the general peer_type block
```

**Rationale:** All owners can run sudo commands. If `-all` were open to all owners, concurrent
broadcast tasks from multiple owners could simultaneously iterate millions of peers, triggering
cascading FloodWait and potential crashes. Restricting to dev ensures only one operator controls
global broadcasts.

---

## `-all` Client Filter Rule

When `-all` flag is used, **only bot accounts** (`client.is_bot() == True`) are allowed to send messages.
User clients (`is_bot() == False`) are excluded at **two layers**:

1. **Population** (`bot/modules/mirror_leech/chat_cloner.py`): `client_to_user_count` is built by iterating
   `bot_manager.get_all_clients()` and skipping any client where `not bot_client.is_bot()`.

2. **Execution guard** (`bot/service/chat_cloner.py`, `_clone_to_peers_by_all_clients`): any client that is
   not connected OR `not bot_client.is_bot()` is added to `inactive_clients` and skipped during send.

### `-ec` — Exclude Clients

`-ec bot_id1 bot_id2 ...` lets dev exclude specific bot client IDs from the `-all` broadcast.

Exclusion happens at **population time** (layer 1 above): excluded bots are skipped before
`client_to_user_count` is built, so they are never iterated, never counted toward total peers,
and incur zero cost.

```python
# Inside the -all path of _setup_clone_chat():
ec_raw = args.get(ArgFlags.EXCLUDE_CLIENT, "").strip()
excluded_client_ids: set[int] = {int(x) for x in ec_raw.split()} if ec_raw else set()

for bot_client in all_clients.values():
    if not bot_client.is_bot():
        continue
    if bot_client.bot_id in excluded_client_ids:
        continue   # ← excluded via -ec; not added to client_to_user_count
    ...
```

The service (`_clone_to_peers_by_all_clients`) requires **no change** — it only iterates `client_to_user_count`,
which already excludes the specified bots.

---

## `_clone_to_peers_by_all_clients` — Send Architecture

### Core invariant
Peer IDs are **partitioned by `client_id`** in the DB. `iter_peers(client_id, peer_type)` yields
only that bot's own peers of the given type. Therefore each `(client, peer)` pair is independent —
no cross-client invalid-peer caching is needed or correct.

The peer type is determined by `target_peer_type` (`PeerType`) set at task-setup time, matching
whatever `-dc` target was combined with the `-all` flag.

### Per-message flow (sequential mode — default)
```
worker.get_messages(source_chat_id, current_msg_id)   # fetched ONCE by worker (must be in source chat)
    ↓ source_message.empty? → skipped_count += 1, continue
    ↓ text message? → text is already available, no download needed
    ↓ media message? → _download_media_to_path() called ONCE → file_path
    ↓ no text AND file_path is None? → skipped_count += 1, WARNING logged, continue
      (covers: too large >50MB, download failed, unsupported type — poll/contact/location/etc.)

client_init_file_ids: dict[int, str] = {}   # reset per message

for bot_client in active_clients:
    async for peer_id in iter_peers(client_id, target_peer_type):   # bot_id + peer_type are the filter keys
        cached_fid = client_init_file_ids.get(client_id)
        success, new_fid = await _send_via_client_chained(
            bot_client, source_message, peer_id, file_path, cached_fid
        )
        if success and new_fid and client_id not in client_init_file_ids:
            client_init_file_ids[client_id] = new_fid   # lock in first file_id

# After all clients done: delete file_path immediately (each client has a file_id now)
```

### Per-client file_id chain — why only 1 upload per client
Telegram `file_id` values are **bot-specific** — a file_id obtained by bot A cannot be reused
by bot B. Therefore:
- **First user of client N** → real upload from local disk → `result.{media}.file_id` captured
- **All subsequent users of client N** → pass `file_id` directly to `send_video/send_document/…`
  → Telegram serves the file from its own servers — no disk I/O, no network upload

Total uploads per message = **1 per active client** (not 1 per user).
Local file is deleted immediately after the client loop exits for that message.

### Force-run path (`-f` flag) — unchanged
Concurrent tasks cannot chain `file_id` (all tasks are dispatched before any result arrives).
The force-run path (`_send_via_client_forced`) continues to upload from `file_path` for every user.
Use sequential mode (default) when targeting large user counts with media.

>>>>>>> 2ecb89d (update)
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
<<<<<<< HEAD
=======
Used only by the **force-run path** and `_send_via_client_forced`.
>>>>>>> 2ecb89d (update)
```python
# text message
if source_message.text:
    result = await bot_client.send_message(chat_id=user_id, text=text)

# media message (file already downloaded)
if file_path:
    return await self._send_media_file(bot_client, user_id, file_path, source_message, replace_dict)

<<<<<<< HEAD
# any exception → log debug, return False → caller increments failed_count
=======
# any exception → log error, return False → caller increments failed_count
>>>>>>> 2ecb89d (update)
```
- **No `get_messages` call** — content already in `source_message`.
- **On failure**: returns `False`, caller increments `failed_count` and continues.
- No `_invalid_peer_ids` caching in this path — failures are per-(client, user) pair.

<<<<<<< HEAD
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
=======
### `_send_via_client_chained(bot_client, source_message, user_id, file_path, cached_file_id)`
Used by the **sequential path** of `_clone_to_peers_by_all_clients` only.
Returns `tuple[bool, str | None]` — (success, telegram_file_id).

```python
if cached_file_id:
    # Re-use file_id: no local disk read, no upload
    result = await bot_client.send_video(video=cached_file_id, ...)  # or photo/audio/document
else:
    # First send for this client: upload from disk, capture file_id
    mime = await file_path.mime()
    result = await bot_client.send_video(video=str(file_path), ...)

# Extract file_id from result (only when not already cached)
result_file_id = getattr(result.video, "file_id", None)  # (or .photo, .audio, .document …)
return True, result_file_id
```
- On failure: returns `(False, cached_file_id)` so subsequent users still use the cached id.

### `_invalid_peer_ids` — removed
This attribute has been removed. There is no persistent invalid-peer cache in any clone mode.
On `PEER_ID_INVALID` exception (and all other send errors): `failed_count += 1`, continue to next user.
Rationale: `PEER_ID_INVALID` is a real delivery failure — the peer no longer exists or was never
reachable. Counting it as skipped hid real failures from the task report.

### Blacklist filtering — combined per-bot + global

Two sources are merged and snapshotted **once before the loop** — O(1) per-user lookup during send, no DB access in the hot path.

| Source | Where stored |
|--------|-------------|
| Per-bot blacklist | `client.blacklists` → `client.config_bot.blacklists` |
| Global blacklist | `worker.db_manager.records.snapshots[uid].blacklisted == True` |

#### `_clone_to_members` / `_clone_to_peers` — single worker, single combined set

```python
_global_bl: set[int] = {uid for uid, rec in worker.db_manager.records.snapshots.items() if rec.blacklisted}
blacklists: set[int] = set(worker.blacklists) | _global_bl
```

| Method | Where checked |
|--------|---------------|
| `_clone_to_members` | At member-fetch time: `member.user.id not in blacklists` — excluded from `member_ids` list entirely |
| `_clone_to_peers` | Inline in worker queue: `if uid in blacklists: skipped_count += 1` |

#### `_clone_to_peers_by_all_clients` — per-client blacklist dict (users only)

Blacklist filtering is only applied when `target_peer_type == PeerType.USER`. For other peer types
(bots, channels, supergroups, groups) the blacklist dicts are empty — there is no concept of
blacklisting a channel/group from receiving messages.

When `target_peer_type == PeerType.USER`: peers are **partitioned by `client_id`** in the DB. A user
blacklisted on client A is irrelevant to client B, and client B may have a completely different
per-bot blacklist. A single merged set would either over-block (union of all clients) or under-block
(only the worker's list). The correct model is one set per client:

```python
if self._target_peer_type == PeerType.USER:
    _global_bl: set[int] = {uid for uid, rec in worker.db_manager.records.snapshots.items() if rec.blacklisted}
    client_blacklists: dict[int, set[int]] = {
        cid: (set(bot_cl.blacklists) | _global_bl)
        for cid, (bot_cl, _) in client_to_user_count.items()
    }
else:
    _global_bl: set[int] = set()
    client_blacklists: dict[int, set[int]] = {}
```

In the send worker, `cid` is available from the queue item `(cid, bot_cl, uid)`:

```python
if uid in client_blacklists.get(cid, _global_bl):
    skipped_count += 1
```

The `_global_bl` fallback in `.get()` is a safety net — `cid` will always be in the dict under
normal operation.

Blacklisted users increment `skipped_count` and are reported in the progress bar.

---
>>>>>>> 2ecb89d (update)

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

<<<<<<< HEAD
=======
### `reply_markup` preservation

Telegram's `copyMessage` API does **not** forward the source message's `reply_markup`. It must be passed explicitly. All `copy_message` calls (across every `replace_dict` branch) include `reply_markup=message.reply_markup` in `copy_kwargs`. The `send_message` path (used when `replace_dict` is dict + text-only message) also includes `reply_markup=message.reply_markup` in `send_kwargs`.

`copy_media_group` does **not** support per-message `reply_markup` — Telegram API limitation.

### Entity preservation during text replacement

When `replace_dict` is a dict, the code uses `message.text.html` / `message.caption.html` (kurigram `Str.html` property) to get the HTML-serialised form of the text **with entities**. Replacement is applied to this HTML string. The result is sent via `send_message(text=...)` or `copy_message(caption=...)` — both use `ParseMode.HTML` (inherited from `PyroClient.parse_mode`) so links, bold, italic and other formatting survive.

When `replace_dict is None`, `copy_message` copies the message verbatim — entities and reply_markup are both preserved (entities by Telegram, reply_markup by explicit kwarg).

>>>>>>> 2ecb89d (update)
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

<<<<<<< HEAD
=======
## Force Run (`-f`) — Sequential Batched Execution

When `task_config.force_run` is `True`, clone methods run **sequentially** (same `await
_copy_message` / `await _send_via_client_chained` calls as the normal path) but use a
**batch sleep** model instead of sleeping after every message.

### Why sequential (not parallel gather)?

`asyncio.gather` with concurrent Telegram API calls caused the task to **hang** because:
- FloodWait inside `_safe_execute` makes one task sleep; `gather` blocks until **all** tasks
  finish — including the sleeping one.
- `_clone_to_peers_by_all_clients` with gather dropped the file_id chaining, causing every user to trigger
  a full file upload — overwhelming Telegram and triggering cascading throttles.

Sequential force-run avoids these problems. `_safe_execute`'s own `Semaphore(3)` already
limits Pyrogram concurrency at the client level — no extra parallelism layer is needed.

### Batch size constant

```python
_FORCE_BATCH_SIZE: int = 10   # bot/service/chat_cloner.py, module-level constant
```

Every `_FORCE_BATCH_SIZE` successful sends, one `send_message_delay` sleep is inserted.
This paces throughput without sleeping after every single message.

### Pattern inside every clone loop

```python
force_batch_count = 0            # declared once before the main while loop
while current_msg_id <= end_msg_id:
    if task_config.is_cancelled:
        break

    # ... fetch & filter message ...

    try:
        count = await self._copy_message(message, dest, seen_group_ids)
        if count == 0:
            skipped_count += 1
        else:
            self.success_count += count
            for _ in range(count):
                await self._record_successful_clone()
            if not force_run:
                await asyncio.sleep(send_delay)       # normal path: sleep every message
            else:
                force_batch_count += count
                if force_batch_count >= _FORCE_BATCH_SIZE:
                    await asyncio.sleep(send_delay)   # force path: sleep every N sends
                    force_batch_count = 0
    except Exception as e:
        failed_count += 1
        ...
```

`force_batch_count` persists across the entire task — rate control is continuous over
the whole run, not reset per message.

### `allusers` force path — file_id chaining preserved

`_clone_to_allusers` uses `_send_via_client_chained` for **both** force and non-force paths.
The batch sleep gate sits inside the `if success` block (sleep is tied to successful sends only):

```python
if success:
    self.success_count += 1
    await self._record_successful_clone()
    if new_fid and client_id not in client_init_file_ids:
        client_init_file_ids[client_id] = new_fid
    if not force_run:
        await asyncio.sleep(send_delay)
    else:
        force_batch_count += 1
        if force_batch_count >= _FORCE_BATCH_SIZE:
            await asyncio.sleep(send_delay)
            force_batch_count = 0
else:
    failed_count += 1
```

This preserves the 1-upload-per-client optimization in force mode.

### Methods updated

All six clone methods follow the unified pattern:

| Method | Copy call |
|--------|-----------|
| `_clone_with_sync` | `_copy_message` (via `_sync_process_message`) |
| `_clone_to_members` | `_copy_message` |
| `_clone_to_peers` | `_copy_message` |
| `_clone_to_peers_by_all_clients` | `_send_via_client_chained` |
| `_clone_single_destination` | `_copy_message` |
| `_clone_multi_destination` | `_copy_message` |

> **Removed**: `_clone_with_topic_sync`, `_clone_topic_sync` — merged into `_clone_with_sync`.
> `_FORCE_CONCURRENCY`, `_force_semaphore`, `_copy_message_forced`,
> `_send_via_client_forced`, `_drain_copy_tasks`, `_drain_send_tasks` — no longer exist.

---

>>>>>>> 2ecb89d (update)
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
