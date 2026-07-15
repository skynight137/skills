---
name: MongoDB session storage
description: Why all persistent PyroClient instances use MongoStorage instead of SQLite, and how the wiring works.
---

All persistent Pyrogram clients use `bot/client/mongo_storage.py` (`MongoStorage`) instead of the default SQLite `.session` file. The storage is injected in `TelegramService.build_client()` by overriding `client.storage` immediately after construction.

**Why:** SQLite `.session` files are local to a single machine. Moving a VPS or running on multiple nodes means two different machines hold the same auth_key at different times → Telegram raises `AuthKeyDuplicated`. MongoDB is a shared, VPS-portable Single Source of Truth.

**How to apply:**
- `build_client()` injects MongoStorage backed by `db_manager.pyrogram` (the `pyrogram` MongoDB database).
- `PyroClient.start()` propagates `self.session_string` into `storage._session_string` before `super().start()` opens the storage.
- On first open with an empty MongoDB doc and `_session_string` set: `open()` calls `_import_from_session_string()` which decodes via Pyrogram's `SQLiteStorage` (in-memory) then writes fields to MongoDB.
- Subsequent starts: MongoDB already has auth data → no session_string import needed.
- `_temp_client_for_validation` uses raw `pyrogram.Client(in_memory=True)` → never touches MongoDB.
- Old `.session` files in `.config/sessions/` are inert (not opened by Pyrogram anymore) and can be deleted manually.
- `cleanup_session()` in `PyroClient` deletes the per-bot MongoStorage document if it exists (the old SQLite file deletion logic still runs as a no-op for non-existent files).
