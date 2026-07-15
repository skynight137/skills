---
name: Webhook vs Polling Mode
description: How no_updates and telegram_secret_token control update delivery for bot/user clients, and where the webhook endpoint lives.
---

## Rule

`TelegramModel.no_updates` (DB field, `require_restart: True`) controls how a client receives updates:

| Value | Mode | Effect |
|---|---|---|
| `True` (default) | Webhook | Pyrogram starts with `no_updates=True` — MTProto connection kept for sending/API calls, update listener disabled. Telegram pushes updates to the FastAPI endpoint. |
| `False` | MTProto polling | Pyrogram's full dispatcher runs; updates arrive over the persistent MTProto connection. Required for user accounts. |

**Why:** Webhook mode scales better — no persistent per-bot update connections. Polling (`no_updates=False`) is kept for user accounts and bots that need MTProto-specific update features.

**How to apply:** `PyroClient.__init__` sets `self.no_updates = self.config_telegram.no_updates` before `super().start()`. Pyrogram reads `self.no_updates` during `start()` to decide whether to spawn the update listener.

## Webhook Endpoint

- File: `backend/api/public/endpoints/telegram.py`
- Route: `POST /telegram/webhook/{bot_token}` — registered in both `api_router_v1` and `api_router_v2`
- Bot lookup: `int(bot_token.split(":")[0])` → `bot_manager.get_client(bot_id)` (no iteration needed)
- Security: `X-Telegram-Bot-Api-Secret-Token` header validated against `WebsModel.telegram_secret_token`; always returns HTTP 200 on failure so Telegram does not retry

## Secret Token

`WebsModel.telegram_secret_token` — set the same value in `setWebhook`'s `secret_token` param. Leave empty to skip validation (development only).

## Pending

Dispatcher injection (`client.dispatcher.updates_queue`) — converting Bot API JSON to Pyrogram MTProto types — is a TODO in `bot/webhook/adapter.py`.
