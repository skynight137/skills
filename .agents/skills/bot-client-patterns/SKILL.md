---
name: bot-client-patterns
<<<<<<< HEAD
description: Use this skill when working with bot/client/ — PyroClient properties, plugin management, TelegramAPIBridge, _safe_execute, FloodWait handling, or adding client-level functionality. Covers PyroClient properties, identity, managers, utility methods, and the TelegramAPIBridge.
=======
description: >-
  Use this skill when working with bot/client/ — PyroClient properties, plugin
  management, TelegramAPIBridge, _safe_execute, FloodWait handling, or adding
  client-level functionality. Covers PyroClient properties, identity, managers,
  utility methods, and the TelegramAPIBridge.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot Client Patterns

`PyroClient` (`bot/client/pyro_client.py`) extends Pyrogram `Client` with auto error handling, config integration, and plugin management.

---

## Module Layout (`bot/client/`)

| File | Contents |
|------|----------|
<<<<<<< HEAD
| `pyro_client.py` | `PyroClient` — core class: identity properties, config access, lifecycle (`start`/`stop`/`restart`), session/task helpers |
| `wrap_client.py` | `WrapClient`, `_safe_execute`, `_handle_flood_wait`, `_inject_default_params`, `DroppingQueue`, `wrap_pyrogram_methods` |
=======
| `pyro_client.py` | `PyroClient` — core class: identity properties, config access, lifecycle (`start`/`stop`/`restart`), session/task helpers. Uses `Cache` from `utils/lru_cache.py` for `message_cache` and `business_user_connection_cache` (maxsize from `TelegramModel.max_message_cache_size`, default 256 ≈ 1 MB). |
| `wrap_client.py` | `WrapClient`, `_safe_execute`, `_handle_flood_wait`, `_inject_default_params`, `PriorityDropQueue` (aliased as `DroppingQueue` — simple bounded drop-when-full queue), `wrap_pyrogram_methods` |
>>>>>>> 2ecb89d (update)
| `mixin_status.py` | `StatusMixin` — `get_tasks_status_message`, `send_status`, `update_status`, `delete_status` |
| `mixin_messaging.py` | `MessagingMixin` — `send_log`, `wait_for_message`, `get_tg_link_message`, `get_topup_message_buttons`, `get_chat_id` |
| `mixin_plugin.py` | `PluginMixin` — plugin add/remove, bot-command sync, `remove_handler` override |
| `manager.py` | `BotManager`, `bot_manager` singleton — multi-client registry |
| `state.py` | `BotState` dataclass — per-client locks, handler dict, user states, status dict, intervals |
| `telegram_bridge.py` | `TelegramAPIBridge` — HTTP Bot API with token rotation |

---

## Inheritance Chain

```
pyrogram.Client
  └── WrapClient             (wrap_client.py — all async methods wrapped with _safe_execute)
        └── StatusMixin      (mixin_status.py — task status display)
              └── MessagingMixin  (mixin_messaging.py — send_log, wait_for_message, link resolution)
                    └── PluginMixin  (mixin_plugin.py — plugin management, bot-command sync)
                          └── PyroClient  (pyro_client.py — core properties + lifecycle)
```

> Import path: `from bot.client import PyroClient, BotManager, BotState, bot_manager`
> Import `bot_manager` singleton: `from bot.client.manager import bot_manager`

---

## Key Properties

### Configuration

```python
client.config_bot        # BotConfig.get_instance(bot_id)
client.config_owner      # UserConfig.get_instance(owner_id)
client.config_telegram   # ConfigManager.TelegramConfig
client.config_manager    # ConfigManager (all configs)
client.wallet            # WalletConfig.get_instance(bot_id)
client.main_wallet       # WalletConfig.get_instance(main_bot_id)
```

### Identity

```python
client.bot_id            # int — current bot's Telegram ID
client.bot_username      # str — current bot's username
client.main_bot_id       # int — main bot's Telegram ID
client.main_bot_username # str — main bot's username
client.owner_id          # int — bot owner's user ID
client.dev_id            # int — developer's user ID
```

### Managers

```python
client.bot_manager        # BotManager — multi-bot management
client.task_manager       # TaskManager — task queue
client.db_manager         # DatabaseManager — DB access
client.service_controller # ServiceController — services
client.telegram_bridge    # TelegramAPIBridge (if configured)
```

### Access Control

```python
<<<<<<< HEAD
client.sudos             # list[int] — sudo user IDs
client.auths             # dict — authorized users per command
client.blacklists        # list[int] — blocked user IDs
client.force_sub_chats   # list[int] — required subscription chats
client.vip_chats         # list[int] — VIP chat IDs from products
client.rss_chats         # dict — RSS feed target chats
```

=======
client.sudos                  # list[int] — sudo user IDs
client.auths                  # dict — authorized users per command
client.blacklists             # list[int] — blocked user IDs
client.force_sub_chats        # list[int] — required subscription chats
client.force_sub_invite_links # dict[int, tuple[str|None, str|None]] — {chat_id: (title, invite_link)}
client.vip_chats              # list[int] — VIP chat IDs from products
client.rss_chats              # dict — RSS feed target chats
```

> `force_sub_invite_links` is populated once in `start()` via `_load_force_sub_invite_links()`.
> Each client loads its own `force_sub_chats`. The **main bot** additionally loads
> `GlobalConfig.default_force_sub_chats` because `add_force_sub_buttons` routes those
> through `main_client`.
> Call `await client.refresh_force_sub_invite_links(chat_id=None)` after updating
> force-sub config to reload all links without a full restart.

>>>>>>> 2ecb89d (update)
### Helpers

```python
client.commands          # BotCommands with prefix/suffix
client.cmd_prefix        # Command prefix from config
client.cmd_suffix        # Command suffix from config
client.download_path     # Per-bot download directory
client.copyright         # Copyright text
client.state             # BotState — user state management
client.user_tracker      # User interaction tracking
```

---

## Key Methods

### `send_log(text, is_private=False)`
Send log via TelegramAPIBridge (best-effort, non-blocking).

<<<<<<< HEAD
### `wait_for_message(query_or_message, pfunc, rfunc=None, doc=False, pho=False, text=True)`
Wait for user input with `GlobalConfig.input_timeout_seconds` timeout.
=======
**Standard dual-logging pattern** — always pair `_logger` + `send_log` for important events
so operators see them in both system logs and Telegram simultaneously:

```python
# ✅ Correct — important errors/warnings
error_msg = "Something went wrong: ..."
self._logger.warning(error_msg)   # system log
await self.send_log(error_msg)    # Telegram log chat

# ✅ For services where self.client may be None (TelegramService)
if self.client:
    await self.client.send_log(error_msg)
```

**Use dual-logging for:**
- Client violation / auth errors
- Bot loading failures at startup
- Plugin add/remove failures
- Force-sub invite link fetch failures
- Service restart failures
- Post-startup task timeouts or errors

**`_logger` only (no Telegram) for:**
- `debug` level messages
- Routine/internal state checks (health checks, rate-limit guards)
- Contexts where `send_log` is unavailable (pre-client startup, inside `send_log` itself)

### `wait_for_message(query_or_message, pfunc, rfunc=None, doc=False, pho=False, text=True)`
Wait for user input with `GlobalConfig.input_timeout_seconds` timeout.  
**Implementation:** event-driven via `asyncio.Event` — no polling loop. The internal handler sets `event_flag` when a matching message arrives; `asyncio.wait({t_msg, t_cancel}, timeout=..., return_when=FIRST_COMPLETED)` suspends until either fires. Zero CPU overhead regardless of how many users are concurrently waiting.
>>>>>>> 2ecb89d (update)

```python
# Wait for text reply
response = await client.wait_for_message(message, prompt_func)

# Wait for document
response = await client.wait_for_message(message, prompt_func, doc=True)
```

### `add_or_remove_plugin(include=None, exclude=None)`
Dynamically enable/disable plugins, reload handlers, persist to DB.

```python
await client.add_or_remove_plugin(include="mirror_leech")
await client.add_or_remove_plugin(exclude="admin")
plugins = await client.get_include_plugins()
<<<<<<< HEAD
available = client.available_plugins
```

=======
available = client.available_plugins   # scans bot/plugins/*.py
```

### Plugin manifests (`bot/plugins/__init__.py`)

Each plugin has a paired `bot/plugins/<name>.yaml` that declares its metadata. The loader is consumed internally by `set_webhook` to build the correct `allowed_updates` list; the API is also useful when inspecting plugin capabilities at runtime.

```python
from bot.plugins import load_all_manifests, get_plugin_update_types

manifests = load_all_manifests()          # dict[str, PluginManifest] — cached
m = manifests["basic"]
m.name                  # "basic"
m.description           # "Core handlers — start, help, settings …"
m.update_types          # ["message", "callback_query", "channel_post", "managed_bot"]
m.requires_main_bot     # False
m.enabled_by_default    # True

# Quick lookup used by set_webhook:
types = get_plugin_update_types("tools")  # ["message", "callback_query", "inline_query", "chosen_inline_result"]
```

**Important:** `available_plugins` (cached property) scans `*.py` files; manifests are loaded from `*.yaml` files. A plugin can exist without a manifest (graceful empty defaults), but **webhook mode silently drops updates for undeclared update types** — always create a YAML alongside any new `bot/plugins/<name>.py`.

>>>>>>> 2ecb89d (update)
### `get_tg_link_message(link)`
Parse Telegram message link and fetch the message. Supports ranges.

### `get_topup_message_buttons(message, chat_type, target_id)`
Generate payment buttons for wallet topup.

### `get_chat_id(chat_id)`
Parse `"chat_id:thread_id"` string into `(chat_id, thread_id)` tuple.

### Utility

```python
client.is_main_bot()            # True if this is the main bot
client.is_bot()                 # True if client is a bot (not user)
client.is_violation()           # True if account is restricted/scam/fake
client.reset_cached_properties()  # Force reload all cached props
await client.get_system_stats() # CPU, memory, disk (cached 5s)
```

---

## _safe_execute (Automatic)

<<<<<<< HEAD
All Pyrogram send methods are wrapped via `wrap_pyrogram_methods()` with:
=======
All Pyrogram **public async methods** are wrapped via `wrap_pyrogram_methods()` with:
>>>>>>> 2ecb89d (update)

| Error | Handling |
|-------|---------|
| `FloodWait` | Sleep + retry (up to 3x by default; unlimited if `accept_all_floodwait=True`) |
| `FloodPremiumWait` | Same as FloodWait |
| `MessageTooLong` | Convert to document upload |
<<<<<<< HEAD
| `MediaCaptionTooLong` | Truncate caption |
| Invalid markup | Strip markup + retry |
| Ignorable errors | Return `None` |

**Critical rule**: Do not catch `FloodWait` manually in module code — `_safe_execute` handles it. See `bot-error-handling` skill for full rules.
=======
| `MediaCaptionTooLong` | Truncate caption + retry via `_safe_execute(depth+1)` |
| Invalid markup | Strip markup + retry via `_safe_execute(depth+1)` |
| Ignorable errors | Return `None` |

**Critical rule**: Do not catch `FloodWait` manually in module code — `_safe_execute` handles it.

**Retry depth guard**: The `MediaCaptionTooLong` and `ReplyMarkupInvalid` recovery branches re-enter `_safe_execute` with `depth=depth+1` so that FloodWait protection covers the retry. When `depth >= 1` the retry falls back to a bare call — this prevents unbounded recursion while still giving flood-wait coverage on the first retry.

### One-shot unsafe bypass (`_unsafe_execute`)

Set `client._unsafe_execute = True` **immediately before** the method call you want to escape from `_safe_execute`.  The flag is **auto-cleared to `False`** by `_safe_execute` after one use — it must be re-set for every subsequent call that needs the bypass.

```python
# ✅ Correct — flag cleared after create_channel fires
client._unsafe_execute = True
chat = await client.create_channel(title)   # raw exceptions propagate; no retry, no swallowing

# ✅ For each call in a loop that must raise on error
for i in range(n):
    client._unsafe_execute = True
    chat = await client.create_supergroup(f"Group {i + 1}")
```

**When to use:**
- Operations where a Telegram error should immediately stop further attempts (e.g. account-creation flood / spam detection on `create_channel` / `create_supergroup`).
- Callers that need raw exceptions to surface inside their own `except` block (e.g. to `break` a loop and report failure without `_safe_execute` silently absorbing the error).

**Do not use for:**
- Normal messaging operations — `_safe_execute`'s FloodWait retry and ignorable-error handling are intentional there.
- Any method called inside `_notify_error` — that path must never re-enter `_safe_execute` recursively.

### Re-raise Critical Errors in `_safe_execute`

Exceptions that indicate a **fatal client condition** must always be re-raised so the error propagates correctly:

- `AuthKeyDuplicated` → re-raise after logging. Without `raise`, Pyrogram falls through to `authorize()` which blocks stdin with `"Enter phone number or bot token"`.

```python
except AuthKeyDuplicated as e:
    LOGGER.error("AuthKeyDuplicated", mention=mention, error=str(e))
    await _notify_error(client, str(e))
    raise  # ← required, do not remove
```

**Rule**: Any exception representing a **permanent, unrecoverable client state** must be re-raised. Swallowing it causes Pyrogram to attempt interactive recovery that blocks the process.

### Guard `client.me` Before Accessing Dependent Properties

A client that failed to start (e.g., `AuthKeyDuplicated`) has `self.me = None`. These will raise `AttributeError` if `client.me` is None:
- `self.bot_id` → `self.me.id`
- `self.config_bot` → `self.bot_id` → `self.me.id`
- `self.wallet`, `self.download_path`, `self.bot_username`, etc.

```python
# ✅ Correct
if getattr(client, "me", None) is not None:
    await client.send_log(...)

# ❌ Wrong — crashes if client failed to start
await client.send_log(...)
```

### Pyrogram Exception Messages

When surfacing exception reasons to users, use `getattr(e, "MESSAGE", str(e))` — Pyrogram exceptions expose a `MESSAGE` class attribute with the clean API error string; generic exceptions fall back to `str(e)`.

### Semaphored methods (`_SEMAPHORED_METHODS`)

Methods in this set go through `self._semaphore` (default `Semaphore(3)`) before executing,
limiting concurrency per-client. Add a method here when many concurrent callers could trigger
FloodWait on the same client:

```
send_message, send_photo, send_video, send_audio, send_document, send_animation,
send_voice, send_video_note, send_sticker, send_media_group, forward_messages,
copy_message, edit_message_text, edit_message_caption, edit_message_media,
edit_message_reply_markup, pin_message, unpin_message, delete_messages,
get_chat_member   ← throttled because check_user_access fires it on main_client for every user
```

### Error-notify deduplication (`_notify_error`)

`_notify_error` suppresses identical Telegram log messages that arrive within
`_ERROR_NOTIFY_DEDUP_WINDOW` (30 s) of each other. This prevents duplicate
Telegram notifications when many concurrent tasks hit the same error (e.g.
`USER_IS_BLOCKED` from parallel sends to the same blocked user).

Key design rules:
- **LOGGER calls are never suppressed** — the system log stays complete.
  Only the Telegram notify is deduplicated.
- Dedup check+write are pure dict ops (no `await` between them) → atomically
  safe in asyncio's single-threaded model.
- Cache is capped at `_ERROR_NOTIFY_CACHE_MAX` (200) entries; stale keys are
  swept on overflow.
- Constants to tune: `_ERROR_NOTIFY_DEDUP_WINDOW` (float, seconds),
  `_ERROR_NOTIFY_CACHE_MAX` (int, max live entries).

### Force-sub membership check rules (`add_force_sub_buttons`)

- `suppress(UserNotParticipant)` — expected "not a member" path
- **Any other exception** from `get_chat_member` (FloodWait exhausted, `ChatAdminRequired`,
  `PeerIdInvalid`, network error) → **log warning + show join button** (safe default — cannot
  confirm membership, so requiring the join is correct)
- **Never show ⚠️** to the end user for transient API errors — it is not actionable
- `invite_link is None` (bot not admin) → show non-URL callback button + log in user state
>>>>>>> 2ecb89d (update)

---

## Default Parameter Injection

`_inject_default_params()` automatically applies BotConfig defaults to all send calls:

```python
# These are injected from BotConfig — do not pass manually:
disable_notification    # from bot_disable_notification
protect_content         # from bot_protect_content
disable_link_preview    # from bot_disable_link_preview
has_spoiler             # from bot_has_spoiler (media only)
supports_streaming      # from bot_supports_streaming (video only)
```

### Covered method groups

| Group | Methods | Injected params |
|-------|---------|-----------------|
| `send_message` | `send_message` | `disable_notification`, `protect_content`, `link_preview_options` |
| `_MEDIA_SEND_METHODS` | `send_photo`, `send_video`, `send_audio`, `send_document`, `send_animation`, `send_voice`, `send_video_note`, `send_sticker`, `send_media_group` | `disable_notification`, `protect_content` (+ `has_spoiler`, `supports_streaming`, `disable_content_type_detection` where applicable) |
| `_PROTECTED_SEND_METHODS` | `copy_message`, `copy_media_group`, `forward_messages`, `forward_story`, `send_cached_media`, `send_checklist`, `send_contact`, `send_dice`, `send_game`, `send_invoice`, `send_location`, `send_paid_media`, `send_poll`, `send_venue` | `disable_notification`, `protect_content` |
| everything else | — | only injects if kwarg is already present AND is `None` (e.g. `post_story` which always passes `protect_content=None` by default) |

> **Key rule**: All methods in `_PROTECTED_SEND_METHODS` use `kwargs.get()` injection — config is applied even when the caller does not pass `protect_content` or `disable_notification` at all. Never pass these explicitly as `None` to `message.copy()`, `message.forward()`, or any method in this group — injection handles it automatically.

---

## TelegramAPIBridge

Lightweight HTTP bridge to Bot API with token rotation. Used for high-throughput sending (avoids session limits).

```python
# Access via client:
if client.telegram_bridge:
    await client.telegram_bridge.send_message(chat_id, text)
    await client.telegram_bridge.send_photo(chat_id, photo_url)
    await client.telegram_bridge.send_video(chat_id, video_path)
    await client.telegram_bridge.send_document(chat_id, doc_path)

# File size limits (raises exception if exceeded):
<<<<<<< HEAD
TelegramAPIBridge.check_file_size(file_size, "document")  # 50MB
TelegramAPIBridge.check_file_size(file_size, "photo")     # 10MB
=======
TelegramAPIBridge.file_size_approved(file_size, "document")  # 50MB
TelegramAPIBridge.file_size_approved(file_size, "photo")     # 10MB
>>>>>>> 2ecb89d (update)
```

```python
from bot.client.telegram_bridge import TooManyRequestsError

try:
    await bridge.send_message(chat_id, text)
except TooManyRequestsError:
    pass  # All tokens exhausted — FloodWait on all
```

Configured via `BotConfig.multi_bot_tokens` (list of tokens for rotation).

---

<<<<<<< HEAD
=======
## MongoDB Session Storage (`MongoStorage`)

All persistent clients use `MongoStorage` (`bot/client/mongo_storage.py`) instead of the default SQLite `.session` file. This is the **Single Source of Truth** for Pyrogram session data — any VPS node can start a client from the same MongoDB auth_key, eliminating `AuthKeyDuplicated` errors when moving deployments.

### Layout (`pyrogram` database — `PyrogramCollection`)

| Collection | `_id` | Content |
|---|---|---|
| `sessions` | `bot_id (int)` | Session: `dc_id`, `auth_key`, `user_id`, `api_id`, `test_mode`, `date`, `is_bot` |
| `peers` | `"<bot_id>:<peer_id>"` | Peer cache: `bot_id`, `peer_id`, `access_hash`, `type`, `phone_number`, `last_update_on` |
| `usernames` | `"<bot_id>:<username>"` | Username→peer_id map: `bot_id`, `peer_id (int)` |
| `update_state` | `"<bot_id>:<entity_id>"` | MTProto state: `bot_id`, `entity_id`, `pts`, `qts`, `date`, `seq` |

**Indexes** (created once per process via class-level `_indexes_ensured` flag):
- `peers`: compound `{bot_id, type, peer_id}` — iter_peers keyset + get_peer_count
- `peers`: partial `{bot_id, phone_number}` (strings only — excludes `null`)
- `usernames`: `{bot_id, peer_id}` — bulk delete-by-peer during update_usernames
- `update_state`: `{bot_id}` — fetch all MTProto states for a bot

### How it's wired

`TelegramService.build_client()` creates `MongoStorage` and replaces `client.storage`:

```python
client.storage = MongoStorage(
    bot_id=client_id,
    session_string=kwargs.get("session_string"),  # for first-time import only
)
```

`PyroClient.start()` propagates any BotConfig-overridden `session_string` into storage before `super().start()` opens it:

```python
if isinstance(self.storage, MongoStorage):
    self.storage._session_string = self.session_string  # sync final value
```

### Performance internals

- **`_session_cache`** — session document fields (`dc_id`, `auth_key`, `user_id`, …) are cached in memory after the first read. `_set` keeps the cache warm. `open()` primes the full cache in one query after the upsert. Avoids N×7 round-trips on per-bot startup.
- **`_indexes_ensured`** — index creation/migration runs once per instance. Prevents N×4 round-trips when `open()` is called on multiple bots or across reconnect cycles.
- **`update_peers` concurrency** — peer `bulk_write` and username `delete_many` target different collections and run via `asyncio.gather`. Username inserts follow sequentially (must come after the delete).
- **`get_input_peer`** — imported from `pyrogram.storage.sqlite_storage`. Pure function (no I/O) that maps `(peer_id, access_hash, type)` → the correct Pyrogram `InputPeer*` type.

### First-time session_string import

On the very first open (MongoDB doc freshly inserted), if `_session_string` is set, `MongoStorage.open()` calls `_import_from_session_string()` which delegates decoding to Pyrogram's own `SQLiteStorage(in_memory=True)` then writes the fields to MongoDB and primes `_session_cache`. Subsequent starts read directly from MongoDB — `session_string` is ignored.

### Peer cleanup

`delete(remove_peers=True)` — full wipe: removes all four per-bot collections concurrently (via `asyncio.gather`) then drops peer indexes. Clears `_session_cache`.  
`delete(remove_peers=False)` — removes only the session document; preserves peer/username/update_state collections to avoid `PeerIdInvalid` errors on reconnect.

### `_temp_client_for_validation`

The temporary validation client in `TelegramService` uses a plain `pyrogram.Client` with `in_memory=True` — it never touches MongoDB and is auto-stopped after validation.

---

>>>>>>> 2ecb89d (update)
## PyroClient Lifecycle

```python
await client.start()    # Load plugins, sync commands, start tracking
await client.stop()     # Cancel tasks, remove handlers, clean state
await client.restart()  # Graceful restart
```

---

<<<<<<< HEAD
=======
## Webhook vs Polling Mode (`no_updates`)

Controlled by **`BotModel.no_updates`** (per-bot, persisted in DB under the bot collection, requires restart):

| `no_updates` | Mode | Use case |
|---|---|---|
| `True` (default) | **Webhook** — Pyrogram starts with `no_updates=True`; MTProto connection is kept for sending/API calls but the update listener is disabled. Telegram pushes updates to `POST /api/v*/telegram/webhook/{bot_token}`. | All bot clients |
| `False` | **MTProto polling** — Pyrogram's dispatcher receives updates directly over the persistent MTProto connection. | User accounts, bots needing real-time polling |

**How it wires up in `PyroClient.start()`** (after `self_config_bot` block, before `super().start()`):
```python
self.no_updates = self_config_bot.no_updates  # applied in start(), not __init__
```
Pyrogram's `Client` reads `self.no_updates` during `start()` to decide whether to spawn the update listener.

**Webhook lifecycle — `mixin_plugin.py`** (mirrors `set_bot_commands`/`delete_bot_commands` pattern):

`set_webhook()` — called inside `async with self.lock:` in `start()`, right after `set_bot_cmds()`:
- Guards: `is_bot()`, `no_updates=True`, `WebsConfig.url` non-empty
- Builds URL: `{WebsConfig.url.rstrip('/')}/api/v2/telegram/webhook/{self.bot_token}`
- POSTs to `https://api.telegram.org/bot{token}/setWebhook` via `async_request`; sets `secret_token`, `allowed_updates=["message","edited_message","callback_query"]`, `drop_pending_updates=False`
- No-op (logs warning) when `WebsConfig.url` is not configured

`delete_webhook(drop_pending_updates=True)` — called in `stop()`, right after `delete_bot_commands()` and before `super().stop()`:
- Same guards as `set_webhook`
- POSTs to `https://api.telegram.org/bot{token}/deleteWebhook`

**Webhook endpoint** (`backend/api/public/endpoints/telegram.py`):
- Route: `POST /telegram/webhook/{bot_token}` — mounted in both `api_router_v1` and `api_router_v2`
- Security: validates `X-Telegram-Bot-Api-Secret-Token` header against `WebsModel.telegram_secret_token` (auto-generated via `token_urlsafe(32)` on first run)
- Routing: extracts `bot_id` from the token prefix (`int(bot_token.split(":")[0])`), looks up via `bot_manager.get_client(bot_id)`
- Drops silently (HTTP 200) on any validation failure — Telegram must not retry on bad secret or unknown bot
- Calls `dispatch_webhook_update(client, update_data)` from `bot/webhook/adapter.py`

**Adapter** (`bot/webhook/adapter.py`):
- `dispatch_webhook_update(client, update_data)` — entry point; handles `message`, `edited_message`, `callback_query` update types
- Parses Bot API JSON into Pyrogram types (`Message`, `User`, `Chat`, `MessageEntity`, `CallbackQuery`) using only constructor kwargs — no MTProto raw types required
- `_fire_handlers(client, update, handler_type)` — mirrors `dispatcher.handler_worker` exactly: iterates `dispatcher.groups`, checks handler type, calls `handler.check()` then `handler.callback()`, respects `StopPropagation` / `ContinuePropagation`, acquires `dispatcher.locks_list[-1]`
- All existing `MessageHandler`, `EditedMessageHandler`, `CallbackQueryHandler` registrations fire unchanged — no bot module changes needed

---

>>>>>>> 2ecb89d (update)
## BotConfig Integration

`config_bot` is a `@property` (not `@cached_property`) — it calls `BotConfig.get_instance(bot_id)` on every access, returning the live object from `collection.cache`. No cache reset is needed when config fields change; `update_fields()` updates the cached model in-place.

PyroClient reads from `BotConfig`:

| Config Field | Effect |
|-------------|--------|
| `bot_disable_notification` | Injected into all sends |
| `bot_protect_content` | Injected into all sends |
| `bot_disable_link_preview` | Injected into text sends |
| `bot_has_spoiler` | Injected into media sends |
| `bot_supports_streaming` | Injected into video sends |
<<<<<<< HEAD
| `bot_max_concurrent_transmissions` | Upload/download concurrency |
=======
>>>>>>> 2ecb89d (update)
| `accept_all_floodwait` | Unlimited FloodWait retries |
| `plugins` | List of enabled plugins |
| `multi_bot_tokens` | Tokens for TelegramAPIBridge |
