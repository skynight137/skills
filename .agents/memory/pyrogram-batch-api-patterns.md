---
name: pyrogram-batch-api-patterns
description: Pyrogram methods that accept a list instead of single ID — always use the list form to avoid N sequential MTProto round-trips.
---

# Pyrogram Batch API Patterns

Several Pyrogram methods accept either a single `int` or a `list[int]`. Always prefer the list form for multiple IDs — it issues one MTProto round-trip regardless of how many IDs are in the list.

## Methods with batch list support

| Method | Single form | Batch form |
|--------|------------|------------|
| `client.get_messages(chat_id, msg_id)` | 1 round-trip per call | `client.get_messages(chat_id, [id1, id2, ...])` — 1 round-trip total |
| `client.delete_messages(chat_id, msg_id)` | 1 round-trip per call | `client.delete_messages(chat_id, [id1, id2, ...])` — 1 round-trip total |

## Return value normalisation

`get_messages` returns a `list` when given a list, a single `Message` when given a single int. Always normalise after a batch call:

```python
messages = await client.get_messages(chat_id, id_list)
if not isinstance(messages, list):
    messages = [messages]
```

## Sites where the batch form was applied

- `backend/services/handle.py` — `verify_paid_message_deliverability` (up to 11 sequential → 1 batch)
- `bot/modules/special/msg_store.py` — `_create_link_from_args` range check (up to 10 → 1 batch)
- `bot/modules/core/start.py` — OTD cleanup `delete_messages` (N → 1 batch)

**Why:** The single-ID form was used out of habit; the list form was repeatedly overlooked in new code and audits. The underlying TL methods (`messages.GetMessages`, `messages.DeleteMessages`) natively accept lists.

**How to apply:** Any time you see a `for msg_id in range(...)` with `await client.get_messages(...)` or `await client.delete_messages(...)` inside the loop, replace with a single batch call.
