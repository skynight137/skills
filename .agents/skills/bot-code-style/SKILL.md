---
name: bot-code-style
description: Use this skill when writing or reviewing Python code in this project. Covers import style, naming conventions, performance patterns, ClassVar usage, config hierarchy, and dead-code activation checklist.
---

# Bot Code Style

Python code style standards and patterns enforced across this project.

---

## 1. Python Import Style (Senior Coder Standard)

- **Top-level imports only**: All imports must be at the top of the file. Never import inside a function/method body unless it is an unavoidable circular import.
- **Circular import exception**: If a top-level import causes a circular import, keep it inside the function and add a comment:
  ```python
  # deferred import — circular: database.__init__ imports this module
  from database import SomeModel
  ```

---

## 2. Naming Conventions

### Module-level function names (`bot/modules/`)

- **Menu entry points**: `<name>_menu` — the public function that opens or renders a menu.
  ```python
  async def rss_menu(client, message): ...       # ✅ entry for /rss command
  async def stats_menu(client, message): ...     # ✅ entry for /stats command
  async def help_menu(client, message): ...      # ✅ entry for /help command
  ```
- **Callback dispatchers**: `<name>_menu_callback` or `<name>_callback` — handles inline button callbacks.
  ```python
  async def rss_menu_callback(client, query): ...    # ✅
  async def help_menu_callback(client, query): ...   # ✅
  async def stats_menu_callback(client, query): ...  # ✅
  ```
- **Private helpers** (not called from plugins): prefix with `_`.
  ```python
  async def _rss_menu(...) -> tuple[str, Markup]:  # ✅ private builder, not the entry point
  ```

### Plugin handler names (`bot/plugins/`)

- **Always prefix with `_`** to prevent name collisions with the module functions they delegate to.
- Name mirrors the module function: `_rss_menu` calls `rss_menu`, `_help_menu_callback` calls `help_menu_callback`.
- **LazyModule variable names** must not collide with handler function names in the same file.
  ```python
  _rss = LazyModule("bot.modules.rss.menu")   # ✅ no collision with _rss_menu handler
  # _rss_menu = LazyModule(...)               # ❌ would collide if handler is also _rss_menu
  ```

### Other naming rules

- **Private helpers on a class**: `_verb_noun` pattern with underscore prefix — e.g., `_get_doc_id`, `_resolve_cache_key`.
- **Never name by infrastructure**: `_get_db_id` is misleading — use `_get_doc_id` (document ID, not database name).
- **Class-level helpers**: If a helper is used in multiple methods of the same class, make it an instance method or `@staticmethod` — not a module-level function or inline lambda.
- **`ClassVar` for class-level config**: Class-level flags must use `ClassVar[bool]` annotation, not instance assignment in `__init__`:
  ```python
  from typing import ClassVar

  class MyCollection(BaseCollection):
      node_specific: ClassVar[bool] = True  # ✅
      # not: self.node_specific = True in __init__  # ❌
  ```

---

## 3. Config Hierarchy

Always use `load_config()` from `update.py` to read configuration values. It checks `config.py` first, then environment variables.

```python
# ✅ Correct
from update import load_config
val = load_config("SOME_KEY")

# ❌ Wrong — bypasses config.py precedence
import os
val = os.getenv("SOME_KEY")
```

---

## 4. Performance & Efficiency

- **O(1) lookups**: Prefer dicts and sets over lists for membership checks and keyed access.
- **No redundant operations**: Eliminate repeated lookups — cache the result in a local variable.
- **Efficient data structures**: Choose the right structure for the access pattern (set for membership, deque for queues, etc.).
- **Scalability**: Design for high-traffic, high-frequency workloads — avoid I/O in hot loops.

---

## 5. Dead-Code Activation Checklist

When activating commented-out code (`# ...`, triple-quote strings, or dead blocks), trace every symbol before committing:

1. **Fields & attributes**: If the code accesses `obj.some_field`, verify the field exists on the model. It may also be commented out.
2. **Imports**: Ensure all imports the code uses are live (not themselves commented/missing).
3. **Helper functions**: Confirm called functions exist with the expected signature.
4. **IDs and keys**: Verify which `id` is actually stored in `_id` in MongoDB — don't guess by name.
5. **Runtime check**: After activation, check logs for `AttributeError`, `TypeError`, or silent no-ops (`n: 0` in MongoDB results).

```python
# ❌ Anti-pattern: uncommenting code that references global_config.expiration_node_id
#    without verifying the field exists on GlobalModel

# ✅ Correct: grep every symbol the uncommented block uses; fix each dependency first
```
