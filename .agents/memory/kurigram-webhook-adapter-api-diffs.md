---
name: kurigram webhook adapter API diffs
description: All kurigram constructor kwarg renames and incompatibilities found in bot/webhook/adapter.py — consult before adding or editing any MessageFactory method.
---

## Structure (as of P6 refactor)
All Bot API → Pyrogram conversions live in `MessageFactory` in `bot/webhook/adapter.py`.
Instantiate once per update: `factory = MessageFactory(client)`.
Add new update types as methods — no need to thread `client` through any signature.
`_fire_handlers` and `dispatch_webhook_update` remain module-level functions.

## Rename pattern
kurigram renames Pyrogram fields but keeps the Bot API payload field names the same.
Rule: `data.get("bot_api_name")` on the right stays unchanged; only the constructor kwarg on the left changes.

## Constructor kwarg fixes (Bot API field → kurigram kwarg)

### User
- `supports_inline_queries` → `supports_guest_queries`

### Message
- `is_topic_message` → `topic_message`
- `is_automatic_forward` → `automatic_forward`
- `is_from_offline` → `from_offline`
- `paid_star_count` → **removed** (not in kurigram Message.__init__)

### Photo
- kurigram Photo.__init__ has NO `sizes` or `has_spoiler` params
- Correct pattern: pass largest PhotoSize as flat fields (`file_id, file_unique_id, width, height, file_size`) + smaller sizes as `thumbs=list[Thumbnail]`

### Sticker
- kurigram Sticker.__init__ takes NO `client` kwarg (calls `super().__init__()` not `super().__init__(client)`)
- `type` is **required** — use `_STICKER_TYPE_MAP` to convert Bot API string ("regular"|"mask"|"custom_emoji") → `enums.StickerType`

### ChatJoinRequest
- `user_chat_id` is NOT in kurigram's ChatJoinRequest.__init__ — omit it

### Video
- `codec` (``str``) is a **required** kwarg in kurigram's Video.__init__ — pass `codec=data.get("codec", "")` from Bot API payload (Bot API doesn't send this field, so always falls back to `""`)

## Filter compatibility patch
kurigram's chat-type filters (`private`, `group`, `channel`, `direct`, `forum`) only access `m.chat`, crashing on `CallbackQuery` (which has `m.message.chat`).

**Location**: `bot/utils/filters/__init__.py` — applied at import time when the filters module is first loaded.

**Fix**: At import time, patch each filter's class `__call__` via `type(filters.private).__call__ = _patched_fn`. The helper `_resolve_chat(m)` returns `m.message.chat` for CallbackQuery and `m.chat` otherwise.

This must happen before any webhook request is dispatched. Patching the class `__call__` fixes all existing composed AndFilter/OrFilter trees since Python dispatches via `type(instance).__call__`.

**Why:** kurigram's `create()` builds a unique dynamic class per filter with `__call__ = func`. AndFilter stores Filter instances as `self.base`/`self.other` and calls them as callables — so patching the class `__call__` retroactively fixes all composed filters already registered.

## Safe filters for CallbackQuery (no patch needed)
- `filters.regex` — explicitly branches on `isinstance(update, CallbackQuery)` → uses `update.data`
- `filters.user(...)` — accesses `message.from_user` which CallbackQuery has
- `filters.chat(...)` — only used with on_message/on_edited_message handlers, never callbacks
