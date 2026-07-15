---
name: bot-msgstore-patterns
<<<<<<< HEAD
description: Use this skill when working on the msg_store module (bot/modules/msg_store.py) or deep link handling in start.py. Covers normal vs paid access flow, security checks, and encrypted token patterns.
=======
description: >-
  Use this skill when working on the msg_store module
  (bot/modules/special/msg_store.py) or deep link handling in start.py. Covers
  normal vs paid access flow, security checks, encrypted token patterns, media
  group auto-expansion, and chain link generation.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot — MsgStore Patterns

<<<<<<< HEAD
Reference for the MsgStore system in `bot/modules/msg_store.py` and `bot/modules/start.py`.
=======
Reference for the MsgStore system in `bot/modules/special/msg_store.py` and `bot/modules/core/start.py`.
>>>>>>> 2ecb89d (update)

---

## File Structure

```
<<<<<<< HEAD
bot/modules/msg_store.py    # MsgStore class, command logic
bot/plugins/special.py      # Plugin registration (filters.command + filters.sudo)
bot/modules/start.py        # Deep link handler for encrypted tokens
bot/utils/bot_commands.py   # Command: msg_store = ["msgstore", "ms"]
=======
bot/modules/special/msg_store.py   # MsgStore class, command logic
bot/plugins/special.py             # Plugin registration (filters.command + filters.sudo)
bot/modules/core/start.py          # Deep link handler for encrypted tokens
bot/utils/bot_commands.py          # Command: msg_store = ["msgstore", "ms"]
bot/utils/constants/args.py        # ArgFlags: SOURCE_CHAT, MESSAGE_ID, CHAIN
>>>>>>> 2ecb89d (update)
```

---

## Two Access Flows

### Normal Flow (free links)
1. User clicks encrypted token (no `_paid_` prefix)
2. `start.py` → `_check_normal_msgstore_access()` — validates bot wallet has MsgStore feature
3. Calls `MsgStore.get_messages_by_start_param()`
4. **Security check**: `_is_paid_content()` — blocks if range overlaps with any Paid Message product
5. Overlap → returns empty list → user sees "Invalid or expired"

### Paid Flow (purchased content)
1. User clicks `_paid_{source_chat_id}_{start_id}_{end_id}_{user_id}` encrypted token
2. `start.py` detects `_paid_` prefix → `_check_paid_msgstore_access()`
3. Validates buyer's `wallet.has_paid_message_access(user_id, source_chat_id, msg_range)`
4. If granted → `MsgStore.retrieve_by_range()` (bypasses `_is_paid_content` — purchase already validated)

---

## Security: `_is_paid_content()`

Checks if **any part** of the requested range overlaps with a Paid Message product in the seller's wallet.

| Scenario | Result |
|----------|--------|
| Paid MsgStore with valid purchase | ✅ Allowed via `retrieve_by_range()` |
| Normal MsgStore for non-paid range | ✅ Allowed |
| Normal MsgStore for paid range | ❌ Blocked — returns empty list |
| Creating link for paid range | ❌ Blocked with error message |
<<<<<<< HEAD
=======
| Chain link for paid source | ❌ Blocked on initial source only |
>>>>>>> 2ecb89d (update)

This prevents Normal MsgStore from bypassing Paid MsgStore access control.

---

## Command Usage

```
<<<<<<< HEAD
/msgstore                              # Quick mode — creates link from replied message
/msgstore -sc @channel -mid 100-200   # Manual mode — create link for message range
/msgstore -sc -1001234567 -mid 50     # Single message by ID
=======
/ms                                         # Quick mode — creates link from replied message
/ms -sc @channel -mid 100-200              # Manual mode — create link for message range
/ms -sc -1001234567 -mid 50               # Single message by ID
/ms -chain 111 222 333                     # Chain mode — relay across 3 bots (reply required)
/ms -chain 111 222 -sc @channel -mid 50   # Chain mode with manual source
>>>>>>> 2ecb89d (update)
```

---

<<<<<<< HEAD
=======
## Mode Dispatch (`new_event`)

```
msg_content contains -chain  →  _handle_chain_mode()
-sc + -mid present           →  _handle_manual_mode()
reply_to_message present     →  _handle_reply_mode()
(none)                       →  _send_usage_response()
```

---

## Media Group Auto-Expansion

`_retrieve_messages` auto-detects media groups **only when `start_id == end_id`** (single-message
mode — quick reply or single `-mid`). If the fetched message has `media_group_id`, it calls
`client.get_media_group(chat_id, msg_id)` to retrieve the full album.

- Range mode (`start_id != end_id`) is never auto-expanded — caller explicitly asked for a range.
- If `get_media_group` raises (e.g. message no longer in a group), falls back silently to the single message.

```python
# _retrieve_messages — single-message branch
if message.media_group_id:
    try:
        group_msgs = await self.client.get_media_group(chat_id, start_id)
        messages.extend(group_msgs)
    except Exception:
        messages.append(message)   # graceful fallback
```

---

## Chain Link Generator (`-chain`)

### Overview

`_handle_chain_mode` creates a relay of MsgStore links across multiple owned bot clients.
Each bot stores the *previous bot's reply message* and generates its own encrypted link,
building a navigable thread:

```
source → Bot1Link (reply to message)
       → Bot2Link (reply to Bot1Link)
       → Bot3Link (reply to Bot2Link)
       …
```

### `ArgFlags.CHAIN = "-chain"`

`arg_parser` joins all space-separated tokens between `-chain` and the next flag into a single
string (`"111 222 333"`). Split on whitespace to recover IDs.

### Source resolution (priority order)

| Condition | Source used |
|-----------|-------------|
| `-sc` + `-mid` present | Resolved chat + parsed range (`src_start_id`, `src_end_id`) — single ID or range both supported |
| `reply_to_message` valid | `reply_msg.chat.id` + `reply_msg.id` (single message: `src_start_id == src_end_id`) |
| Neither | `MsgStoreError` |

Security check (`_is_paid_content`) runs only on the **initial source** using the full range
(`src_start_id`, `src_end_id`). Subsequent sources are bot reply messages — not user content —
so no paid check is needed there.

### Client ordering

`bot_manager.get_clients_by()` returns clients in arbitrary order.
`_handle_chain_mode` re-sorts them to match the user's specified order:

```python
clients_map = {c.bot_id: c for c in clients_list}
ordered_clients = [clients_map[bid] for bid in bot_ids if bid in clients_map]
```

### Per-iteration flow

```python
for c in ordered_clients:
    # 1. Verify access — check src_start_id (sufficient for channel auth)
    src_check = await c.get_messages(src_chat_id, src_start_id)
    if not src_check or src_check.empty:
        continue  # bot can't read the message — skip with warning

    # 2. Encrypt with this client's bot_id — encodes full range on first hop
    token = Encryption.encrypt(c.bot_id, ints=(src_chat_id, src_start_id, src_end_id))

    # 3. Reply (first: to self.message; subsequent: to previous reply)
    reply_target = msg_store_result if msg_store_result else self.message
    new_result = await reply_target.reply(f"Chain Link ({c.mention}):\n{url}", ...)

    # 4. Advance source to the sent reply — relay hops always collapse to single message
    src_chat_id  = new_result.chat.id
    src_start_id = new_result.id
    src_end_id   = new_result.id   # ← collapses range; each relay is a single message
    msg_store_result = new_result
```

**Key invariant:** the first link encodes `(src_chat_id, start_id, end_id)` — which may be a
range. Once that reply is sent, the chain pivots to using the reply message itself as the next
source, so `src_start_id == src_end_id` for all subsequent hops. This is correct: each
relay bot stores its own reply (a single Telegram message), not the original content.

### Error behaviour

- Bot can't access source → logged + skipped (partial chain still delivered).
- Token encryption fails → logged + skipped.
- **All** bots skipped → `MsgStoreError` (no partial result to reply to).
- Some bots skipped → trailing warning reply attached to last successful link.

---

>>>>>>> 2ecb89d (update)
## Key Classes

| Class/Function | Description |
|----------------|-------------|
| `MsgStore` | Main class for message store operations |
<<<<<<< HEAD
| `ChatValidator` | Validates and resolves chat identifiers |
| `MessageRangeValidator` | Validates message ID ranges with max limit |
| `MsgStoreError` | Custom exception |
| `get_messages_from_token()` | Convenience function for token retrieval |
=======
| `MessageRangeValidator` | Validates message ID ranges with max limit |
| `MsgStoreError` | Custom exception |
| `get_messages_from_token()` | Convenience function for token retrieval |
| `_handle_chain_mode()` | Multi-bot chain link generator |
| `_retrieve_messages()` | Internal retrieval — auto-expands media groups in single-msg mode |
>>>>>>> 2ecb89d (update)
