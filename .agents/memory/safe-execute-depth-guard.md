---
name: _safe_execute retry depth guard
description: MediaCaptionTooLong and ReplyMarkupInvalid retries re-enter _safe_execute(depth+1) for flood protection, capped at depth>=1 to prevent unbounded recursion.
---

## Rule

`_safe_execute` in `bot/client/wrap_client.py` handles two error types that require a modified retry:

- `MediaCaptionTooLong` — truncates the caption, then retries the call
- `ReplyMarkupInvalid` / `ButtonUrlInvalid` / `ButtonTypeInvalid` / `ButtonDataInvalid` — strips markup, then retries

**Pattern:**
```python
if depth == 0:
    return await _safe_execute(client, method, *args, depth=depth + 1, **kwargs)
else:
    return await method(client, *args, **kwargs)   # bare call — prevents unbounded recursion
```

**Why:** Earlier versions used a bare `await method(client, ...)` on the retry leg, bypassing `_safe_execute`. This meant a `FloodWait` during the retry was not handled — it propagated raw to the caller. The fix re-enters `_safe_execute` on the first retry (`depth=0 → 1`) so flood protection and `_decay_flood_counter` run. At `depth >= 1`, the bare call is used as a recursion ceiling.

**How to apply:**

- Never add a bare `await method(...)` retry inside `_safe_execute` for a new error branch — use the `depth` guard pattern instead.
- The `depth` parameter is already present in the function signature; just thread it through the recursive call.
