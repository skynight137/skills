---
name: Plugin manifest system
description: YAML sidecar manifests alongside each bot/plugins/*.py declare update_types and lifecycle metadata; loader is lazy-cached.
---

## Rule
Each `bot/plugins/<name>.py` has an optional `bot/plugins/<name>.yaml` sidecar.
`bot/plugins/__init__.py` reads them lazily on first call and caches for the process lifetime.
`set_webhook()` in `mixin_plugin.py` calls `get_plugin_update_types(plugin)` per active plugin
to build the `allowed_updates` list dynamically — never hardcode that list.

## YAML schema
```yaml
name: basic
description: "Short human-readable description"
update_types:          # Bot API update types this plugin needs
  - message
  - callback_query
requires_main_bot: false   # true → stripped from non-main bots on startup
enabled_by_default: true   # hint for new-bot provisioning
```

All fields are optional. A missing manifest is not a fatal error — `PluginManifest` falls back
to empty defaults and logs a debug warning.

## Public API (bot/plugins/__init__.py)
- `load_all_manifests() -> dict[str, PluginManifest]` — cached; scans `*.yaml` on first call
- `get_plugin_update_types(plugin_name) -> list[str]` — safe shortcut; returns `[]` for unknown plugins

**Why:** `allowed_updates` must reflect which update types each active plugin actually needs.
Hardcoding the list caused missed updates when plugins were disabled. The YAML sidecar keeps
the declaration co-located with the code that handles it.

**How to apply:** When adding a new plugin file, create a matching `.yaml` with at minimum the
correct `update_types`. Do not import the manifest loader (`bot/plugins/__init__.py`) at module
level — import lazily inside the method that needs it (pattern already in `mixin_plugin.py`) to
avoid circular imports at startup.
