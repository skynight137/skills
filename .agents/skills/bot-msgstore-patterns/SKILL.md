---
name: bot-msgstore-patterns
description: Use this skill when working on the msg_store module (bot/modules/msg_store.py) or deep link handling in start.py. Covers normal vs paid access flow, security checks, and encrypted token patterns.
---

# Bot — MsgStore Patterns

Reference for the MsgStore system in `bot/modules/msg_store.py` and `bot/modules/start.py`.

---

## File Structure

```
bot/modules/msg_store.py    # MsgStore class, command logic
bot/plugins/special.py      # Plugin registration (filters.command + filters.sudo)
bot/modules/start.py        # Deep link handler for encrypted tokens
bot/utils/bot_commands.py   # Command: msg_store = ["msgstore", "ms"]
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

This prevents Normal MsgStore from bypassing Paid MsgStore access control.

---

## Command Usage

```
/msgstore                              # Quick mode — creates link from replied message
/msgstore -sc @channel -mid 100-200   # Manual mode — create link for message range
/msgstore -sc -1001234567 -mid 50     # Single message by ID
```

---

## Key Classes

| Class/Function | Description |
|----------------|-------------|
| `MsgStore` | Main class for message store operations |
| `ChatValidator` | Validates and resolves chat identifiers |
| `MessageRangeValidator` | Validates message ID ranges with max limit |
| `MsgStoreError` | Custom exception |
| `get_messages_from_token()` | Convenience function for token retrieval |
