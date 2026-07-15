---
name: Webs Service CLOUDFLARED_TUNNEL stop guard
description: Why stopping the Webs Service is blocked in CLOUDFLARED_TUNNEL mode and how the force-stop path works.
---

# Webs Service Stop Guard — CLOUDFLARED_TUNNEL Mode

## The Rule

In `bot/modules/settings/bots/_bot_settings.py`, the `STOP` action for `ConfigAlias.WEBS` is **blocked** when `CLOUDFARED_TUNNEL` is `True`.

```python
if d2 == CallbackKey.Action.STOP and d3 == ConfigAlias.WEBS and CLOUDFARED_TUNNEL:
    await query.answer("⚠️ Cannot stop Webs Service ...", show_alert=True)
    return
```

**Why:** Stopping the Webs service terminates the running Cloudflare tunnel (`_stop_tunnel()`). On the next start a *brand-new* tunnel URL is allocated and persisted to `webs_url`. Any PyroClient that registered its webhook against the *old* URL will stop receiving updates — the webhook is never re-registered automatically on a plain service start. Only a **full bot restart** (which re-initialises TelegramService and re-registers the webhook) is safe.

## Force-Stop Path (non-CLOUDFLARED)

When `CLOUDFARED_TUNNEL` is `False`, clicking STOP calls `WebServerService.stop(force=True)` directly instead of `ServiceController.stop_service(alias)`. This cancels the in-process uvicorn asyncio task immediately (no 10 s graceful-exit wait), making the UI respond fast.

`WebServerService.stop(force=True)` path:
1. `_stop_tunnel()` — no-op when `CLOUDFARED_TUNNEL=False`
2. Sets `self._server.should_exit = True`
3. Cancels `self._server_task` immediately (skips `wait_for(..., timeout=10.0)`)

## How to Apply

- Whenever adding a new stop path for `ConfigAlias.WEBS`, check `CLOUDFARED_TUNNEL` first.
- Prefer `force=True` for UI-triggered WEBS stops (fast feedback).
- For programmatic/shutdown stops (not UI-triggered), keep `force=False` to allow graceful exit.
