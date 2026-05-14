---
name: bot-settings-patterns
description: Use this skill when working on settings modules (bot/modules/settings/bots/ or users.py). Covers bot_manage and userset callback schemas, state management, reply contract, and handler routing.
---

# Bot — Settings Patterns

Reference for settings modules: `bot/modules/settings/bots/` (package) and `bot/modules/settings/users.py`.

### `bots/` Package Structure

| File | Responsibility |
|------|---------------|
| `__init__.py` | Re-exports public API — `bot_settings`, `bot_settings_callback`, `bot_manage_menu`, `bot_manage_callback` |
| `_constants.py` | Module-level shared constants: `SERVICE_ACTIONS`, `SERVICE_ALIASES`, `telegram_service`, `global_config`, `bot_config`, `BOT_CONFIG_KEYS*`, `BOT_BUNDLE_KEYS` |
| `_helpers.py` | Input handler functions: `validate_and_restore_bot_config`, `edit_global_config`, `edit_bot_config`, `edit_service_config`, `update_server_config_file`, `add_new_bot_input` |
| `_bot_settings.py` | `bot_settings` (renderer) + `bot_settings_callback` (callback handler for `BOT_SET` prefix) |
| `_bot_manage.py` | `bot_manage_menu` (renderer) + `bot_manage_callback` (callback handler for `BOT_MANAGE` prefix) |

Imports in `basic.py` (`from bot.modules.settings.bots import ...`) remain unchanged — Python resolves the package `__init__.py` transparently.

---

## Handler Registration (`bot/plugins/basic.py`)

```python
# Bot settings
@Client.on_message(filters.command(BotCommands.bot_settings) & filters.private)
async def _bot_settings(client, message):
    from bot.modules.settings.bots import bot_settings
    await bot_settings(client, message, reply=True)

@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.BOT_SET}") & filters.private)
@new_task
async def _bot_settings_callback(client, query):
    from bot.modules.settings.bots import bot_settings_callback
    await bot_settings_callback(client, query)

@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.BOT_MANAGE}") & filters.private)
@new_task
async def _bot_manage_callback(client, query):
    from bot.modules.settings.bots import bot_manage_callback
    await bot_manage_callback(client, query)

# User settings
@Client.on_message(filters.command(BotCommands.user_settings) & filters.private)
async def _user_settings(client, message):
    from bot.modules.settings.users import user_settings
    await user_settings(client, message, reply=True)

@Client.on_callback_query(filters.regex(f"^{CallbackPrefix.USER_SET}") & filters.private)
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
bot_manage {user_id} allbots                    # dev only
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
| `BOT_CONFIG_KEYS_ALIAS` | Ordered list of config key aliases for pagination |
| `BOT_CONFIG_EXCLUDE_KEYS` | Identity fields never reset: `{id, owner_id, bot_token, session_string, node_id}` |
| `BOT_BUNDLE_KEYS` | Keys locked to view-only when a bot bundle is active |
| `CallbackPrefix.BOT_SET` | `"botset"` — used for back-navigation to parent settings |
