---
name: Unit-testing task/command parsing without live Telegram
description: How to test MirrorLeech/TaskConfig-style command parsing with fakes instead of a real Telegram session; two gotchas hit along the way.
---

## Approach
`bot/task/config.py::TaskConfig` and task modules like `bot/modules/mirror_leech/mirror_leech.py`
can be unit-tested without a live Telegram connection by constructing fake
`Client`/`Message` objects (see `tests/fakes.py`: `FakeClient`, `FakeMessage`, `FakeUser`)
and patching out the network/DB-heavy boundary — `configure_task()` and
`client.task_manager.*_manager.submit()` — with `AsyncMock`. This validates argument
parsing / link resolution (the part that actually breaks when someone edits flag
handling) deterministically, fast, and with no FloodWait risk.

Pure logic worth testing directly with zero mocking at all: `bot/utils/fmt.py::arg_parser()`
and `bot/task/config.py::parse_destinations()`/`Destination.from_token()` — both are I/O-free.

Real MongoDB (dev cluster via `MONGODB_URI`) connects lazily on first use and is fine to touch
in tests — `UserConfig.get_instance()`/`WalletConfig.get_instance()` only read `collection.cache`
(in-memory dict) and fall back to an unpersisted default instance when nothing exists; no insert
happens, so a random/fake user_id is safe to use in tests.

## Gotcha 1: circular import
Importing `bot.task.config` directly (e.g. `from bot.task.config import Destination`) as the
*first* bot-related import in a process raises `ImportError: cannot import name 'TaskConfig'
from partially initialized module` — a real circular import (`bot.task.config` →
`bot.service.state` → triggers `bot/service/__init__.py` → `bot.service.telegram` → imports
`TaskConfig` back from `bot.task.config`).

**Why:** it only resolves if `bot.service` is fully imported *before* `bot.task.config` is
first touched — which happens naturally during normal bot startup but not in an isolated
script/test importing `bot.task.config` first.

**How to apply:** `tests/conftest.py` does `import bot.service` once, early, for the whole test
session, so any test module can `from bot.task.config import ...` directly without hitting this.
If you write a standalone script that needs `bot.task.config`, add the same `import bot.service`
before it.

## Extension: fakes for TaskPolicy / ConcurrentManager / TaskManager tests
`TaskPolicy` and `ConcurrentManager`/`TaskManager` (`bot/task/policy.py`, `bot/task/manager.py`)
only ever read attributes off `task_config` — never `isinstance()`-check it — so
`tests/fakes.py::make_fake_task_config(**overrides)` builds a plain `SimpleNamespace` tree
instead of a real `TaskConfig`. This is far cheaper than wiring live `UserConfig`/`WalletConfig`/
`ConfigManager`, and every leaf is overridable via kwargs (e.g.
`make_fake_task_config(state=FakeTaskState(status=TaskStatus.DOWNLOAD, size=1024))`).
`FakeWallet` mirrors `WalletConfig`'s real per-task `_locked_balances` dict semantics
(lock/unlock/deduct with call-log lists for assertions) closely enough to test balance-locking
bookkeeping without touching Mongo or the real `ClassVar`-shared lock table.

**Gotcha:** `TaskPolicy.check_user_wallet_balance()` calls
`client.get_topup_message_buttons(msg, ...)` *synchronously* (not awaited) and reassigns `msg` to
its return value before raising. A fake that returns a canned string here (e.g. `("msg", None)`)
silently replaces the real error text in every failure test — the fake must echo the input
message back unchanged (`side_effect=lambda msg, **_: (msg, None)`) or assertions on the raised
message will fail against a stub string instead of the real content.

## Gotcha 2: `-d` (ArgFlags.SEED) is boolean-only despite ratio:time parsing code existing
`ArgFlags.SEED` ("-d") is registered in `ArgFlags.bool_arg_set()`, so `arg_parser` never lets it
consume a following value. The `isinstance(self.seed, str)` branch in
`MirrorLeech.new_event()` that parses `"ratio:time"` into `self.seed_ratio`/`self.seed_time` is
therefore dead code today — `-d` only toggles seeding on/off. If seed ratio/time configuration
is expected to work via the command flag, this is the place to look.
