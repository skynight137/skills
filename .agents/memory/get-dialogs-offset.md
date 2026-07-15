---
name: get_dialogs offset_date unsupported
description: kurigram get_dialogs() does not accept offset_date — it is managed internally; use limit=seen+100 to paginate deeper.
---

# kurigram `get_dialogs()` — no `offset_date` parameter

## The rule
`get_dialogs(limit, exclude_pinned, from_archive)` — these are the **only** accepted parameters.

`offset_date`, `offset_id`, and `offset_peer` are managed **internally** by the method's `while True` loop. Passing `offset_date` raises `TypeError: got an unexpected keyword argument 'offset_date'` at the first call.

**Why:** kurigram's `GetDialogs` class handles its own cursor state. The public API deliberately hides pagination internals.

**How to apply — paginating deeper into the dialog list:**
Since each call always starts from the top and walks forward internally, to surface dialogs beyond the first N:
```python
fetch_limit = len(already_buffered) + 100  # fetch total seen + one new page
async for dialog in client.get_dialogs(limit=fetch_limit, from_archive=bool(folder)):
    if dialog not in already_buffered:  # dedup by chat.id
        already_buffered.append(dialog)
```
Each successive call with a larger `limit` fetches enough dialogs to cover all previous pages plus the new one. The dedup guard skips already-seen entries so only the new batch is appended.
