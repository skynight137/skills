---
name: bot-error-handling
description: Use this skill when working with Pyrogram client code, _safe_execute wrappers, client startup/error flows, or any code that accesses client.me, bot_id, or config_bot. Covers critical re-raise rules and client.me guard patterns.
---

# Bot Error Handling — Pyrogram Client Patterns

Critical error handling rules for Pyrogram clients in this project.

---

## 1. `_safe_execute` — Re-raise Critical Errors

`_safe_execute` wraps all Telegram API calls. Exceptions that indicate a **fatal client condition** must always be re-raised so the error propagates correctly to the caller.

**Must re-raise:**

- `AuthKeyDuplicated` → re-raise after logging. Without `raise`, Pyrogram falls through to `authorize()`, which blocks stdin with `"Enter phone number or bot token"`.

```python
except AuthKeyDuplicated as e:
    LOGGER.error(f"AuthKeyDuplicated for {mention}...")
    await _notify_error(client, str(e))
    raise  # ← required, do not remove
```

**Rule**: Any exception that represents a **permanent, unrecoverable client state** must be re-raised. Swallowing it causes Pyrogram to attempt interactive recovery that will block the process.

---

## 2. Guard `client.me` Before Accessing Dependent Properties

A client that failed to start (e.g., `AuthKeyDuplicated`) has `self.me = None`. The following will all raise `AttributeError: 'NoneType' object has no attribute 'id'` if `client.me` is None:

- `self.bot_id` → `self.me.id`
- `self.config_bot` → `self.bot_id` → `self.me.id`
- `self.wallet`, `self.download_path`, `self.bot_username`, etc.

**Rule**: Before calling `send_log()` or any method that accesses `config_bot` / `bot_id`, always guard:

```python
# ✅ Correct
if getattr(client, "me", None) is not None:
    await client.send_log(...)

# ❌ Wrong — will crash if client failed to start
await client.send_log(...)
```

---

## 3. General Error Handling Principles

- **Audit all changes**: Verify every code change preserves system stability and error handling.
- **Resource leaks**: Actively check for memory leaks, unclosed file handles, unclosed connections.
- **Race conditions**: Review concurrency behaviour in async code — especially around shared state and collection writes.
- **Edge cases**: Always test boundary conditions (empty collections, None values, zero balances, expired tokens).
