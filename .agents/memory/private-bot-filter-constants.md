---
name: Pre-composed private_bot / private_user filter constants
description: Use filters.private_bot and filters.private_user instead of inline AND compositions for private-chat handlers.
---

## Rule

`bot/utils/filters/__init__.py` exports two pre-composed filter constants:

```python
private_bot  = private & bot_client    # private chat, bot account only
private_user = private & user_client   # private chat, user account only
```

**Use these constants** everywhere a handler targets private chats on a bot or user client. Do NOT write `filters.private & filters.bot_client` inline — the pre-composed form is created once at import time and keeps handler registration consistent.

**Why:** Inline `filters.private & filters.bot_client` re-composes the AND predicate on every decorator evaluation. More importantly, if a new global guard needs to be added (e.g. maintenance-mode filter), only the constant definition needs updating, not every plugin file.

## How to apply

- Message handlers in private chat: `& filters.private_bot`
- Callback query handlers in private chat: `& filters.private_bot`
- User-client private handlers: `& filters.private_user`
- Handlers not restricted to private chat: continue using `& filters.bot_client` or `& filters.user_client` directly

## Sites already updated

`bot/plugins/basic.py` (BOT_SET, BOT_MANAGE, USER_SET callbacks, bot_settings/user_settings commands) and `bot/plugins/xmissions.py` all use `filters.private_bot`.
