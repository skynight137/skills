---
name: MongoStorage performance patterns
description: Session cache, index guard, update_peers concurrency, inspect.stack removal, force_sub filter guard — durable rules not derivable from code alone.
---

# MongoStorage performance patterns

## Rules

### inspect.stack() → explicit attr parameter
`_get(attr)` and `_set(attr, value)` take an explicit `attr: str` param. Each accessor (dc_id, auth_key, …) passes its own field name directly. Never go back to `inspect.stack()`.

**Why:** `inspect.stack()` walks the full Python call stack on every call — expensive, fragile (breaks if call depth changes), and unnecessary.

### _session_cache — in-memory field cache
`_session_cache: dict[str, Any]` is primed in `open()` after the upsert with a single `find_one`. `_get` checks it first (using `_MISSING` sentinel, not `None`, so zero values aren't missed). `_set` keeps it warm. `delete()` and `delete_session()` must clear it.

**Why:** Pyrogram calls 5–7 distinct session accessors during every bot startup. Without caching each is a separate MongoDB round-trip: N bots × 7 accessors = N×7 network calls saved.

**How to apply:** Any new session field accessor must pass its field name to `_accessor` and never bypass the cache.

### _indexes_ensured — one-time index guard
`_indexes_ensured: bool = False` in `__init__`. Index creation/drop runs only inside `if not self._indexes_ensured:` then sets the flag `True`. Prevents N×4 MongoDB round-trips when `open()` is called on every bot startup.

**Why:** `create_index` is idempotent but still makes a network call. With many bots it adds up. The flag gates it to once per instance.

### update_peers — concurrent peer + username delete
```python
coros = [self._peer.bulk_write(peer_ops)]
if peer_ids_with_usernames:
    coros.append(self._usernames.delete_many({...}))
await asyncio.gather(*coros)
# then username inserts — must follow delete_many
if username_ops:
    await self._usernames.bulk_write(username_ops)
```

**Why:** peer bulk_write and username delete_many target different collections — no conflict. Sequential execution wastes one full RTT per call. Username inserts MUST be sequential after delete_many.

### Existing indexes are sufficient — don't add more
- `peers_<bot_id>`: `_id` (primary) + partial `phone_number` (string only)
- `usernames_<bot_id>`: `_id` (primary) + `peer_id`

Adding a TTL index on `last_update_on` in peers would auto-expire cached peers → `PeerIdInvalid` errors. Do NOT add it.

---

## Filter guard — force_sub

Both `check_user_access` (role.py) and `_mstore` (service.py) must guard `add_force_sub_buttons` with:
```python
default_force_sub = client.config_manager.GlobalConfig.default_force_sub_chats
if client.force_sub_chats or default_force_sub:
    buttons = ButtonMaker()
    not_subs_msg, no_subs_buttons = await buttons.add_force_sub_buttons(client, message, user_id)
```

**Why:** `add_force_sub_buttons` calls `get_chat_member` (real Telegram API call, in the semaphored path) for every required chat. This fires on every incoming message from a non-privileged user. Without the guard, even bots with no force-sub configured incur the function call + ButtonMaker allocation on every message.

**How to apply:** Check BOTH `client.force_sub_chats` (per-bot) AND `GlobalConfig.default_force_sub_chats` (global) — `add_force_sub_buttons` checks both internally.
