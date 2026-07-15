---
name: IS_TEST_MODE replaces test_mode field
description: test_mode was removed from GlobalModel (database/models/globals.py) and WebsConfig (backend/core/config.py); all callers now import IS_TEST_MODE directly from utils.constants.
---

# IS_TEST_MODE is the only source of truth for run mode

`IS_TEST_MODE = NODE_ENV == "development"` in `utils/constants/env.py` is the single source of truth.

**Why:** The `test_mode` field on `GlobalModel` had a validator that always returned `IS_TEST_MODE` anyway (non-configurable). `WebsConfig.test_mode` was a redundant copy set in `config.py`. Both fields were stripped; every callsite imports `IS_TEST_MODE` directly.

**How to apply:**
- Never re-add a `test_mode` field to any model — it is permanently replaced.
- All backend route handlers, bot service/module code, and task policy code import `from utils.constants import IS_TEST_MODE`.
- `tests/conftest.py` sets `os.environ.setdefault("NODE_ENV", "development")` at the very top (before any backend import) so `IS_TEST_MODE` is `True` for the entire test session. No `patch.object` on `test_mode` is needed or valid.

**Files changed (2026-07-12):**
- `database/models/globals.py` — field + validator removed, `IS_TEST_MODE` import removed
- `backend/core/config.py` — `test_mode` field removed, `web_config.test_mode = IS_TEST_MODE` line removed
- `backend/common.py`, `backend/main.py`, `backend/api/dependencies.py` — direct `IS_TEST_MODE` import added
- `backend/api/public/endpoints/payment.py`, `backend/api/v1/endpoints/auth.py` — `web_config` import replaced by `IS_TEST_MODE`
- `backend/api/v2/endpoints/auth.py` — `IS_TEST_MODE` import added alongside kept `web_config`
- `bot/service/chat_cloner.py`, `bot/service/state/base.py`, `bot/task/policy.py` — IS_TEST_MODE import added, field access replaced
- `bot/modules/mirror_leech/gdrive_list.py`, `bot/modules/mirror_leech/rclone_list.py` — same
- `tests/conftest.py` — env var set at top, `patch.object(web_config, "test_mode", ...)` removed
