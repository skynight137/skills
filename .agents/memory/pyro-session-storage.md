---
name: Pyrogram session storage — pyrogram DB design
description: MongoStorage schema, collection layout, key format, index strategy, and DC-map import for the pyrogram MongoDB database.
---

## Database

`pyrogram` DB (Motor), four shared collections.  All per-bot isolation is via a `bot_id` field and a composite `_id`.

## Collection schema

### `sessions`
```
{ _id: <bot_id: int>, dc_id, api_id, test_mode, auth_key, date, user_id, is_bot, server_address, port }
```
One doc per bot.  `_id = bot_id`.  Queried with `{"_id": self._bot_id}`.

### `peers`
```
{ _id: "<bot_id>:<peer_id>", bot_id, peer_id, access_hash, type, phone_number, last_update_on }
```
Composite string `_id`.  `peer_id` is a separate field (needed for sort/keyset).

### `usernames`
```
{ _id: "<bot_id>:<username>", bot_id, peer_id }
```

### `update_state`
```
{ _id: "<bot_id>:<entity_id>", bot_id, entity_id, pts, qts, date, seq }
```

## Indexes

| Collection    | Index                           | Purpose                                  |
|---------------|---------------------------------|------------------------------------------|
| peers         | `{bot_id, type, peer_id}`       | iter_peers keyset + get_peer_count       |
| peers         | `{bot_id, phone_number}` partial| get_peer_by_phone_number                 |
| usernames     | `{bot_id, peer_id}`             | delete-by-peer during update_usernames   |
| update_state  | `{bot_id}`                      | fetch all MTProto states for a bot       |

Index creation is class-level-guarded (`PyrogramCollection._indexes_ensured`) — runs once per process, called from `MongoStorage.open()`.

## DC address fallback

```python
from pyrogram.storage.sqlite_storage import PROD, TEST
```
`server_address()` uses `TEST[dc_id]` or `PROD.get(dc_id, PROD[2])` based on `test_mode` when stored value is `None`.  `port()` falls back to `443`.

**Why:** kurigram's `connect()` passes `server_address` + `port` to `get_session()` before any connection exists.  Existing sessions whose MongoDB docs predate kurigram have `None` for these fields, causing a `ConnectionError`.  After first connect, `set_dc()` persists real values so the fallback only fires once per pre-existing session.

## Composite key helpers (MongoStorage)

```python
def _peer_key(self, peer_id: int) -> str:   return f"{self._bot_id}:{peer_id}"
def _username_key(self, username: str) -> str: return f"{self._bot_id}:{username}"
def _state_key(self, entity_id: int) -> str: return f"{self._bot_id}:{entity_id}"
```

## Chat Cloner / broadcast API

`db_manager.pyrogram.iter_peers(bot_id, peer_type)` and `.get_peer_count(bot_id, peer_type)` query `{"bot_id": bot_id, "type": peer_type}` with keyset pagination on the `peer_id` field (sorted ascending).  Starting sentinel: `-(2**62)`.
