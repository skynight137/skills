---
name: bot-client-patterns
description: Use this skill when working with bot/client/ — PyroClient properties, plugin management, TelegramAPIBridge, _safe_execute, FloodWait handling, or adding client-level functionality. Covers PyroClient properties, identity, managers, utility methods, and the TelegramAPIBridge.
---

# Bot Client Patterns

`PyroClient` (`bot/client/pyro_client.py`) extends Pyrogram `Client` with auto error handling, config integration, and plugin management.

---

## Module Layout (`bot/client/`)

| File | Contents |
|------|----------|
| `pyro_client.py` | `PyroClient` — core class: identity properties, config access, lifecycle (`start`/`stop`/`restart`), session/task helpers |
| `wrap_client.py` | `WrapClient`, `_safe_execute`, `_handle_flood_wait`, `_inject_default_params`, `DroppingQueue`, `wrap_pyrogram_methods` |
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
client.sudos             # list[int] — sudo user IDs
client.auths             # dict — authorized users per command
client.blacklists        # list[int] — blocked user IDs
client.force_sub_chats   # list[int] — required subscription chats
client.vip_chats         # list[int] — VIP chat IDs from products
client.rss_chats         # dict — RSS feed target chats
```

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

### `wait_for_message(query_or_message, pfunc, rfunc=None, doc=False, pho=False, text=True)`
Wait for user input with `GlobalConfig.input_timeout_seconds` timeout.

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
available = client.available_plugins
```

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

All Pyrogram send methods are wrapped via `wrap_pyrogram_methods()` with:

| Error | Handling |
|-------|---------|
| `FloodWait` | Sleep + retry (up to 3x by default; unlimited if `accept_all_floodwait=True`) |
| `FloodPremiumWait` | Same as FloodWait |
| `MessageTooLong` | Convert to document upload |
| `MediaCaptionTooLong` | Truncate caption |
| Invalid markup | Strip markup + retry |
| Ignorable errors | Return `None` |

**Critical rule**: Do not catch `FloodWait` manually in module code — `_safe_execute` handles it. See `bot-error-handling` skill for full rules.

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
TelegramAPIBridge.check_file_size(file_size, "document")  # 50MB
TelegramAPIBridge.check_file_size(file_size, "photo")     # 10MB
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

## PyroClient Lifecycle

```python
await client.start()    # Load plugins, sync commands, start tracking
await client.stop()     # Cancel tasks, remove handlers, clean state
await client.restart()  # Graceful restart
```

---

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
| `bot_max_concurrent_transmissions` | Upload/download concurrency |
| `accept_all_floodwait` | Unlimited FloodWait retries |
| `plugins` | List of enabled plugins |
| `multi_bot_tokens` | Tokens for TelegramAPIBridge |
