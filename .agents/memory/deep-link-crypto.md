---
name: DEEP_LINK_SECRET env var
description: How the DEEP_LINK_SECRET hardens XOR encryption for MsgStore and market deep-link tokens, and what breaks without it.
---

## The rule

`TelegramModel.deep_link_secret` (stored in MongoDB `services` collection, `telegram` doc) is injected into `utils/crypto.py` at startup via `set_deep_link_secret()`. When set, the XOR key for all `Encryption.encrypt(bot_id, ...)` calls becomes:

```python
HMAC-SHA256(DEEP_LINK_SECRET.encode(), struct.pack("<q", bot_id))[:8]
```

Without it the key equals the raw public `bot_id`, which anyone can derive from any message the bot sends — making all MsgStore and market tokens forgeable.

## How it's wired

- `TelegramCollection.load()` → `_push_secret(model)` → `set_deep_link_secret(model.deep_link_secret)`
- `TelegramCollection._apply_remote_change()` also calls `_push_secret()` so live config changes take effect without restart.
- `utils/crypto.py` holds the module-level `_DEEP_LINK_SECRET` string. A one-time `LOGGER.warning` fires if it is absent at first use.

## Deployment requirements

All VPS nodes **must share the same value** — tokens are cross-bot in multi-VPS mode; mismatched secrets break decryption silently.

Generate:
```sh
openssl rand -hex 32
```

Set in every environment: Heroku config vars, VPS `.env`, staging, CI.

## Backward compatibility

If unset: falls back to raw `bot_id` (pre-fix behavior). Existing tokens remain valid. Setting the secret for the first time **invalidates all previously issued tokens** — plan a rollout window; tell users to re-open MsgStore links.

**Why:** `bot_id` is a publicly derivable value (extracted from any message the bot sends or via `@botfather`). Without the HMAC layer, any observer can forge a MsgStore token pointing to arbitrary private channel message ranges the bot has access to.
