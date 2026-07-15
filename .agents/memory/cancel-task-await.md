---
name: Cancel task await pattern
description: inner wait_for_message cancel tasks must be awaited after cancel() — without await, stale handlers intercept the next user input and the new wait_for_message exits silently.
---

# Cancel Task Await Pattern

## The Rule

When a `wait_for_message` task is created for a cancel button and then cancelled on completion, **always await the task** after calling `.cancel()`:

```python
finally:
    if cancel_task:
        cancel_task.cancel()
        with suppress(asyncio.CancelledError, Exception):
            await cancel_task   # ensures handler + handler_dict are cleaned up
    cm_manager.clear_session(user_id)
```

**Why:** `task.cancel()` only schedules cancellation. The inner task's `finally` block — which calls `remove_handler(handler)` and `handler_dict.pop(user_id)` — runs only when the event loop gives the task a turn. Without `await cancel_task`, that cleanup may not happen before the outer function returns. If the user immediately starts another action and sends text, the stale inner `MessageHandler` fires first, calls `set_handler(user_id, False)`, and the new outer `wait_for_message` sees `handler_dict.get(user_id) = False` → exits as `handler_cancelled = True` → user input is silently dropped. The bot appears "stuck" — it shows the prompt but never processes further input.

**Note:** `asyncio.CancelledError` is a `BaseException` in Python 3.8+, so `suppress(Exception)` alone does NOT catch it. Use `suppress(asyncio.CancelledError, Exception)`.

**How to apply:** Everywhere in `bot/modules/admin/chat_management/actions.py` that creates `cancel_task = asyncio.create_task(client.wait_for_message(...))` and cancels it in a `finally` block. Currently applied to all 5 handlers: `handle_addmembers`, `handle_addadmin`, `handle_dokick`, `handle_dokickbulk`, `handle_bulk_add`.

Also applies to any other module that uses the same inner cancel task pattern (e.g. `bot/modules/tools/tp_generator.py`).
