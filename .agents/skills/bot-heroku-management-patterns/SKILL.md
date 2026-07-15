---
name: bot-heroku-management-patterns
description: >-
  Use when working on the Heroku management module
  (bot/modules/tools/heroku_management.py). Covers session cache lifecycle,
  callback schema, view/edit state, dyno control, backup/restore, add var,
  API call patterns, edit flow, eco-dyno quota display, per-app quota breakdown,
  create app wizard, and API key input flow.
enabled: true
---

# Bot — Heroku Management Patterns

Reference for the `heroku_management` module (`/hm` command).

---

## Module Location

```
bot/modules/tools/heroku_management.py   # All logic
bot/plugins/tools.py                     # Handlers: _heroku_management_menu, _heroku_management_callback
bot/utils/bot_commands.py                # heroku_management command entry
bot/utils/constants/tasks.py             # CallbackPrefix.HEROKU = "hm"
utils/constants/display.py              # ButtonText.CREATE_APP = "➕ Create App"
```

---

## Session Cache Architecture

```python
@dataclass
class _HerokuSession:
    api_key: str
    account_info: dict
    apps: list
    quota_info: dict            # {} if plan doesn't support quota API
    config_vars_cache: dict     # {app_name: {VAR_KEY: value}}
    formation_cache: dict       # {app_name: [dyno_list]}
    _timer: asyncio.Task | None
```

`_SESSIONS: dict[int, _HerokuSession]` — keyed by `user_id`.

### Lifecycle helpers

| Function | Purpose |
|----------|---------|
| `_store_session(user_id, session)` | Save session + start 5-min auto-clear |
| `_touch_session(user_id)` | Get session + reset 5-min TTL |
| `_clear_session(user_id)` | Delete session + cancel timer immediately |
| `_auto_clear(user_id)` | Coroutine — removes session after `_SESSION_TTL` (300s) |

**Rule**: Always call `_touch_session()` in the callback handler to reset the TTL on every user interaction.

---

## Entry Point — API Key Input Flow

`heroku_management_menu` no longer accepts an API key via command argument. Flow:

1. If session cached → `_render_account_menu` (reply=True) and return.
2. If no session → send reply keyboard with **Cancel** button and `wait_for_message`.
3. `_handle_api_key` pfunc: detect `ButtonText.CANCEL` → delete messages and return. Otherwise connect to Heroku, store session, render menu with `ReplyKeyboardRemove`.

```python
kb_maker = ButtonMaker()
kb_maker.add_keyboard_button(ButtonText.CANCEL)
prompt_msg = await message.reply(text, reply_markup=kb_maker.build_keyboard())

async def _handle_api_key(_, key_msg) -> None:
    api_key = key_msg.text.strip() if key_msg.text else ""
    if api_key == ButtonText.CANCEL:
        await key_msg.delete()
        with suppress(Exception):
            await prompt_msg.delete()
        return
    status_msg = await _send_status("⏳ Connecting...", key_msg, old_message=prompt_msg, reply_markup=ReplyKeyboardRemove())
    with suppress(Exception):
        await key_msg.delete()
    # ... connect, store session, render menu

await client.wait_for_message(message, _handle_api_key)
```

---

## Callback Schema

```
hm <user_id> <action> [<param1> [<param2>]]
```

| Callback data | d2 | d3 | d4 | Behaviour |
|---------------|----|----|----|-----------|
| `hm U close` | `close` | — | — | Clear session, delete message |
| `hm U back` | `back` | — | — | Render account menu |
| `hm U back <app>` | `back` | `app_name` | — | Render app menu |
| `hm U app <app>` | `app` | `app_name` | — | Open app menu (resets to view/page=0) |
| `hm U var <app> <idx>` | `var` | `app_name` | `var_idx` | View value or open edit prompt |
| `hm U edit <app>` | `"edit"` | `app_name` | — | Set STATE=edit, re-render app menu |
| `hm U view <app>` | `"view"` | `app_name` | — | Set STATE=view, re-render app menu |
| `hm U ps <start> <app>` | `ps` | `start` | `app_name` | Jump to pagination offset |
| `hm U restart <app>` | `restart` | `app_name` | — | DELETE /apps/{app}/dynos (restart all) |
| `hm U start <app>` | `start` | `app_name` | — | Scale all dynos to qty=1 |
| `hm U stop <app>` | `stop` | `app_name` | — | Scale all dynos to qty=0 |
| `hm U backup <app>` | `backup` | `app_name` | — | Send config vars as .env file |
| `hm U restore <app>` | `restore` | `app_name` | — | Wait for file/text → **full replace** (old keys set to null) |
| `hm U addvar <app>` | `addvar` | `app_name` | — | Wait for KEY=VALUE → PATCH single var |
| `hm U del_var <app> <idx>` | `del_var` | `app_name` | `var_idx` | PATCH var to null (delete) + remove from cache |
| `hm U refresh_quota` | `refresh_quota` | — | — | Re-fetch quota, re-render account menu |
| `hm U create_app` | `create_app` | — | — | 4-step keyboard wizard to create new app |
| `hm U maint <app>` | `maint` | `app_name` | — | Toggle maintenance mode on/off |
| `hm U del_confirm <app>` | `del_confirm` | `app_name` | — | Show delete confirmation inline prompt |
| `hm U del_ok <app>` | `del_ok` | `app_name` | — | Execute DELETE /apps/{app} |

> **Parsing**: `data = query.data.split()` → `_, d1, d2, d3, d4, *_ = data + [None]*5`

---

## Account Menu Button Layout

```
[ app-1 ]  [ app-2 ]  [ app-3 ]              ← body grid (2 cols)
[ ➕ Create App ]  [ 🔄 Refresh ]            ← footer row 1
[ ⛔ Close ]                                  ← footer row 2 (close only)
```

- `ButtonText.CREATE_APP` uses `style=ButtonStyle.SUCCESS`
- `ButtonText.REFRESH` uses `style=ButtonStyle.PRIMARY`
- `add_navigation_buttons(_CB, user_id, close_only=True)` for the Close button

---

## App Menu Button Layout

**VIEW state** (default):
```
[ 🚀 START ]  [ 💥 STOP ]  [ ♻️ RESTART ]    ← header row (dyno control)
[ VAR_KEY_1 ] [ VAR_KEY_2 ]                   ← body grid (config vars, 2 cols)
[ VAR_KEY_3 ] ...
[ 🔧 Maintenance ] [ 🗑️ Delete App ]         ← footer row 1 (app-level actions)
[ EDIT / VIEW ] [ ➕ Add Var ] ...            ← footer row 2 (var actions)
[ RESTORE ] [ BACKUP ]                        ← footer row 3
[ ◀ BACK ]  [ ✖ CLOSE ]                       ← footer row 4 (navigation)
[ pagination ]                                ← footer row 5 (if applicable)
```

**EDIT state** — each var is paired with a 🗑️ delete button (2-col natural pairing):
```
[ 🚀 START ]  [ 💥 STOP ]  [ ♻️ RESTART ]    ← header row (dyno control)
[ VAR_KEY_1 ] [ 🗑️ ]                          ← var + delete pair
[ VAR_KEY_2 ] [ 🗑️ ]
[ VAR_KEY_3 ] ...
[ 🔧 Maintenance ] [ 🗑️ Delete App ]         ← footer row 1
[ EDIT / VIEW ] [ ➕ Add Var ] ...            ← footer row 2
[ RESTORE ] [ BACKUP ]                        ← footer row 3
[ ◀ BACK ]  [ ✖ CLOSE ]                       ← footer row 4 (navigation)
[ pagination ]                                ← footer row 5 (if applicable)
```

**Maintenance button style**: `ButtonStyle.SUCCESS` when maintenance is ON, `ButtonStyle.DANGER` when OFF.
**Delete App button style**: always `ButtonStyle.DANGER`.

Header buttons use `position=ButtonPositions.HEADER`, footer buttons use `position=ButtonPositions.FOOTER`.
All button labels use `ButtonText` constants — never hardcode emoji+text strings directly.

---

## State Management

Uses standard `client.state.get_user_state(user_id)` with `UserStateKeys`:

| Key | Values | Meaning |
|-----|--------|---------|
| `UserStateKeys.STATE` | `"view"` / `"edit"` | Var button behaviour |
| `UserStateKeys.START` | `int` | Pagination offset |

Reset STATE and START to defaults (`view`, `0`) when navigating to a different app or going back.

---

## View vs Edit State

### VIEW (default)
```python
if state == MenuStates.VIEW:
    display_val = str(current_value) if current_value else "(empty)"
    await query.answer(f"{var_key}:\n{display_val}", show_alert=True)
```

### EDIT
1. Edit message to show current value + "Send the new value:"
2. `client.wait_for_message(query, _handle_edit, rfunc)`
3. `_handle_edit` calls `PATCH /apps/{app}/config-vars` + updates in-memory cache
4. `rfunc = partial(_render_app_menu, client, message, user_id, session, app_name, page_start, MenuStates.EDIT)`

---

## Heroku API Class (`_HerokuAPI`)

```python
api = _HerokuAPI(session.api_key)

# Read
account = await api.get_account()           # GET /account
apps    = await api.get_apps()              # GET /apps
vars    = await api.get_config_vars(app)    # GET /apps/{app}/config-vars
form    = await api.get_formation(app)      # GET /apps/{app}/formation

# Write — single var
await api.update_config_var(app, key, value)       # PATCH /apps/{app}/config-vars {key:value}

# Write — bulk vars (restore)
await api.update_config_vars(app, {"K":"V",...})   # PATCH /apps/{app}/config-vars {full dict}

# Dyno control
await api.restart_dynos(app)               # DELETE /apps/{app}/dynos
result = await api.scale_formation(app, [{"type":"web","quantity":1}])
# PATCH /apps/{app}/formation {"updates":[...]}

# Create app (personal)
result = await api.create_app(name, region, stack)   # POST /apps
# name=None → random; stack=None → Heroku default; region="us" or "eu"
# IMPORTANT: stack is passed as plain string ("container"), NOT {"name": "container"}

# Create app (team)
result = await api.create_team_app(name, region, team, stack)  # POST /teams/apps

# App-level update (maintenance toggle, etc.)
result = await api.update_app(app, {"maintenance": True})  # PATCH /apps/{app}

# Delete app
await api.delete_app(app)  # DELETE /apps/{app}
```

All HTTP is via `async_request` from `bot/utils/http.py` (httpx, `verify=False`).

**Error handling**: Catch `httpx.HTTPStatusError` for HTTP errors (attrs: `e.response.status_code`, `e.response.reason_phrase`). Catch generic `Exception` as fallback. Always `reply()` or `edit()` the error text.

---

## Create App Wizard (`create_app`)

4-step reply keyboard wizard triggered by `hm U create_app` callback:

```python
_BTN_REGION_EU = "🇪🇺 EU"
_BTN_REGION_US = "🇺🇸 US"
_BTN_STACK_CONTAINER = "📦 Container"
```

| Step | Keyboard | Stored as |
|------|----------|-----------|
| 1: Name | `[⏭️ Skip] [❌ Cancel]` | `app_data["name"]` = str or None |
| 2: Region | `[🇪🇺 EU] [🇺🇸 US] [❌ Cancel]` | `app_data["region"]` = `"eu"` / `"us"` |
| 3: Stack | `[📦 Container] [⏭️ Skip] [❌ Cancel]` | `app_data["stack"]` = `"container"` or None |
| 4: Team | `[⏭️ Skip] [❌ Cancel]` | `app_data["team"]` = str or None |

Pattern per step:
- `await _send_status(prompt, message, old_message=prev_msg, reply_markup=kb)`
- `await client.wait_for_message(query, _handle_step)`
- Check `app_data.get("_cancelled") or "key" not in app_data` → send cancel notice with `ReplyKeyboardRemove()` and return

After all steps: call `api.create_app()` or `api.create_team_app()`, refresh `session.apps = await api.get_apps()`, re-render account menu.

---

## Dyno Control (start / stop / restart)

- **restart**: calls `api.restart_dynos(app)`, clears `formation_cache[app_name]` so next open re-fetches fresh state.
- **start**: reads `formation_cache[app_name]` (must be populated by opening the app first), scales every dyno type to `quantity=1`.
- **stop**: same as start but `quantity=0`.
- If `formation_cache` is empty for the app, show `show_alert=True` and return early.

---

## Backup / Restore

### Backup
Reads from `session.config_vars_cache[app_name]` (must be populated by opening the app first).
Writes sorted `KEY=VALUE` lines to `io.BytesIO`, sets `.name` attribute, sends as document:
```python
buf = io.BytesIO("\n".join(lines).encode())
buf.name = f"{app_name}_config_backup.env"
await message.reply_document(buf, caption=...)
```

### Restore
Uses `client.wait_for_message(query, pfunc, rfunc, doc=True, text=True)` to accept either a .env file upload or raw text. Parser:
```python
for line in raw.splitlines():
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, _, v = line.partition("=")
    pairs[k.strip()] = v.strip()
```
**Full replace semantics**: keys in the current cache that are absent from `pairs` are set to `None` in the PATCH payload — Heroku deletes vars whose value is `null`. The local cache is fully replaced with `dict(pairs)` (deleted keys removed). Success message reports both restored and deleted counts.

---

## Delete Var (`del_var`)

Available only in EDIT state. Each var button is paired with a `ButtonText.DELETE_VAR` ("🗑️") button using `style=ButtonStyle.DANGER`. The 2-col `build_menu(2)` layout naturally pairs `[VAR_KEY] [🗑️]` per row.

Handler (`elif d2 == "del_var"`):
1. Resolves `var_key` from `var_idx` via sorted keys.
2. `api.update_config_vars(app, {var_key: None})` — Heroku deletes vars set to `null`.
3. `session.config_vars_cache[app_name].pop(var_key, None)` removes it from local cache.
4. Calls `_render_app_menu(..., MenuStates.EDIT)` to refresh the menu in place.

---

## Add New Var (`addvar`)

Uses `client.wait_for_message` (text only, default). Expects `KEY=VALUE` on one line.
Parses with `text.partition("=")`, calls `api.update_config_var(app, key, value)`,
updates `session.config_vars_cache[app_name][key]`.

---

## Config Var Indexing

Config vars are sorted alphabetically and addressed by position index:
```python
var_keys = sorted(config_vars.keys())
var_key = var_keys[var_idx]
```

The callback button uses the absolute index (relative to the full sorted list, not the page):
```python
for i, key in enumerate(var_keys[page_start : page_start + _MAX_PER_PAGE]):
    abs_idx = page_start + i
    buttons.callback_button(key, f"{_CB} {user_id} var {app_name} {abs_idx}")
```

---

## Access Control

- Command handler: `filters.bot_client` (no role — any user can authenticate with their own key)
- Callback handler: `filters.bot_client`
- Session is user-scoped; callback verifies `user_id == int(d1)`

---

## Adding Features

To add a new action:
1. Add the method to `_HerokuAPI` using `_get`, `_patch`, `_post`, or `_delete`
2. Add a button in `_render_account_menu` or `_render_app_menu` at the correct position
3. Add `elif d2 == "<action>":` branch in the callback dispatcher
4. Update the callback schema table above
