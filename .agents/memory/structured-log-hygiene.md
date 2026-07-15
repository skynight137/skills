---
name: Structured log hygiene
description: Rules for LOGGER.exception, LOGGER.warning, and LOGGER.error call sites — no f-strings with {e}, aggregation-friendly static event strings.
---

# Structured log hygiene

## The rules

### `LOGGER.exception` — plain string literal, never f-string with `{e}`

```python
# BAD — duplicates exception text, breaks log aggregation:
LOGGER.exception(f"RSS update failed: {e}")

# GOOD — exc_info is captured automatically by structlog:
LOGGER.exception("RSS update failed")
# Also drop `as e` from the except clause if e was only used in the logger call.
```

`LOGGER.exception(...)` is equivalent to `LOGGER.error(..., exc_info=True)`. Structlog already captures the exception class, message, and full traceback. Putting `{e}` in the event string makes every log entry unique, defeating Datadog / Loki / CloudWatch aggregation and adding zero diagnostic value.

### `LOGGER.error` — static event string + structured `error=str(e)` kwarg

```python
# BAD:
LOGGER.error(f"JWT validation failed: {e}")

# GOOD:
LOGGER.error("JWT validation failed", error=str(e))
```

### `LOGGER.warning` — same as LOGGER.error when catching an exception

```python
# BAD:
LOGGER.warning(f"Webhook processing failed: {e}")

# GOOD:
LOGGER.warning("Webhook processing failed", error=str(e))
```

### `LOGGER.debug` — same rule applies

```python
# BAD:
LOGGER.debug(f"Cache miss for key: {e}")

# GOOD:
LOGGER.debug("Cache miss for key", error=str(e))
```

**Why:** Static event strings are the foundation of structured log aggregation. Any interpolated `{e}` makes the event field unique per occurrence, so log systems can no longer count or alert on error rates for a given event. The structured `error=str(e)` kwarg is searchable and filterable without polluting the event field.

**How to apply:**
- After any `except` clause, if `e` is only used in a logger call, drop `as e` entirely for `LOGGER.exception` sites.
- For `LOGGER.warning/error/debug` sites, keep `as e` but move `{e}` to `error=str(e)` kwarg.
- If the event string contains other dynamic values (e.g., `f"YouTube search failed: keywords: {keywords}"`), keep those — only remove `{e}`.
- **COMPLETE as of 2026-06-29 Round 7.** Zero f-string violations remain in `bot/`, `backend/`, `database/`, `utils/`. Final batch fixed ~90 remaining violations across: `bot/modules/market/seller.py`, `mirror_leech/cancel_task.py`, `mirror_leech/rclone_list.py`, `rss/crud.py`, `rss/helpers.py`, `rss/menu.py`, `settings/users.py`, `special/msg_store.py`, `system/restart.py`, `tools/sa_generator.py`, `tools/sa_stats.py`, `tools/search_gdrive.py`, `tools/search_inline.py`, `tools/search_qbit.py`, `tools/tp_generator.py`, `tools/uss_generator.py`, `xmissions/owner_manage.py`, `xmissions/referral.py`, `xmissions/reward.py`, `xmissions/rotator_blogs.py`, `xmissions/xmissions.py`, `bot/config/wallet.py`. Grep pattern for verification: `LOGGER\.(debug|info|warning|error|exception)\(f"` across `bot/` `backend/` `utils/` — must return no matches. `self._logger` pattern in `database/` also clean (checked separately).
