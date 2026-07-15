---
name: bot-settings-patterns
<<<<<<< HEAD
description: Use this skill when working on settings modules (bot/modules/settings/bots/ or users.py). Covers bot_manage and userset callback schemas, state management, reply contract, and handler routing.
=======
description: >-
  Use this skill when working on settings modules (bot/modules/settings/bots/ or
  users.py). Covers bot_manage and userset callback schemas, state management,
  reply contract, and handler routing.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot — Settings Patterns

Reference for settings modules: `bot/modules/settings/bots/` (package) and `bot/modules/settings/users.py`.

### `bots/` Package Structure

| File | Responsibility |
|------|---------------|
| `__init__.py` | Re-exports public API — `bot_settings`, `bot_settings_callback`, `bot_manage_menu`, `bot_manage_callback` |
<<<<<<< HEAD
| `_constants.py` | Module-level shared constants: `SERVICE_ACTIONS`, `SERVICE_ALIASES`, `telegram_service`, `global_config`, `bot_config`, `BOT_CONFIG_KEYS*`, `BOT_BUNDLE_KEYS` |
=======
| `_constants.py` | Module-level shared constants: `SERVICE_ACTIONS`, `SERVICE_ALIASES`, `telegram_service`, `global_config`, `bot_config`, `BOT_CONFIG_KEYS`, `BOT_CONFIG_EXCLUDE_KEYS`, `BOT_CONFIG_EXCLUDE_KEYS_EXTENDED`, `BOT_BUNDLE_KEYS` |
>>>>>>> 2ecb89d (update)
| `_helpers.py` | Input handler functions: `validate_and_restore_bot_config`, `edit_global_config`, `edit_bot_config`, `edit_service_config`, `update_server_config_file`, `add_new_bot_input` |
| `_bot_settings.py` | `bot_settings` (renderer) + `bot_settings_callback` (callback handler for `BOT_SET` prefix) |
| `_bot_manage.py` | `bot_manage_menu` (renderer) + `bot_manage_callback` (callback handler for `BOT_MANAGE` prefix) |

Imports in `basic.py` (`from bot.modules.settings.bots import ...`) remain unchanged — Python resolves the package `__init__.py` transparently.

---

## Handler Registration (`bot/plugins/basic.py`)

```python
# Bot settings
<<<<<<< HEAD
@Client.on_message(filters.command(BotCommands.bot_settings) & filters.private)
=======
@Client.on_message(filters.command(BotCommands.bot_settings) & filters.private_bot)
>>>>>>> 2ecb89d (update)
async def _bot_settings(client, message):
    from bot.modules.settings.bots import bot_settings
    await bot_settings(client, message, reply=True)

<<<<<<< HEAD
@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.BOT_SET}") & filters.private)
=======
@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.BOT_SET}") & filters.private_bot)
>>>>>>> 2ecb89d (update)
@new_task
async def _bot_settings_callback(client, query):
    from bot.modules.settings.bots import bot_settings_callback
    await bot_settings_callback(client, query)

<<<<<<< HEAD
@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.BOT_MANAGE}") & filters.private)
=======
@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.BOT_MANAGE}") & filters.private_bot)
>>>>>>> 2ecb89d (update)
@new_task
async def _bot_manage_callback(client, query):
    from bot.modules.settings.bots import bot_manage_callback
    await bot_manage_callback(client, query)

# User settings
<<<<<<< HEAD
@Client.on_message(filters.command(BotCommands.user_settings) & filters.private)
=======
@Client.on_message(filters.command(BotCommands.user_settings) & filters.private_bot)
>>>>>>> 2ecb89d (update)
async def _user_settings(client, message):
    from bot.modules.settings.users import user_settings
    await user_settings(client, message, reply=True)

<<<<<<< HEAD
@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.USER_SET}") & filters.private)
=======
@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.USER_SET}") & filters.private_bot)
>>>>>>> 2ecb89d (update)
@new_task
async def _user_settings_callback(client, query):
    from bot.modules.settings.users import user_settings_callback
    await user_settings_callback(client, query)
```

---

## reply=True / reply=False Contract

- `reply=True` — only from a **command handler** (first display; creates a new message)
- `reply=False` (default) — every **callback-driven** call; edits the existing message in place

This keeps one persistent message toggled between views — no stale messages accumulate.

---

## `bot_manage` Callback Schema

```
# Root level (no bot selected)
bot_manage {user_id} add
<<<<<<< HEAD
bot_manage {user_id} allbots                    # dev only
=======
bot_manage {user_id} bulk {start|stop|restart}                  # owner-scoped bulk action
bot_manage {user_id} allbots                                    # dev only
bot_manage {user_id} filter {all|connected|disconnected}        # dev only — allbots status filter
>>>>>>> 2ecb89d (update)
bot_manage {user_id} ps {new_start} [allbots]
bot_manage {user_id} back
bot_manage {user_id} close

# Per-bot level (d2 is numeric bot_id)
bot_manage {user_id} {bot_id} manage
bot_manage {user_id} {bot_id} plugins
bot_manage {user_id} {bot_id} crud {key}
bot_manage {user_id} {bot_id} ps {new_start} {action}
bot_manage {user_id} {bot_id} start|stop|restart
bot_manage {user_id} {bot_id} remove
bot_manage {user_id} {bot_id} toggle_plugin {name}
bot_manage {user_id} {bot_id} default|toggle {key} [value]
bot_manage {user_id} {bot_id} backup|restore manage
bot_manage {user_id} {bot_id} reset manage
bot_manage {user_id} {bot_id} back [action]
bot_manage {user_id} {bot_id} close
```

**Ownership check**: `user_bot.owner_id != user_id` → reject. **Dev bypass**: skip ownership check when `user_id == client.dev_id`.

<<<<<<< HEAD
=======
**Server-wide client limit** (`add` action): before showing the input form, non-dev users are checked against `GlobalConfig.max_total_clients`. If `max_total_clients > 0` and `len(bot_manager.get_all_clients()) >= max_total_clients`, the callback answers with `show_alert=True` and returns early. Dev always bypasses this check. `max_total_clients = 0` means unlimited.

>>>>>>> 2ecb89d (update)
**64-byte limit reminder**: longest realistic string ~45 bytes. Always verify with `len(cb.encode())`.

---

## `userset` Callback Schema

```
# Navigation
userset {user_id} {category}
userset {user_id} {category} {field_key}
userset {user_id} back [target_key]

# Field actions
userset {user_id} tog {field} t|f
userset {user_id} set {field}
userset {user_id} file {field}
userset {user_id} remove {field}
userset {user_id} reset {field}
userset {user_id} view {field}

# Bulk actions
userset {user_id} reset           # reset all (no d3)
userset {user_id} backup
userset {user_id} restore
```

---

## State Management

```python
state = client.state.get_user_state(user_id)  # shared mutable dict — no explicit save needed
```

| Key | Values |
|-----|--------|
| `UserStateKeys.STATE` | `MenuStates.VIEW` or `MenuStates.EDIT` |
| `UserStateKeys.START` | 0-based page offset for paginated list |
| `UserStateKeys.CURRENT_KEY` | Active action/section; reset to 0 when action changes |
<<<<<<< HEAD
=======
| `UserStateKeys.STATUS_FILTER` | `"all"` (default) / `"connected"` / `"disconnected"` — allbots connection filter; persists across visits |
>>>>>>> 2ecb89d (update)

---

## User Settings Storage

| Storage | Contents |
|---------|----------|
| `UserConfig` (DB model) | Scalar settings — strings, booleans, lists, dicts |
| `BinCollection` (binary store) | File-based: `thumbnail`, `saccounts`, `netrc`, `cookies` |
| File system only | `rclone_config`, `token_pickle` (restored from bin on startup) |

**Reset All** clears both UserConfig fields and all binary/file entries. Each file-clear step is wrapped in `contextlib.suppress(Exception)` so a missing file never aborts the reset.

---

## Key Constants (Bot Settings)

| Constant | Purpose |
|----------|---------|
<<<<<<< HEAD
| `BOT_CONFIG_KEYS_ALIAS` | Ordered list of config key aliases for pagination |
| `BOT_CONFIG_EXCLUDE_KEYS` | Identity fields never reset: `{id, owner_id, bot_token, session_string, node_id}` |
| `BOT_BUNDLE_KEYS` | Keys locked to view-only when a bot bundle is active |
| `CallbackPrefix.BOT_SET` | `"botset"` — used for back-navigation to parent settings |
=======
| `BOT_CONFIG_KEYS` | Ordered list of BotConfig field names used for pagination and index-based callbacks |
| `BOT_CONFIG_EXCLUDE_KEYS` | Identity fields never reset: `{id, owner_id, bot_token, session_string, node_id}` |
| `BOT_CONFIG_EXCLUDE_KEYS_EXTENDED` | Superset of exclude keys used when building the crud button list |
| `BOT_BUNDLE_KEYS` | Keys locked to view-only when a bot bundle is active |
| `CallbackPrefix.BOT_SET` | `"botset"` — used for back-navigation to parent settings |

## Managed Bot Token Retrieval

When a user completes the `KeyboardButtonRequestManagedBot` (Bot Token Manager) flow, Telegram fires a `managed_bot` update — but **never includes the token** in the payload (true for both webhook and MTProto mode).

The handler (`handle_managed_bot` in `_bot_manage.py`) recovers the token by calling the **Bot API `getManagedBotToken` method** using the main bot's own token:

```
POST https://api.telegram.org/bot{MAIN_BOT_TOKEN}/getManagedBotToken
{ "bot_id": <managed_bot_id> }
```

This works because the main bot is the **parent** of the managed bot (it created it via `KeyboardButtonRequestManagedBot`). The managed bot's ID comes from `managed_bot.bot.id`, which IS present in the update.

The helper `_fetch_managed_bot_token(main_bot_token, managed_bot_id)` wraps this call. Only if it fails (no `bot_token` on the main client, or API error) does the handler fall back to asking the user to paste the token manually.

**Reference**: https://core.telegram.org/bots/api#getmanagedbottoken

---

## Service Action Guards in `_bot_settings.py`

Some service actions have environment-specific guards that fire **before** the actual operation and `return` early.  Always check these guards when adding new service actions.

| Condition | Guard | Behaviour |
|-----------|-------|-----------|
| `STOP` + `ConfigAlias.WEBS` + `CLOUDFARED_TUNNEL=True` | Block STOP entirely | `query.answer(…, show_alert=True)` + `return`. Stopping the Webs service terminates the Cloudflare tunnel; restart creates a **new** URL, breaking any PyroClient webhook registered against the old one. User must do a **full bot restart** instead. |
| `STOP` + `ConfigAlias.WEBS` + non-CLOUDFLARED | Immediate stop | Calls `ServiceController.service_map[ConfigAlias.WEBS].stop(force=True)` directly (skips the normal 10 s graceful-exit wait). |
| `STOP` + `ConfigAlias.WEBS` + `DYNO` env var | Heroku note | Posts a reminder message; stop still proceeds. |
| `START/STOP/RESTART` + `ConfigAlias.TELEGRAM` or `services` | Info note | Posts "main client excluded" reminder; action still proceeds. |

**Why `force=True` for WEBS STOP**: `WebServerService.stop(force=True)` cancels the in-process uvicorn task immediately; without it the call waits up to 10 s for a natural exit, making the UI feel unresponsive.

---

## Callback Field Encoding

Field identity in `bot_manage` and `bot_settings` callbacks is encoded as a **positional integer index** into `BOT_CONFIG_KEYS` (or `model.get_all_keys(exclude={"id"})`), not as the field name or a hash. This keeps data under the 64-byte Telegram callback limit.

```python
# Building buttons (sender side):
for abs_idx, key in enumerate(BOT_CONFIG_KEYS):
    cb = f"bot_manage {user_id} {bot_id} crud {abs_idx}"

# Decoding on callback (receiver side):
field_name = BOT_CONFIG_KEYS[int(d4)]              # for bot_manage (BotConfig)
field_name = model.get_field_by_index(int(d3), exclude={"id"})  # for bot_settings (service/global)
```
>>>>>>> 2ecb89d (update)
