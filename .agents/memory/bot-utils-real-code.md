---
name: bot/utils mixed real-code vs shims
description: bot/utils/fmt.py and bot/utils/links/validators.py are real bot-specific code, not shims. Do not delete during shim cleanup.
---

## Rule
`bot/utils/` contains a mix of cleaned-up shims and files with actual bot-specific logic. Never delete a file just because it appears to sit alongside former shims.

## Files with real code (keep)
- `bot/utils/fmt.py` — has `arg_parser`, `strip_html`, `get_telegraph_list`, plus one shim export (`format_pydantic_error` re-exported from `utils.fmt`). 15+ callers across bot/modules/, bot/service/, bot/task/.
- `bot/utils/links/validators.py` — has `is_gdrive_id`, `is_gdrive_link`, `is_magnet`, `is_rclone_path`, `is_share_link`, `is_telegram_link`, `is_url`. These do NOT exist in `utils/links/`. 10+ callers. Import directly: `from bot.utils.links.validators import ...`

## bot/utils/links/ is NOT a Python package
`bot/utils/links/__init__.py` was deleted (2026-06-28). The directory contains only `validators.py`. All callers must import directly from the module file, not from the package:
- ✅ `from bot.utils.links.validators import is_url`
- ❌ `from bot.utils.links import is_url`  ← no __init__.py exists

## Files that were pure shims or stubs (deleted)
- `bot/utils/crypto.py` — re-exported from `utils.crypto`
- `bot/utils/lazy.py` — re-exported from `utils.lazy`
- `bot/utils/logger_setup.py` — re-exported from `utils.logger_setup`
- `bot/utils/links/text_clean.py` — shimmed then deleted; callers use `utils.links.text_clean` directly
- `bot/utils/links/__init__.py` — removed; callers updated to import from `validators.py` directly

## format_pydantic_error migration
`format_pydantic_error` callers were migrated from `from bot.utils.fmt import` → `from utils.fmt import` (8 files in bot/modules/). The shim export line in `bot/utils/fmt.py` can be removed once all callers are confirmed migrated.

**Why:** During X6 shim cleanup, `bot/utils/fmt.py` was nearly deleted under the assumption it was a pure shim. It is not. Similarly, `bot/utils/links/__init__.py` removal broke any `from bot.utils.links import` style imports — all were updated to reference `validators.py` directly.

**How to apply:** Before removing any file in `bot/utils/`, check for non-shim function definitions inside it. If any exist, the file is real code. For `bot/utils/links/`, always import from `bot.utils.links.validators` — no package-level `__init__` exists.
