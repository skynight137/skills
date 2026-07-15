---
name: bot-chat-management-patterns
description: >-
  Use this skill when working on bot/modules/admin/chat_management/ — adding
  actions, modifying the menu, changing the callback schema, understanding the
  dialog cache, adding new bulk operations, or working on the bulk kick / create
  chats features.
enabled: true
---

# bot-chat-management-patterns

Use this skill when working on `bot/modules/admin/chat_management/` — adding actions, modifying the menu, changing the callback schema, understanding the dialog cache, or adding new bulk operations.

---

## Module Structure

```
bot/modules/admin/chat_management/
  __init__.py       — re-exports chat_management_menu, chat_management_callback
  menu.py           — entry point + _render_chat_management (main/detail/kickmenu/bulkkickmenu/adminprivmenu/adminprivmenubulk/createchatsmenu views)
  callback.py       — slim callback dispatcher (~320 lines); calls actions.py / actions_joins.py for complex handlers
  actions.py        — complex async action handlers: delhist, addmembers, addadmin, dokick, dokickbulk, bulk_add, dokickbylist, kicklistbulk, createchats
  actions_joins.py  — join request + export link handlers: approvejoins, rejectjoins, joins_bulk, exportlinks_bulk
  helpers.py        — constants, state keys, action executors, session manager, collect_kick_targets
bot/modules/docs/chat_management.md  — full reference doc
```

---

## Callback Schema

`cb_key = "chatmgmt"` (`CallbackPrefix.CHAT_MGMT`)

```
chatmgmt {user_id} {target_id} {action} [param]
```

`target_id` = `user_client.bot_id` — embedded in every button (survives restarts, no state lookup needed).

| d3 (action)        | d4 (param)         | Notes                                                             |
|--------------------|--------------------|-------------------------------------------------------------------|
| `filter`           | filter type        | Toggles dialog filter; resets START; re-renders from cache        |
| `ps`               | new_start offset   | Pagination; served from cache                                     |
| `chat`             | chat_id            | Open detail; served from cache                                    |
| `back`             | —                  | Back to main list; served from cache                              |
| `close`            | —                  | Delete message + clear full state                                 |
| `folder`           | —                  | Toggle Main/Archive; clears dialog cache                          |
| `refresh`          | —                  | Force re-fetch; clears dialog cache + resets START                |
| `selmode`          | —                  | Toggle selection mode                                             |
| `sel`              | chat_id            | Toggle one chat selected/deselected                               |
| `selall`           | —                  | Select/deselect all chats on current page (select mode only)      |
| `bulk`             | action name        | Set pending bulk action + enter select mode                       |
| `dobulk`           | —                  | Execute bulk action; kick→bulkkickmenu, addmembers→prompt, addadmins→adminprivmenubulk, exportlinks/approvejoins/rejectjoins→dedicated handlers, others→exec_bulk |
| `leave`            | chat_id            | Leave chat; removes from cache on success                         |
| `delhist`          | chat_id            | Delete history — single MTProto call; forum: prompts for topic (→`delete_forum_topic`) or all (→`delete_chat_history(revoke=True)`) |
| `del`              | chat_id            | Delete chat; removes from cache on success                        |
| `addmembers`       | chat_id            | Add members wizard (live progress + cancel)                       |
| `adminprivmenu`    | chat_id            | Open admin privilege selection menu; resets CM_ADMIN_PRIV_KEY to all-on |
| `adminprivflt`     | field_name         | Toggle one admin privilege (individual); chat_id from CM_ADMIN_PRIV_CHAT_KEY |
| `adminprivall`     | chat_id            | Toggle all privileges ON/OFF (individual)                         |
| `doadminpriv`      | —                  | Confirm privileges → calls handle_addadmin(privileges=…)          |
| `adminprivfltb`    | field_name         | Toggle one admin privilege (bulk); re-renders adminprivmenubulk   |
| `adminprivallb`    | —                  | Toggle all privileges ON/OFF (bulk)                               |
| `doadminprivbulk`  | —                  | Confirm bulk privileges → calls handle_bulk_add(privileges=…)     |
| `kickmenu`         | chat_id            | Open individual kick filter menu; sets CM_KICK_CHAT_KEY in state  |
| `kickflt`          | filter_type        | Toggle individual kick filter; chat_id read from CM_KICK_CHAT_KEY |
| `dokick`           | —                  | Execute individual kick with selected filters; live progress + cancel |
| `kickfltb`         | filter_type        | Toggle bulk kick filter (no chat_id); re-renders bulkkickmenu     |
| `dokickbulk`       | —                  | Execute bulk kick across all CM_BULK_KICK_CHATS_KEY chats         |
| `kicklist`         | chat_id            | Kick members by user list for one chat; prompt for IDs/usernames  |
| `approvejoins`     | chat_id            | Approve join requests for one chat; prompt for user IDs or `all` |
| `rejectjoins`      | chat_id            | Reject join requests for one chat; prompt for user IDs or `all`  |
| `createchats`      | —                  | Show Create Chats type-selection menu                             |
| `createchatstype`  | `channel` / `group`| Store type in state; prompt for count via wait_for_message        |

---

## State Keys (`user_state`)

| Constant               | Key string            | Type                    | Description                                                       |
|------------------------|-----------------------|-------------------------|-------------------------------------------------------------------|
| `UserStateKeys.START`  | —                     | `int`                   | Current page offset                                               |
| `CM_FILTERS_KEY`       | `cm_filters`          | `set[str]`              | Active dialog filter types (AND logic)                            |
| `CM_SELECTED_KEY`      | `cm_selected`         | `set[int]`              | Selected chat IDs (bulk mode)                                     |
| `CM_BULK_ACTION_KEY`   | `cm_bulk_action`      | `str \| None`           | Pending bulk action: `leave`, `delhist`, `del`, `addmembers`, `addadmins`, `kick`, `kicklist`, `exportlinks`, `approvejoins`, `rejectjoins` |
| `CM_SELECT_MODE_KEY`   | `cm_selmode`          | `bool`                  | Whether selection mode is active                                  |
| `CM_FOLDER_KEY`        | `cm_folder`           | `int`                   | Active folder: `0` = Main, `1` = Archive                          |
| `CM_DIALOGS_KEY`       | `cm_dialogs`          | `list[Dialog] \| None`  | Dialog cache — see below                                          |
| `CM_KICK_CHAT_KEY`     | `cm_kick_chat`        | `int \| None`           | Chat ID targeted for individual kick (set by `kickmenu`)          |
| `CM_KICK_FILTERS_KEY`   | `cm_kick_filters`      | `set[str]`              | Active kick filters (OR logic); shared by individual and bulk kick |
| `CM_BULK_KICK_CHATS_KEY`| `cm_bulk_kick_chats`  | `set[int]`              | Chat IDs stored for bulk kick (set by `dobulk` with `kick`)       |
| `CM_KICK_LIST_CHATS_KEY`| `cm_kick_list_chats`  | `set[int]`              | Chat IDs stored for bulk kick-by-list (set by `dobulk` with `kicklist`) |
| `CM_ADMIN_PRIV_KEY`     | `cm_admin_priv`        | `set[str]`              | Selected `ChatPrivileges` field names; default: all 17 fields ON  |
| `CM_ADMIN_PRIV_CHAT_KEY`| `cm_admin_priv_chat`  | `int \| None`           | Individual add-admin flow: chat_id (set by `adminprivmenu`)        |
| `CM_BULK_ADMIN_CHATS_KEY`| `cm_bulk_admin_chats`| `set[int]`              | Chat IDs stored for bulk add-admin (set by `dobulk` with `addadmins`) |
| `CM_CREATE_CHAT_TYPE_KEY`| `cm_create_chat_type`| `str`                  | Chat type for creation: `"channel"` or `"group"`                  |

All constants are defined in `helpers.py` and imported where needed.

---

## Dialog Cache (`CM_DIALOGS_KEY`)

`get_dialogs()` is called **only once per session** (or after explicit invalidation). All subsequent navigation — pagination, filter change, selection, back — reads from this cache.

**Population**: first render with `k1=None` when `cm_dialogs` is absent.  
**Stored**: full unfiltered list for the active folder.  
**Filter**: `_passes_filter()` slices the cached list at render time — no re-fetch on filter changes.  
**Chat detail**: `menu.py` searches the cache by `chat_id`; falls back to `get_chat()` only if absent.  
**`is_forum`**: read from cache; falls back to `get_chat()` only if cache absent.

**Invalidation rules**:

| Trigger | What happens |
|---------|-------------|
| `folder` toggle | `user_state.pop(CM_DIALOGS_KEY)` |
| `refresh` (🔄) | `user_state.pop(CM_DIALOGS_KEY)` + reset START |
| `dobulk` completes (destructive) | `user_state.pop(CM_DIALOGS_KEY)` |
| `leave` success | Filter out that entry: `[d for d in cached if d.chat.id != chat_id]` |
| `del` success | Filter out that entry: `[d for d in cached if d.chat.id != chat_id]` |
| `close` | Full `clear_user_state()` |

---

## Menu Layout

```
[HEADER] 🗃 Archive  🔄                  ← folder toggle + refresh (always visible)
[HEADER] 👥 🔷 📢 👤 🤖 👑 💫           ← dialog filter buttons (hidden in select mode)
[BODY]   chat buttons (paginated, max_button_menu rows)
[BODY]   Bulk action buttons + 🏗 Create Chats (normal mode only)
         ▶ Perform + ☐ All Page (select mode with action pending)
[BODY]   ✖ Cancel Select / ☑ Select Mode toggle
[FOOTER] ⛔ Close   ◀ prev  ▶ next
```

### Select/Deselect All Page (`selall`)

In select mode, a **☐ All Page / ☑ All Page** button appears alongside the Perform button.  
- If all current page chat IDs are in `CM_SELECTED_KEY` → label = "☑ All Page" → click deselects them  
- Otherwise → label = "☐ All Page" → click adds all page IDs to selected set

---

## Bulk Actions

| Key            | Label                    | `dobulk` path                                                                                          |
|----------------|--------------------------|--------------------------------------------------------------------------------------------------------|
| `leave`        | Leave                    | `_exec_bulk()` → `_exec_action("leave", ...)`                                                         |
| `delhist`      | Delete History           | `_exec_bulk()` → `_exec_action("delhist", ...)`                                                       |
| `del`          | Delete                   | `_exec_bulk()` → `_exec_action("del", ...)`                                                           |
| `addmembers`   | Add Members              | `handle_bulk_add()` — prompts for user list, adds to each chat                                         |
| `addadmins`    | Add Admins               | Stores chats in `CM_BULK_ADMIN_CHATS_KEY`, clears select state, renders `adminprivmenubulk`; after privilege selection, `handle_bulk_add(privileges=…)` |
| `kick`         | Kick Members             | Stores chats in `CM_BULK_KICK_CHATS_KEY`, clears select state, renders `bulkkickmenu`                  |
| `exportlinks`  | Export InviteLinks       | `handle_exportlinks_bulk()` — all chats processed concurrently via `gather` + `Semaphore(5)`; reads `chat.invite_link` or `export_chat_invite_link()`; per-chat errors collected individually |
| `approvejoins` | Approve Join Requests    | `handle_joins_bulk()` — iterates `get_chat_join_requests()`; calls `approve_chat_join_request()` per req |
| `rejectjoins`  | Reject Join Requests     | `handle_joins_bulk()` — iterates `get_chat_join_requests()`; calls `decline_chat_join_request()` per req |

**Bulk Add Members flow**: `handle_bulk_add()` uses `wait_for_message` to get a target list (one per line), then iterates `selected × targets` with live progress and cancel support. State is cleaned after completion.

**Bulk Add Admins flow** — two-phase:
1. `dobulk` (action=addadmins): stores selected chats in `CM_BULK_ADMIN_CHATS_KEY`, clears selection state, resets `CM_ADMIN_PRIV_KEY = set(ADMIN_PRIV_ALL)` (all 17 privileges ON), renders `adminprivmenubulk`
2. `adminprivmenubulk`: shows 17 privilege toggles (2-col) + ☑ All shortcut (callbacks use `adminprivfltb`/`adminprivallb`), shows "▶ Set Privileges (N) → M chat(s)" when ≥1 privilege selected
3. `doadminprivbulk`: reads `CM_BULK_ADMIN_CHATS_KEY` and `CM_ADMIN_PRIV_KEY`, calls `_build_privileges(priv_sel)`, then `handle_bulk_add(..., privileges=…)` → prompts for user list
4. On done: clears `CM_BULK_ADMIN_CHATS_KEY` and `CM_ADMIN_PRIV_KEY`

**Bulk Kick flow** — two-phase:
1. `dobulk` (action=kick): stores selected chats, clears selection state, resets `CM_KICK_FILTERS_KEY = set()`, renders `bulkkickmenu`
2. `bulkkickmenu`: same 8 filter toggles (callbacks use `kickfltb` not `kickflt`), shows "▶ Kick (N chats, M filter(s))" when filters selected
3. `dokickbulk`: iterates stored chats, `collect_kick_targets()` per chat, kicks with live progress + cancel
4. On done: clears `CM_BULK_KICK_CHATS_KEY` and `CM_KICK_FILTERS_KEY`

---

## Admin Privileges Menu

### Individual flow (`k1="adminprivmenu"`, `k2=chat_id`)

Rendered by `_render_chat_management()`. Opens when user clicks "👑 Add Admin" from the chat detail (Menu B).

Default state: `CM_ADMIN_PRIV_KEY = set(ADMIN_PRIV_ALL)` — all 17 privileges ON.

Layout:
```
☑ All                               ← toggle all; active if all ON, else inactive
🔧 Manage Chat    🗑 Delete Messages
🎥 Video Chats    🚫 Restrict Members
👑 Promote Members ✏️ Change Info
📨 Invite Users   📝 Post Messages
📋 Edit Messages   📌 Pin Messages
📸 Post Stories   🖊 Edit Stories
🗑 Delete Stories  💬 Manage Topics
💌 Direct Messages 🏷 Manage Tags
👤 Anonymous
▶ Set Privileges (N)                ← shown when ≥1 selected; ButtonStyle.SUCCESS
[FOOTER] 🔙 Back (→ chat detail) | ⛔ Close
```

Active privileges shown with `✅ ` prefix + `ButtonStyle.PRIMARY`. "▶ Set Privileges" then triggers `doadminpriv` → calls `handle_addadmin(..., privileges=_build_privileges(priv_sel))` → prompts for user list.

### Bulk flow (`k1="adminprivmenubulk"`)

Same layout, but reads chats from `CM_BULK_ADMIN_CHATS_KEY`. Filter callbacks use `adminprivfltb` / `adminprivallb`. Confirm button: `doadminprivbulk`. Footer: Back → main list.

### `ADMIN_PRIV_FIELDS` (in `helpers.py`)

The 17 `ChatPrivileges` boolean fields in display order:
`can_manage_chat`, `can_delete_messages`, `can_manage_video_chats`, `can_restrict_members`, `can_promote_members`, `can_change_info`, `can_invite_users`, `can_post_messages`, `can_edit_messages`, `can_pin_messages`, `can_post_stories`, `can_edit_stories`, `can_delete_stories`, `can_manage_topics`, `can_manage_direct_messages`, `can_manage_tags`, `is_anonymous`.

### `_build_privileges(selected: set[str]) → ChatPrivileges`

Converts a set of field name strings to a `ChatPrivileges` object: each field `True` if in `selected`, `False` otherwise.

---

## Kick Members (Individual)

### Menu (`k1="kickmenu"`, `k2=chat_id`)

Rendered by `_render_chat_management()`. Shows 8 filter toggle buttons (2-column layout):

```
👥 All      👑 Admin     🤖 Bot       📞 Contact
🤝 Mutual   👻 Deleted   ⭐ Premium   👤 Non-Premium
```

Active filters highlighted with `✅` prefix + `ButtonStyle.PRIMARY`.  
"▶ Kick (n filter(s))" button appears when ≥1 filter is selected.  
Footer: `🔙 Back` (→ chat detail via `chat {chat_id}`) | `⛔ Close`.

### Kick Filters (OR logic)

| Filter      | Strategy                                                                                    |
|-------------|---------------------------------------------------------------------------------------------|
| `ALL`       | `get_chat_members()` with no filter — all members (limit=0 default = unlimited)             |
| `ADMIN`     | `ChatMembersFilter.ADMINISTRATORS`                                                          |
| `BOT`       | `ChatMembersFilter.BOTS`                                                                    |
| `CONTACT`   | **Manual pass**: `getattr(user, "is_contact", False)` — NOT `ChatMembersFilter.CONTACTS` (doesn't exist in kurigram) |
| `MUTUAL`    | **Manual pass**: `getattr(user, "is_mutual_contact", False)` — NOT `ChatMembersFilter.MUTUAL_CONTACTS` |
| `DELETED`   | Manual pass: `getattr(user, "is_deleted", False)`                                           |
| `PREMIUM`   | Manual pass: `getattr(user, "is_premium", False)`                                           |
| `NONPREMIUM`| Manual pass: `not premium and not deleted`                                                  |

- `ALL` shortcircuits all others.
- `ADMIN` and `BOT` each make one API call via `ChatMembersFilter`.
- `CONTACT`, `MUTUAL`, `DELETED`, `PREMIUM`, `NONPREMIUM` all share **one** full-member iteration pass.
- `collect_kick_targets()` always excludes `user_client.me.id`.

### Kick Execution

Uses `ban_chat_member` + `unban_chat_member` pattern (kick = ban + immediately unban).  
Live progress bar every 3 seconds + cancel button (`ButtonText.CANCEL`).  
Uses `cm_manager` (session tracker) for cancellation.  
On completion: `CM_KICK_CHAT_KEY` and `CM_KICK_FILTERS_KEY` are popped from state.

### Cancel Task Cleanup Rule (critical)

Every action that creates an inner cancel `wait_for_message` task **must await it after cancelling**:

```python
finally:
    if cancel_task:
        cancel_task.cancel()
        with suppress(asyncio.CancelledError, Exception):
            await cancel_task   # ← required: ensures handler removal + handler_dict cleanup
    cm_manager.clear_session(user_id)
```

**Why**: `cancel_task.cancel()` only schedules cancellation. Without `await cancel_task`, the inner task's `finally` block (which calls `remove_handler` and `handler_dict.pop`) may not run before the outer function returns. If the user immediately starts another action, the stale inner `MessageHandler` fires first, calls `set_handler(user_id, False)`, and the new outer `wait_for_message` sees `is_active = False` → exits as cancelled → input is silently dropped. Applied in all 5 handlers: `handle_addmembers`, `handle_addadmin`, `handle_dokick`, `handle_dokickbulk`, `handle_bulk_add`.

---

## Create Chats Feature

### Flow

1. User clicks **🏗 Create Chats** (main list, not in select mode) → renders `createchatsmenu`
2. `createchatsmenu`: "📢 Channel" | "👥 Group" type selection buttons + Back + Close
3. User picks type → `createchatstype {channel|group}` callback:
   - Stores type in `CM_CREATE_CHAT_TYPE_KEY`
   - Shows count prompt via `wait_for_message`: "How many? (1–50)"
4. pfunc validates count (1–50 integer), then:
   - Channel: `user_client.create_channel(f"Channel {i+1}")` — private by default
   - Group: `user_client.create_supergroup(f"Group {i+1}")` — private supergroup
   - 0.5 s sleep between creations (rate limit)
   - Live progress every 5 chats
5. Result: lists created chat IDs; user renames/sets usernames manually
6. Clears `CM_CREATE_CHAT_TYPE_KEY` on done

### Why private chats only

Public usernames must be globally unique and may conflict. Creating private chats avoids this entirely — the user can manually set a username in Telegram settings afterwards.

---

## Adding a New Individual Action

1. Add a `_can_*()` guard in `helpers.py`.
2. Add button in `menu.py` inside `k1 == "chat"` using the guard.
3. Add a handler branch in `callback.py` (`if d3 == "myaction" and d4:`).
   - Simple inline handler: write it in `callback.py`
   - Complex handler with `wait_for_message` or long progress: write a `handle_myaction()` function in `actions.py` (or `actions_joins.py` if join/link related) and call it from `callback.py`
4. If the action modifies the chat list (chat disappears), remove from cache:
   ```python
   cached = user_state.get(CM_DIALOGS_KEY)
   if cached is not None:
       user_state[CM_DIALOGS_KEY] = [d for d in cached if d.chat.id != chat_id_int]
   ```
5. Update `chat_management.md` and this skill.

## Adding a New Bulk Action

1. Add the key + label to `BULK_ACTION_LABELS` in `helpers.py`.
2. **Simple action** (no user input): add execution branch in `_exec_action()` in `helpers.py`. `dobulk` auto-routes to `_exec_bulk()` for unknown bulk actions — no `callback.py` changes needed.
3. **Special action** (user input or multi-step): add a branch at the top of the `dobulk` handler in `callback.py` before the `_exec_bulk()` call.
   - If it needs a menu transition: store state, render a new `k1` view, add that view to `menu.py`, add its callback actions to `callback.py`.
   - If it needs a user list: use `wait_for_message` — model after `handle_bulk_add()` in `actions.py`.
4. Update docs and this skill.

---

## File Size Rule

| File              | Limit     | Approx after change |
|-------------------|-----------|---------------------|
| `callback.py`     | 300–500 L | ~410 L              |
| `actions.py`      | ≤800 L    | ~760 L              |
| `actions_joins.py`| ≤800 L    | ~230 L              |
| `menu.py`         | ≤700 L    | ~570 L              |
| `helpers.py`      | ≤700 L    | ~470 L              |

`actions.py` is dense because it contains 7 independent async handlers each with closures and progress tracking. New join/export handlers live in `actions_joins.py` to stay under the 800-line limit. Split further only if either file grows beyond 800 lines.

---

## Security

- Command gated by `filters.owner`; callback also verifies `user_id == int(d1)`.
- Non-dev without explicit `bot_id`: both `bot_id` and `owner_id` set to `user_id` — sees only own client.
- Non-dev with explicit `bot_id` (`/cm <id>`): `bot_id=target_id`, `owner_id=user_id` — ownership enforced, access only to own bots.
- Dev: `owner_id=None` (no owner restriction); `bot_id=None` (all clients) or `bot_id=target_id` (explicit).
- `target_id` embedded in callback data (d2) — no state lookup, survives restarts.

---

## Client Resolution

`_get_user_client(client, bot_id=None, owner_id=None)` in `helpers.py` wraps `bot_manager.get_clients_by(is_bot=False, ...)`. Both filters are optional — only passed when set. Returns `list[PyroClient]` (may be empty).
