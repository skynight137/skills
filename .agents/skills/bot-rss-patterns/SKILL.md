---
name: bot-rss-patterns
description: Use this skill when working on the RSS module (bot/modules/rss/, bot/service/rss.py). Covers permission model, data structure, callback schema, security patterns, and supported feed types.
---

# Bot — RSS Patterns

Reference for the RSS feed system in `bot/modules/rss/`.

---

## File Structure

```
bot/modules/rss/                      # UI and user-facing logic — split by responsibility
  constants.py                        # Shared constants: _MAIN_CB, max_button_menu, field maps, RssSessionManager
  helpers.py                          # Private helpers: _validate_*, _get_target_client, _resolve_feed_by_idx, text builders, _rss_edit_menu
  menu.py                             # RSS main menu + callback dispatcher: _rss_menu (builder), rss_menu (command handler), update_rss_menu, rss_management_menu, rss_feed_detail, rss_menu_callback
  subscribe.py                        # Subscribe flow: rss_sub_flow, process_rss_sub_input, build_nekopoi_category_buttons
  crud.py                             # CRUD ops: rss_text_list, _process_fedt_field_input, rss_delete, handle_rss_backup, handle_rss_restore
  telegram_listener.py                # Telegram RSS listener: on_message_listener_rss
bot/service/rss.py                    # RssService + RssMethods (scrapers, feed parsing, monitor loop)
database/collections/rss_feeds.py    # RssCollection — feed subscriptions (db_manager.rss_feeds)
database/collections/rss.py          # RssConfigCollection — service config (db_manager.rss)
database/models/rss_feeds.py          # RssModel — feed subscription document
database/models/rss.py                # RssConfigModel — service config document
bot/config/rss.py                     # RssConfig(UtilityConfig, RssConfigModel)
bot/exceptions/rss.py                 # Custom exceptions
```

### Dependency Chain (no circular imports)

```
constants.py → helpers.py → menu.py (imports from crud.py, subscribe.py)
telegram_listener.py  (standalone — no rss/ imports)
```

---

## Permission Model (3 Levels)

| Role | Scope | Extras |
|------|-------|--------|
| **Normal user** | Own feeds only | backup/restore personal data |
| **Bot owner** | All feeds on **owned bot only** | pause/resume/unsub all users on that bot; delete user data from that bot |
| **Developer** | All feeds, all bots, system-wide | start/stop RSS service, enable/disable via ServiceController, view cache stats |

**Critical**: Owner operations affect single-bot scope only. Dev operations are system-wide.

---

## ServiceController Integration

`RssService(BaseService, RssMethods)` — inherits `BaseService` for full `ServiceController` compatibility. It is registered in `ServiceController.service_map` under alias `"rss"`. This means it participates in the standard service lifecycle and `bots.py` settings UI automatically.

```python
# Access via ServiceController
ServiceController.rss          # rss_service singleton
ServiceController.get_service("rss")

# Lifecycle (handled automatically by start_all_enabled / stop_all_enabled)
await ServiceController.start_service("rss")
await ServiceController.stop_service("rss")
await ServiceController.restart_service("rss")

# Enable/Disable (persists to RssConfig.disable_rss in DB)
await ServiceController.set_enabled_disabled("rss", disabled=True)
await ServiceController.set_enabled_disabled("rss", disabled=False)
await ServiceController.handle_service_action(ServiceAction.ENABLE, "rss")
await ServiceController.handle_service_action(ServiceAction.DISABLE, "rss")
```

### `BaseService` abstract method implementations in `RssService`

| Method | Implementation |
|--------|---------------|
| `set_version()` | No-op — version is static (`"3.0.0"`) |
| `_check_dependencies()` | No-op — no external binary |
| `package_name` | Returns `"rss-monitor"` — no external binary |

### `is_running` property + setter

`BaseService.__init__` sets `self.is_running = False`. Since `RssService` defines `is_running` as a `@property`, a matching setter is required to avoid `AttributeError`:

```python
@is_running.setter
def is_running(self, value: bool) -> None:
    self._running = value
```

The getter combines `self._running` with a live task check:
```python
@property
def is_running(self) -> bool:
    return self._running and self._monitor_task is not None and not self._monitor_task.done()
```

### `disable_rss` field (`RssConfigModel` / `RssConfig`)

```python
disable_rss: bool  # default False — toggles via RssConfig.update_fields()
```

- **Stored in `database/models/rss.py` → `RssConfigModel.disable_rss`** (NOT in `GlobalModel`)
- DB collection: `services` document with `_id = "rss"` (alias `ConfigAlias.RSS`)
- Config class: `bot/config/rss.py` → `RssConfig(UtilityConfig, RssConfigModel)`
- When `True`: `startup()` and `start()` return early — monitor loop never starts
- `start_monitor()` (raw public method) still starts unconditionally — **dev override only**
- All auto-start paths check `not rss_service.is_disabled and not rss_service.is_running`

### `on_message_listener_rss` guard

The Telegram-chat RSS listener (`bot/modules/message_listener.py`) returns immediately when the service is not running:

```python
from bot.service.rss import rss_service

if not rss_service.is_running:
    return
```

This ensures no Telegram messages are processed for RSS when the service is stopped or disabled.

---

## Database Document

```
_id format: MongoDB ObjectId (string form in cache, bson.ObjectId in DB)
```

Uniqueness enforced by compound index `(bot_id, user_id, name)` in MongoDB.
Duplicate feed URLs per user blocked by unique index `(user_id, feed_link)`.

Key fields:

| Field | Type | Notes |
|-------|------|-------|
| `bot_id` | `int` | Non-unique index |
| `user_id` | `int` | Non-unique index |
| `name` | `str` | Feed name, unique per (bot_id, user_id) pair |
| `feed_link` | `str` | RSS/YouTube URL, or **resolved numeric TG chat ref** (e.g. `"-1001234567890"` or `"-1001234567890:topic_id"`). For Telegram feeds this is always the resolved numeric ID, never a raw username. |
| `destination_chat` | `str\|int\|None` | Target chat for posts |
| `include_thumb` | `bool` | Send item as photo using feed's own thumbnail. **Not prompted or shown for Telegram feeds.** |
| `case_sensitive` | `bool` | Regex matching is case-sensitive |
| `scrape_mode` | `bool` | Extract regex matches from full page/message text |
| `command` | `str\|None` | Bot command to run on new items |
| `auto_poster` | `bool` | Post MsgStore link instead of forwarding (Telegram feeds only) |
| `auto_poster_thumb` | `str\|None` | Thumbnail URL for auto-poster (None = plain text) |

**Removed fields** (do not reference or add back):
- `source_chat` — removed; resolved numeric ID now stored directly in `feed_link`
- `source_chat_id` — merged into `source_chat` (historical)
- `source_topic_id` — merged into `source_chat` (historical)
- `auto_poster_bid` — removed; auto-poster always uses the feed's own `client`

**`source_chat_parts` property** on `RssModel`:
```python
@property
def source_chat_parts(self) -> tuple[int | None, int | None]:
    """Return (chat_id, topic_id) parsed from feed_link. topic_id is None for general topic."""
```
Parses `feed_link` directly. Returns `(None, None)` when `feed_link` is not a Telegram chat reference (non-numeric URL). Detects TG format inline (must start with `-100` + digits, optionally with `:topic_id`).

Internally delegates to `PyroClient.get_chat_id` via a **lazy import** (inside the method body) to avoid a circular `database → bot` dependency while keeping the parsing logic in one canonical place. Any future change to `PyroClient.get_chat_id` is automatically reflected here.

**Backup format** (new — list of feed dicts):
```json
[
  {"name": "my_feed", "bot_id": 123, "user_id": 456, "feed_link": "https://...", ...},
  {"name": "tg_feed", "bot_id": 123, "user_id": 456, "feed_link": "-1001234567890", ...}
]
```
Old dict format `{name: feed_data}` is still accepted on restore for backward compatibility.

**Safe iteration**: always snapshot cache before iterating async:
```python
for item in list(self.cache.values()):  # snapshot — prevents RuntimeError during async mutation
    ...
```

---

## DB Manager Attributes

| Attribute | Class | Purpose |
|-----------|-------|---------|
| `db_manager.rss_feeds` | `RssCollection` | Feed subscription documents |
| `db_manager.rss` | `RssConfigCollection` | RSS service config (`disable_rss`, `rss_delay`, etc.) |

MongoDB collection names:
- `rss_feeds` — feed subscriptions (public DB)
- `services` — service config documents incl. RSS (private DB, `_id = "rss"`)

---

## Supported Feed Types

| Type | Detection |
|------|-----------|
| Generic RSS/Atom | Any URL not matched below |
| YouTube | URL contains `"youtube"` → `yt_scraper()` |
| Nekopoi | URL starts with `https://nekopoi.care` → `nekopoi_scraper()` |
| Telegram chat | Matches Telegram chat ref patterns → `rss_service.is_telegram_chat_link()` |

**Telegram chat formats**: `-1001234567890`, `-1002928045313:1234` (chat:topic), `@channelname`

**Telegram and Nekopoi type access**: both buttons are shown **only when `is_dev` is True**. Owners and normal users cannot subscribe to either type.

---

## Security Patterns

Every callback validates embedded user ID:
```python
if not _validate_rss_callback_auth(pre_event, embedded_user_id):
    await message.reply(ProcessMessages.NOT_YOURS)
    return
```

Cross-bot access validation:
```python
async def _get_target_client(client, user_id, target_id):
    if target_id == "me":
        return current_user_feed
    if user_id == client.dev_id:
        return access_granted          # dev always allowed
    if BotConfig(target_id).owner_id == user_id:
        return access_granted          # owner of that bot
    return access_denied
```

**Duplicate feed**: same URL cannot be subscribed twice on the same bot (even with different names).

**`auto_poster` / `auto_poster_thumb` are stored for Telegram feeds only**: Only prompted in `rss_sub_flow` when the user selects the Telegram type. These fields are not collected for YouTube or RSS/Atom.

**`include_thumb` is skipped for Telegram feeds**: Step 6 of `rss_sub_flow` is bypassed when `feed_type == "tg"`. The Thumb toggle is also hidden in the edit menu for TG feeds.

**`tg_client` resolution in `rss_sub_flow`**: when subscribing a `is_telegram_chat_link` feed, `get_chat_id` and `get_chat` must be called on the **target bot's client**, not the command-accepting client. `rss_sub_flow` resolves this via `_get_target_client`:
```python
tg_client = client
if target_client_id and target_client_id != client.bot_id:
    tg_client, _ = await _get_target_client(client, user_id, target_client_id)
    if not tg_client:
        await query.answer("❌ Access denied.", show_alert=True)
        return
# then use tg_client.get_chat_id() / tg_client.get_chat()
```
This reuses the existing helper rather than duplicating `bot_manager.get_client` calls. **Never fall back to `client` when `target_client_id` is set** — a silent fallback would operate on the wrong bot without the user knowing.

**`feed_link` storage for Telegram feeds**:
```python
chat_id_raw, topic_id = tg_client.get_chat_id(feed_link)
resolved = await tg_client.get_chat(chat_id_raw)
numeric_chat_id = resolved.id
resolved_feed_link = f"{numeric_chat_id}:{topic_id}" if topic_id else str(numeric_chat_id)
# store resolved_feed_link directly into feed_link — no separate source_chat field
```
Always store the **resolved numeric ID** directly in `feed_link` (never the raw username/link). There is no separate `source_chat` field.

---

## Cross-Bot Command Format

```
/rss                    # Current bot's RSS menu
/rss <target_bot_id>    # Open another bot's RSS (owner/dev only)
/rss me                 # All personal feeds across bots
```

---

## Callback Schema

### Subscribe flow — type selection

```
rssset sub {user_id} [{target_client_id}]
```
- Shows inline buttons for feed type: YouTube / RSS/Atom always; Telegram and Nekopoi shown **only for `is_dev`**.

```
rssset sub_type {user_id} {target_client_id} {feed_type}
```
- `feed_type` ∈ `{"yt", "tg", "rss"}`
- Launches `rss_sub_flow()` — keyboard-guided step-by-step flow
- Byte budget: `rssset sub_type 1234567890 1234567890 rss` = **41 bytes** ✅

### Subscribe flow — step sequence

`rss_sub_flow()` collects these fields via `process_rss_sub_input()` + `client.wait_for_message()`:

| Step | Field | Required | Button | Notes |
|------|-------|----------|--------|-------|
| 1 | `name` | ✅ | Cancel only | |
| 2 | `feed_link` | ✅ | Cancel only | |
| 3 | `destination_chat` | optional | Skip + Cancel | |
| 4 | `regex` | optional | Skip + Cancel | |
| 5 | `hashtag` | optional | Skip + Cancel | |
| 6 | `include_thumb` | optional | Yes + No + Cancel | **Skipped entirely for `feed_type == "tg"`** |
| 7 | `command` | optional | Skip + Cancel | |
| 8 | `case_sensitive` | optional (only if regex set) | Yes + No + Cancel | |
| 9 | `scrape_mode` | optional (only if regex set) | Yes + No + Cancel | |
| 10 | `auto_poster` | optional (tg only) | Yes + No + Cancel | |
| 10b | `auto_poster_thumb` | optional (tg+ap) | Skip + Cancel | |

Session state stored in `manager` (`RssSessionManager`). Cancel sets `sub_data["_cancelled"] = True`. Skip stops session without setting the field.

### Management list (feeds as buttons)

```
rssset mgmt {user_id} {client_id} {page}
```
- Opens paginated list of user's feeds — each feed is a clickable inline button
- `FEEDS_PER_PAGE = 8` buttons per page
- Paused feeds shown with `⏸` prefix in button label

### Individual feed detail + action menu

```
rssset feed {user_id} {client_id} {page} {idx}
```
- Shows feed details (URL, status, settings) and action buttons
- `page` + `idx` together address a feed (resolved by `_resolve_feed_by_idx`)

### Per-feed actions (all use page+idx addressing)

| Action | Callback | Effect |
|--------|----------|--------|
| Delete | `rssset fdel {user_id} {client_id} {page} {idx}` | Delete feed → back to mgmt list |
| Latest | `rssset fget {user_id} {client_id} {page} {idx}` | Auto-fetch 5 latest items → back to feed detail. **Hidden for Telegram Chat feeds** (`source_chat` set) — fetching latest is unsupported for that type. |
| Edit | `rssset fedt {user_id} {client_id} {page} {idx}` | Show edit prompt → wait_for_message → `rss_edit()` |
| Pause | `rssset fpau {user_id} {client_id} {page} {idx}` | Pause feed → refresh feed detail |
| Resume | `rssset frsu {user_id} {client_id} {page} {idx}` | Resume feed → refresh feed detail |

### Byte budget (Telegram 64-byte callback limit)

Worst case `rssset fdel 1234567890 1234567890 99 9` = **38 bytes** ✅ (well under 64)

### Resolution helper

```python
async def _resolve_feed_by_idx(client_id, user_id, page, idx):
    user_feeds = await db_manager.rss_feeds.get(client_id, user_id)
    feed_names = list(user_feeds.keys())
    target_idx = page * FEEDS_PER_PAGE + idx
    name = feed_names[target_idx]
    return name, user_feeds[name]
```

---

## Edit Menu — Field Visibility by Feed Type

| Field | RSS/YouTube | Telegram |
|-------|-------------|----------|
| Source URL | ✅ | ✅ |
| Destination Chat | ✅ | ✅ |
| Regex | ✅ | ✅ |
| Hashtag | ✅ | ✅ |
| Command | ✅ | ✅ |
| Thumb (toggle) | ✅ | ❌ hidden |
| AP Thumb (text) | ❌ hidden (unless auto_poster on) | ✅ (if auto_poster on) |
| Case Sensitive | ✅ | ✅ |
| Scrape Mode | ✅ | ✅ |
| Auto Poster (toggle) | ❌ hidden | ✅ |

The `_build_edit_menu_text(name, feed, feed_type)` function accepts `feed_type` to conditionally omit the Thumb row. The `_rss_edit_menu` function skips the Thumb toggle button when `is_tg_feed`.

---

## Legacy / Text-based Callbacks (kept for backward compat)

| Action | Callback | Notes |
|--------|----------|-------|
| Text list (personal) | `rssset list {user_id} {client_id} {start}` | Redirects to `mgmt` now |
| All subscriptions | `rssset listall {user_id} {client_id} {start}` | Owner/dev text view — unchanged |
| Bulk get items | `rssset get {user_id} [{client_id}]` | Text prompt for name+count |
| Bulk pause/resume/unsub | `rssset pause/resume/unsubscribe {user_id} [{client_id}]` | Text prompt for feed names |
| Bulk edit | `rssset edit {user_id} [{client_id}]` | Text prompt for name+flags |

---

## Function Reference

| Function | Purpose |
|----------|---------|
| `rss_sub_flow()` | **Keyboard-guided subscribe** — step-by-step, one field per prompt |
| `process_rss_sub_input()` | Per-step input processor called via `wait_for_message` in `rss_sub_flow` |
| `RssSessionManager` / `manager` | Per-user session tracking (start/stop/is_stopped) for subscribe flow |
| `RSS_FEED_TYPES` | Dict `{"yt": "🎬 YouTube", "tg": "📨 Telegram", "rss": "📡 RSS/Atom"}` |
| `RSS_FEED_TYPE_LABELS` | Dict of step-2 prompt labels per feed type |
| `rss_management_menu()` | Render paginated feed list as inline buttons |
| `rss_feed_detail()` | Render individual feed info + action buttons |
| `_resolve_feed_by_idx()` | Resolve (page, idx) → (name, feed_data) |
| `_build_feed_detail_text()` | Format feed detail message string |
| `_build_edit_menu_text(name, feed, feed_type)` | Format edit menu summary string; hides Thumb row for `feed_type="tg"` |
| `rss_text_list()` | Owner/dev all-subscriptions text view |
| `rss_menu()` | Build main RSS menu |
| `rss_edit()` | Edit business logic (args-flags format, name+flags) |
| `rss_get()` | Get items by name+count (text prompt) |
| `rss_update()` | Bulk pause/resume/unsubscribe by name |
| `rss_delete()` | Delete user's feeds (owner/dev) |
| `handle_rss_backup()` | Export feeds to JSON |
| `handle_rss_restore()` | Import feeds from JSON |
| `rss_menu_callback()` | Main callback dispatcher |
