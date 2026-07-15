---
name: project-global-utils
<<<<<<< HEAD
description: Use this skill when adding new cross-module utilities, deciding whether a helper belongs in utils/ vs bot/utils/, migrating code from bot/utils/ to root utils/, or understanding the shim backward-compat pattern. Covers what lives in utils/, what must stay in bot/utils/, the shim pattern, and migration rules.
=======
description: >-
  Use this skill when adding new cross-module utilities, deciding whether a
  helper belongs in utils/ vs bot/utils/, migrating code from bot/utils/ to root
  utils/, or understanding the shim backward-compat pattern. Covers what lives
  in utils/, what must stay in bot/utils/, the shim pattern, and migration
  rules.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Project Global Utils

Root-level `utils/` package for framework-agnostic utilities shared across `bot/`, `backend/`, and `database/`.

---

## 1. Package Layout

```
utils/
├── __init__.py            # package marker
├── crypto.py              # Encryption, DeepLinkData, encode/decode_deep_link, get_pincode
├── fmt.py                 # format_pydantic_error
├── lazy.py                # LazyModule
├── logger_setup.py        # setup_logging, SERVER_LOG_LEVEL, orjson_logging, structlog_to_stdlib
├── constants/
│   ├── __init__.py        # re-exports routing + display symbols
│   ├── display.py         # TextStyle, ButtonText, ProcessMessages, ProductDisplay, MenuStates, ButtonPositions, SettingsConstants
│   └── routing.py         # ConfigAlias, BroadcastTarget, CostMultiplier, GdriveAuthConstants, RcloneAuthConstants, DestinationConstants, SpecialDestinationConstants, RSSConstants
└── links/
    ├── __init__.py        # re-exports text_clean symbols
    └── text_clean.py      # clean_text, clean_spam_domains, normalize_*, DOMAIN_REGEX, LEET_MAP, COMMON_TLDS
```

---

## 2. Decision Rule — utils/ vs bot/utils/

**Put in `utils/` (global)** if the module:
- Has zero top-level imports from `bot.*`, `backend.*`, or `database.*`
- Any `bot.*` / `backend.*` imports are deferred (inside method/function bodies)
- Is needed by two or more of: `bot/`, `backend/`, `database/`

**Keep in `bot/utils/` (bot-specific)** if the module:
- Imports Pyrogram types, bot clients, bot config at module level
- Only makes sense in Telegram bot context (e.g., `file_handler.py`, `telegraph_helper.py`)
- Is not imported by `backend/` or `database/` at all

```python
# ✅ Goes to utils/ — no top-level bot imports, used by backend + database
class Encryption: ...

# ✅ Goes to utils/ — deferred bot import is safe (only called at runtime from bot)
class SettingsConstants:
    @staticmethod
    def get_timeout_seconds():
        from bot.config import ConfigManager  # deferred — safe
        return ConfigManager.GlobalConfig.input_timeout_seconds

# ❌ Stays in bot/utils/ — top-level Pyrogram import
from pyrogram import filters
```

---

## 3. Shim Pattern (Backward Compatibility)

When a file moves from `bot/utils/foo.py` → `utils/foo.py`, replace the original with a shim:

```python
# bot/utils/foo.py  ← shim
"""Backward-compat shim — foo has moved to utils.foo."""

from utils.foo import Bar, baz

__all__ = ["Bar", "baz"]
```

Rules:
- Shim must export **all** public names that existed before
- Never add new logic to a shim — it is forwarding only
- All existing `from bot.utils.foo import Bar` imports continue to work unchanged
- New code in `database/`, `backend/`, other modules should import from `utils.foo` directly

---

## 4. Import Conventions After Migration

| Consumer | Import from |
|----------|-------------|
| `database/` models/collections | `from utils.constants import ConfigAlias` |
| `database/` models | `from utils.lazy import LazyModule` |
| `database/` collections | `from utils.fmt import format_pydantic_error` |
| `backend/` constants | `from utils.constants import *  # noqa: F403` |
| `backend/` services/endpoints | `from utils.crypto import Encryption` |
| `backend/` schemas (deferred) | `from utils.links import clean_text` |
| `bot/` plugins | `from utils.lazy import LazyModule` |
| `bot/` modules using crypto | `from utils.crypto import Encryption` |
| `bot/__main__.py` | `from utils.logger_setup import setup_logging` |

> **Note:** `bot/utils/lazy.py`, `bot/utils/crypto.py`, and `bot/utils/logger_setup.py` are shims for
> any remaining indirect callers. Direct callers inside `bot/` have been updated to import from
> `utils.*` directly. New code in `bot/` must also import from `utils.*` directly.

---

## 5. Adding a New Global Utility

1. Decide: does it pass the Decision Rule above?
2. Create `utils/<name>.py` (or `utils/<pkg>/__init__.py`)
3. If migrating from `bot/utils/<name>.py`, replace the original with a shim
4. Update all direct callers across `bot/`, `database/`, and `backend/` to import from `utils.*`
5. Update this skill if the layout changes

---

## 6. What Must NOT Go in utils/

- Anything importing `pyrogram.*` at module level
- Anything importing `bot.client.*` or `bot.config.*` at module level
- Telegram-bot-specific logic (message handlers, filters, keyboards)
- `FileHandler` (bot download/upload files — stays in `bot/utils/file_handler.py`)
- `telegraph_helper.py` (Telegram Telegraph API — bot-specific)
- `button_build.py` (Pyrogram InlineKeyboardMarkup builder — bot-specific)
