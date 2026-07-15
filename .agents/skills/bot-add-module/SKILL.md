---
name: bot-add-module
<<<<<<< HEAD
description: Use this skill when adding a new command, feature, or module to the bot. Covers the full scaffold — module file, command definition, plugin registration, filters, documentation, and skill creation checklist.
=======
description: >-
  Use this skill when adding a new command, feature, or module to the bot.
  Covers the full scaffold — module file, command definition, plugin
  registration, filters, documentation, and skill creation checklist.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot — Adding a New Module

Step-by-step process for adding new functionality to the bot system.

---

## File Checklist

- [ ] `bot/modules/<group>/<name>.py` — module logic (place in the matching feature group)
- [ ] `bot/utils/bot_commands.py` — command definition
- [ ] `bot/plugins/<plugin>.py` — handler registration (add handler to the matching plugin file)
<<<<<<< HEAD
- [ ] `bot/plugins/filters.md` — add new handler rows to the correct plugin section table
- [ ] `bot/modules/docs/<name>.md` — technical reference (internal/agent-facing)
- [ ] `bot/modules/docs/user_guide/<name>.md` — end-user guide (optional)
- [ ] `.agents/skills/bot-<name>-patterns/SKILL.md` — create skill if module has reusable patterns (see rule #11 in `rules.md`)
- [ ] Register new skill in `skills-lock.json` and add to indexes in `rules.md` + `replit.md`
=======
- [ ] `bot/plugins/<plugin>.yaml` — **only when creating a new plugin file** (not when adding to an existing one); declares metadata for the loader (see Step 3.5)
- [ ] `bot/plugins/filters.md` — add new handler rows to the correct plugin section table
- [ ] `bot/modules/docs/<name>.md` — technical reference (internal/agent-facing)
- [ ] `bot/utils/help_messages/` — add help text here (as Rich HTML strings via `InputRichMessage`) if the module has user-facing help; do NOT create `bot/modules/docs/user_guide/` files
- [ ] `.agents/skills/bot-<name>-patterns/SKILL.md` — create skill if module has reusable patterns (use `writing-skills` skill for the process)
- [ ] Register new skill in `skills-lock.json` and add to the Active Skills table in `replit.md`
>>>>>>> 2ecb89d (update)

### Module Group → Plugin Mapping

| Group (`bot/modules/<group>/`) | Plugin file (`bot/plugins/<plugin>.py`) |
|---|---|
| `core/` | `basic.py` |
| `admin/` | `admin.py` |
| `mirror_leech/` | `mirror_leech.py` |
| `market/` | `basic.py` |
| `special/` | `special.py` |
| `system/` | `system.py` |
| `tools/` | `tools.py` |
| `rss/` | `rss.py` |
<<<<<<< HEAD
| `daily_task/` | `daily_task.py` |
=======
| `xmissions/` | `xmissions.py` |
>>>>>>> 2ecb89d (update)
| `settings/` | `basic.py` |

---

## Step 1 — Module File (`bot/modules/<group>/<name>.py`)

```python
import structlog
from pyrogram.types import Message

LOGGER = structlog.get_logger(__name__)


async def my_command(client, message: Message):
    user_id = message.from_user.id
    await message.reply(f"Hello, {user_id}!")
```

- Use `structlog.get_logger(__name__)` — never `logging.getLogger`.
- Keep handlers thin; put logic in separate methods or helpers.
- File size limit: 500–700 lines. Split if bloated.

---

## Step 2 — Command Definition (`bot/utils/bot_commands.py`)

```python
class BotCommands(BaseModel, metaclass=BotCommandsMetaclass):
    my_command: CommandEntry = Field(
        default=["mycommand", "mc"],          # primary + alias
        description="(Auth) What it does",
        json_schema_extra={"plugin": "my_plugin"}
    )
```

- `default=["primary", "alias"]` — first is the canonical command, rest are aliases.
- `description` — shown to users in help text. Prefix with `(Auth)`, `(Sudo)`, `(Owner)`, or `(Dev)` to indicate permission level.
- `json_schema_extra={"plugin": "..."}` — must match the plugin filename (without `.py`).

---

## Step 3 — Plugin Registration (`bot/plugins/<plugin>.py`)

```python
"""My Plugin — one-line description."""

from pyrogram import Client
from bot.utils import filters
from bot.utils.bot import new_task
from bot.utils.bot_commands import BotCommands


@Client.on_message(filters.command(BotCommands.my_command) & filters.auth)
@new_task
async def _my_command(client, message):
    from bot.modules.my_module import my_command
    await my_command(client, message)


# Callback handler (if the module uses inline keyboards)
@Client.on_callback_query(filters.regex(r"^mymodule") & filters.auth)
@new_task
async def _my_callback(client, query):
    from bot.modules.my_module import my_callback_handler
    await my_callback_handler(client, query)
```

- Import the module handler **inside** the plugin function (deferred import — avoids circular imports at plugin load time).
- Always decorate with `@new_task` to run in the task engine.
- If adding to an existing plugin file, just append the handlers.
- **Naming rules**:
  - Name the handler after the module function it calls: `_my_command` calls `my_command`, `_rss_menu` calls `rss_menu`.
  - Always add `_callback` suffix to `CallbackQueryHandler` functions: `_my_callback`, `_status_pages_callback`.
  - If the message handler triggers a `CallbackQueryHandler`, both must share consistent base naming: `_bot_settings` + `_bot_settings_callback`.
<<<<<<< HEAD
- **`filters.bot_client` rule**: All `CallbackQueryHandler`s must have `filters.bot_client`. Any message handler that opens a callback-menu flow must also have `filters.bot_client`.
=======
- **`filters.bot_client` rule**: All `CallbackQueryHandler`s must have `filters.bot_client`. Any message handler that opens a callback-menu flow must also have `filters.bot_client`. For private-chat bot handlers, use the pre-composed `filters.private_bot` constant instead of `filters.private & filters.bot_client`.
>>>>>>> 2ecb89d (update)
- **After registering**, add the new handler rows to `bot/plugins/filters.md` in the correct plugin section table.

---

<<<<<<< HEAD
## Step 4 — Filters

Available filters in `bot/utils/filters.py`:
=======
## Step 3.5 — Plugin Manifest (`bot/plugins/<plugin>.yaml`) — new plugin files only

**Skip this step if you are adding handlers to an existing plugin file.** Only create a YAML manifest when you create a brand-new `bot/plugins/<name>.py`.

```yaml
name: my_plugin
description: "One-line summary of what this plugin does"
update_types:           # Telegram Bot API update types this plugin needs
  - message
  - callback_query
  # other types: channel_post, inline_query, chosen_inline_result,
  #              chat_join_request, managed_bot, edited_message
requires_main_bot: false   # true → stripped from managed bots on startup
enabled_by_default: false  # hint for new-bot provisioning
```

**`update_types` reference** — list only what the plugin's handlers actually consume:

| Update type | When to include |
|---|---|
| `message` | Any `@Client.on_message` handler |
| `callback_query` | Any `@Client.on_callback_query` handler |
| `channel_post` | Handlers that process channel posts |
| `inline_query` | `@Client.on_inline_query` handlers |
| `chosen_inline_result` | `@Client.on_chosen_inline_result` handlers |
| `chat_join_request` | Join-request gating handlers |
| `managed_bot` | Managed-bot lifecycle handlers |
| `edited_message` | Handlers that react to message edits |

**Why it matters:** `set_webhook` reads these manifests to build the `allowed_updates` list sent to Telegram, so only update types declared here are delivered to the bot in webhook mode. Missing an update type → silently dropped updates. The loader (`bot/plugins/__init__.py`) auto-discovers `*.yaml` files in this directory — no registration step needed.

---

## Step 4 — Filters

Available filters in `bot/utils/filters/__init__.py`:
>>>>>>> 2ecb89d (update)

| Filter | Who can use |
|--------|-------------|
| `filters.command(cmd)` | Match command — no auth restriction alone |
| `filters.auth` | Authorized users/chats |
| `filters.sudo` | Sudo users only |
| `filters.owner` | Bot owner only |
| `filters.dev` | Developer only |
| `filters.regex(pattern)` | Callback query matching |
<<<<<<< HEAD
=======
| `filters.private_bot` | Private chat + bot account (pre-composed constant) |
| `filters.private_user` | Private chat + user account (pre-composed constant) |
>>>>>>> 2ecb89d (update)

Combine with `&`:
```python
filters.command(BotCommands.my_cmd) & filters.sudo
<<<<<<< HEAD
=======

# ✅ Preferred for private-chat bot handlers (pre-composed, created once at import)
filters.command(BotCommands.my_cmd) & filters.private_bot

# ❌ Avoid — identical result but re-composes the AND on every handler check
filters.command(BotCommands.my_cmd) & filters.private & filters.bot_client
>>>>>>> 2ecb89d (update)
```

---

## Step 5 — Documentation

### `bot/modules/docs/<name>.md` — Technical reference (agent-facing)

```markdown
# My Module Documentation

## Overview
Brief description of what the module does.

## Module Structure
bot/modules/my_module.py     # Main logic
bot/plugins/my_plugin.py     # Plugin registration
bot/utils/bot_commands.py    # Command definition

## Key Functions

| Function | Description |
|----------|-------------|
| `my_command()` | Main handler |

## Callback Schema
mymodule <user_id> <action> [param]

*Last Updated: YYYY-MM-DD*
```

<<<<<<< HEAD
### `bot/modules/docs/user_guide/<name>.md` — End-user guide (optional)

```markdown
# My Module — User Guide

> **Command:** `/mycommand`

## Usage
/mycommand              # Basic usage
/mycommand -flag value  # With options

## Arguments

| Flag | Value | Description |
|------|-------|-------------|
| `-flag` | `value` | What it does |

## Examples
/mycommand -flag value
```

=======
### `bot/utils/help_messages/` — In-bot help (Rich HTML)

User-facing help is delivered directly inside Telegram as Rich HTML via `InputRichMessage`.
Add a new string (or extend an existing dict) in `bot/utils/help_messages/` following the established pattern:

```python
my_feature = f"""<b>Description</b>
<blockquote>What this feature does</blockquote>

<b>Args</b>
<blockquote>{ArgFlags.MY_FLAG}</blockquote>

<b>Usage</b>
<blockquote><code>/cmd link {ArgFlags.MY_FLAG} value</code></blockquote>

<b>Example</b>
<blockquote><code>/cmd https://t.me/telegram/388 {ArgFlags.MY_FLAG} value</code></blockquote>
"""
```

Register the string in the relevant `HELP_DICT` in `arguments.py` or `commands.py`, then wire it into `create_help_buttons()` in `bot/modules/core/help.py`.

>>>>>>> 2ecb89d (update)
---

## Step 6 — Create a Skill (if patterns are reusable)

<<<<<<< HEAD
If the module introduces a callback schema, menu flow, or API pattern that future work will reference — create a skill. See rule #11 in `rules.md` for the full process.
=======
If the module introduces a callback schema, menu flow, or API pattern that future work will reference — create a skill. Use the `writing-skills` skill for the full process.
>>>>>>> 2ecb89d (update)

**Good candidates for a skill:**
- New callback data schema (like `mrkt`, `userset`, `bot_manage`)
- Custom menu flow with multiple states
- A utility/service class used across multiple modules

**Not a skill candidate:** simple one-command modules with no callback logic or shared patterns.

---

## Complete Example: Ping Module

### `bot/modules/core/ping.py`
```python
import structlog
from time import time
from pyrogram.types import Message

LOGGER = structlog.get_logger(__name__)


async def ping(client, message: Message):
    start = time()
    msg = await message.reply("Pong!")
    elapsed = (time() - start) * 1000
    await msg.edit(f"Pong! {elapsed:.2f}ms")
```

### `bot/utils/bot_commands.py`
```python
ping: CommandEntry = Field(
    default=["ping", "p"],
    description="Check bot latency",
    json_schema_extra={"plugin": "basic"}
)
```

### `bot/plugins/basic.py`
```python
@Client.on_message(filters.command(BotCommands.ping))
@new_task
async def _ping(client, message):
    from bot.modules.core.ping import ping
    await ping(client, message)
```
