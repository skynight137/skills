---
name: database → backend circular import rule
description: database/ models must never import from backend/; constants must live in database/constants.py or utils/constants/
---

# One-way import rule: utils ← database ← backend ← bot

`database/` models and `database/expiration.py` must **never** import from `backend/`.

**Why:** `backend/constants.py` does `from database.constants import *` at the top level. Any `database/` file that imports back from `backend/` creates a circular import that crashes uvicorn on startup with `AttributeError: partially initialized module 'backend.constants' has no attribute '...'`.

**How to apply:**
- Constants used by database models belong in `database/constants.py` (e.g. `MIN_USER_ID`, `MAX_USER_ID`, `PRODUCT_ID_PATTERN`).
- `database/expiration.py` uses `bot_manager` — keep it as a lazy `@property` (deferred `from bot.client.manager import bot_manager`) so the import only runs at call time, not at module load.
- Same lazy-property pattern for any other bot-layer dependency inside `database/` (mirrors the existing `config_manager` property in `ExpirationManager`).
- **Hook-registration pattern** (canonical example: `InventoryCollection._bundle_hook`): when a `database/` collection needs to call backend logic (e.g. cache invalidation), declare a `_hook: Callable | None = None` field and a `set_hook()` method on the collection. Then in `backend/main.py` lifespan, after `db_manager.startup()`, push the backend callable in: `db_manager.inventory.set_bundle_hook(_invalidate_cache)`. The collection calls `_bundle_hook()` at runtime without ever importing from `backend/`. This is the correct pattern for any future cross-layer callback needs.
- Files fixed: `database/models/bot.py`, `inventory.py`, `mission.py`, `transaction.py`, `user.py`, `wallet.py`, `web_session.py`, `webs.py`, `database/expiration.py`, `database/collections/inventory.py`.
