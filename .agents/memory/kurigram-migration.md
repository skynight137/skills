---
name: kurigram migration from pyrotgfork
description: Key API differences when moving from pyrotgfork to kurigram; both install under the pyrogram namespace so no import paths change.
---

# kurigram Migration from pyrotgfork

## Both install as `pyrogram`
`import pyrogram` and `from pyrogram import ...` work identically. No top-level import paths need changing.

## Breaking changes (all fixed, PyroClient starts successfully)

### 6. `MongoStorage.server_address()` / `port()` must return DC defaults for existing sessions
- kurigram's `connect()` passes `server_address=await storage.server_address()` and `port=await storage.port()` to `get_session()`
- `get_session()` hits `if not server_address or not port:` → calls `get_dc_option()` → `invoke(help.GetConfig())` → **"Client has not been started yet"** ConnectionError
- This only fires for **existing sessions** whose MongoDB docs predate kurigram — `server_address`/`port` fields are `None` (new fields)
- For fresh sessions `load_session()` sets defaults before `connect()` is called — no issue
- **Fix:** Override `server_address()` and `port()` to fall back to a static DC table when stored is `None`:
  ```python
  _DC_ADDRESS_TABLE = {1:"149.154.175.53", 2:"149.154.167.51", 3:"149.154.175.100", 4:"149.154.167.91", 5:"91.108.56.130"}
  _DC_DEFAULT_PORT = 443
  ```
  When `stored is None`: `server_address()` returns `_DC_ADDRESS_TABLE.get(dc_id or 2, "149.154.167.51")`; `port()` returns `443`.
- After first successful connect, kurigram calls `set_dc()` → `storage.server_address(value)` / `storage.port(value)` → values are persisted to MongoDB.

### 7. `update_peers` tuple format changed from 5 to 4 elements
- pyrotgfork: `update_peers([(peer_id, access_hash, type, usernames: list[str], phone_number), ...])`
- kurigram: `update_peers([(peer_id, access_hash, type, phone_number), ...])` — **4-tuple, no usernames**
- kurigram calls `update_usernames([(peer_id, [username, ...]), ...])` **separately** after `update_peers` for peers that have usernames
- `MongoStorage.update_peers` was changed from 5-tuple unpacking to 4-tuple; username handling stays in `update_usernames` which was already correctly implemented



### 1. Handler rename
- pyrotgfork: `ManagedBotUpdateHandler`
- kurigram:   `ManagedBotUpdatedHandler` (added "d")
- Fixed in: `bot/webhook/adapter.py` — import + `_fire_handlers` call

### 2. `CopyTextButton` removed — `copy_text` is now a plain `str`
- pyrotgfork: `InlineKeyboardButton(copy_text=CopyTextButton(text="…"))`
- kurigram: `InlineKeyboardButton(copy_text="…")` — pass the string directly, no wrapper
- Fixed in: `bot/utils/button_build.py` — removed `CopyTextButton` import and usage

### 3. `pyrogram.types.message_origin.*` subpackage moved
- pyrotgfork: `from pyrogram.types.message_origin.message_origin_channel import MessageOriginChannel`
- kurigram: `from pyrogram.types.messages_and_media.message_origin_channel import MessageOriginChannel`
- Same for `MessageOriginChat`, `MessageOriginHiddenUser`, `MessageOriginUser`
- Fixed in: `bot/webhook/adapter.py` lines 62-65

### 4. `Storage` base class added `server_address` and `port` as abstract methods
- kurigram `Storage` requires: `open`, `save`, `close`, `delete`, `update_peers`,
  `update_usernames`, `update_state`, `get_peer_by_id`, `get_peer_by_username`,
  `get_peer_by_phone_number`, `dc_id`, `api_id`, `server_address`, `port`,
  `test_mode`, `auth_key`, `date`, `user_id`, `is_bot`
- `server_address` and `port` are **new** abstract methods not in pyrotgfork
- Fixed in: `bot/client/mongo_storage.py` — added both using existing `_accessor` pattern,
  stored as session document fields

### 5. Managed bot token — native method replaces HTTP helper
- pyrotgfork: no native method → used `_fetch_managed_bot_token()` HTTP helper
- kurigram: `await client.get_managed_bot_token(bot_id)` → `bots.ExportBotToken(revoke=False)`
- kurigram: `await client.replace_managed_bot_token(bot_id)` → `bots.ExportBotToken(revoke=True)`
- Fixed in: `bot/modules/settings/bots/_bot_manage.py` — removed helper + HTTP import

### 9. `message_effect_id` renamed to `effect_id` in all send/reply methods
- pyrotgfork: `message.reply(..., message_effect_id=x)`, `send_message(..., message_effect_id=x)`
- kurigram: renamed to `effect_id=x` across all high-level send methods (`reply`, `send_message`, `send_photo`, etc.)
- `copy_media_group` does NOT have `effect_id` — drop that kwarg entirely when calling it
- Fixed in: `bot/modules/core/start.py`, `bot/utils/filters/role.py`

### 8. `send_as` dropped from all high-level send methods
- pyrotgfork: `send_message/send_video/send_document/send_photo/send_audio` all accepted `send_as=peer`
- kurigram: **removed** from all high-level send methods; exists only in raw `messages.SendMedia` / `messages.SendMessage`
- Replacement: `client.set_send_as_chat(chat_id, send_as_peer)` sets the persistent default for that chat before sending
- Verification pattern: `await worker.set_send_as_chat(dest, peer)` — raises `SendAsPeerInvalid` if inaccessible (replaces test-message send)
- Fixed in: `bot/service/telegram.py` `_msg_to_reply` (calls `set_send_as_chat` once per upload batch) + `bot/task/config.py` `_setup_send_as` (verification via `set_send_as_chat`)

## Safe aliases (no code change needed)
- `client.send_code()` — kept as alias for `send_phone_number_code()` in kurigram
- All storage APIs identical for existing methods: `SQLiteStorage`, `get_input_peer`, `in_memory=True`

## `business_user_connection_cache` — safe custom attribute
- kurigram does NOT have this attribute natively (pyrotgfork had it)
- `pyro_client.py` sets it manually: `self.business_user_connection_cache = Cache(...)`
- `__main__.py` reads it with `getattr(client, "business_user_connection_cache", None)` — safe
- No code change needed

## New parameters in kurigram `Client.__init__`
- `max_topic_cache_size: int` — new; topic cache size (default constant)
- `fetch_replies`, `fetch_topics`, `fetch_stories`, `fetch_stickers: Optional[bool]` — new
- `link_preview_options: Optional[LinkPreviewOptions]` — new
- `init_connection_params: Optional[dict]` — new
- `connection_factory`, `protocol_factory` — new
- `client_platform: enums.ClientPlatform` — new
- `storage_engine` → replaces `storage_engine` (same name, takes `Storage` instance)
- `loop` parameter added (optional asyncio event loop)

## New handlers in kurigram (not in pyrotgfork)
`BusinessConnectionHandler`, `BusinessMessageHandler`, `ChatBoostHandler`, `ConnectHandler`,
`DeletedBusinessMessagesHandler`, `EditedBusinessMessageHandler`, `ErrorHandler`,
`GuestMessageHandler`, `MessageReactionCountHandler`, `MessageReactionHandler`,
`StartHandler`, `StopHandler`

## New native bot methods in kurigram
- `client.get_managed_bot_token(user_id)` — fetch managed bot token via MTProto
- `client.replace_managed_bot_token(user_id)` — revoke + regenerate managed bot token
- `client.get_managed_bot_access_settings(user_id)` — read access settings
- `client.set_managed_bot_access_settings(user_id, ...)` — write access settings
- `client.create_bot(...)` — create a new bot
- `client.get_owned_bots()` — list all owned bots

## `ManagedBotUpdated` type in kurigram
Fields: `user` (User who created), `bot` (User — the managed bot). **No `token` field** — fetch separately with `get_managed_bot_token()`. The `getattr(mb, "token", None)` guard in `adapter.py` handles this safely.

**Why:** kurigram (KurimuzonAkuma fork) is more up-to-date with the Telegram API layer spec and adds native MTProto wrappers for managed-bot operations, plus new Storage abstract methods for DC-level session persistence.
