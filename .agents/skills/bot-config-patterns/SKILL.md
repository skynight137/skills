---
name: bot-config-patterns
<<<<<<< HEAD
description: Use this skill when working with bot/config/ — reading or updating configs, understanding BaseConfig singleton pattern, ConfigManager, cache invalidation, or adding new config fields. Covers config hierarchy, get_instance(), update_fields(), and field metadata.
=======
description: >-
  Use this skill when working with bot/config/ — reading or updating configs,
  understanding BaseConfig singleton pattern, ConfigManager, cache invalidation,
  or adding new config fields. Covers config hierarchy, get_instance(),
  update_fields(), and field metadata.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot Config Patterns

All configuration in `bot/config/` uses a singleton-per-ID pattern backed by MongoDB collections. **Never instantiate config classes directly** — always use `.get_instance()`.

---

## Config Class Hierarchy

```
BaseConfig
├── CommonConfig (bundle support)
│   ├── BotConfig     — per-bot settings
│   └── UserConfig    — per-user settings
├── WalletConfig      — per-wallet balance/inventory
└── ServiceConfig
    ├── DaemonConfig  — for daemon processes
    │   ├── AriaConfig
    │   └── QbitConfig
    └── (Utility)
        ├── GlobalConfig
        ├── TelegramConfig
        ├── RcloneConfig
        ├── GDriveConfig
        ├── FFMpegConfig
        ├── YouTubeConfig
        ├── SevenZConfig
        ├── WebsConfig
        └── ChatClonerConfig
```

---

## Getting Config Instances

```python
# ✅ CORRECT — use .get_instance(id)
bot_config   = BotConfig.get_instance(bot_id)      # int
user_config  = UserConfig.get_instance(user_id)    # int
wallet       = WalletConfig.get_instance(wallet_id) # int (= user_id)

# Service configs (singleton, preloaded at startup)
from bot.config import ConfigManager
ConfigManager.GlobalConfig.max_concurrent_dl
ConfigManager.TelegramConfig.api_id
ConfigManager.AriaConfig.rpc_port

# ❌ WRONG — never instantiate directly
bot_config = BotConfig(bot_id)   # Bypasses cache!
```

---

## Alias → Collection Mapping

| Config Class | Alias | DB Collection |
|-------------|-------|--------------|
| `BotConfig` | `bots` | `db_manager.bots` |
| `UserConfig` | `users` | `db_manager.users` |
| `WalletConfig` | `wallets` | `db_manager.wallets` |
| `GlobalConfig` | `globals` | `db_manager.globals` |
| `TelegramConfig` | `telegram` | `db_manager.telegram` |
| `AriaConfig` | `aria` | `db_manager.aria` |
| `QbitConfig` | `qbit` | `db_manager.qbit` |
| `WebsConfig` | `webs` | `db_manager.webs` |

---

## Cache Layer

```
Single source of truth: collection.cache  (in-memory dict keyed by id)
Backed by: MongoDB                        (persistent storage)
```

`get_instance()` checks `collection.cache` → constructs from DB dict if missing → stores back in cache.

> There is **no** `_instances` cache on `BaseConfig`. Do not reference `_instances`.

---

## Updating Config Fields (Critical)

```python
# ✅ CORRECT — updates in-memory model + DB + collection.cache atomically
await config.update_fields({"prefix": "!", "disable_notification": True})

# ❌ WRONG — leaves stale data in collection.cache
await db_manager.bots.update_one(bot_id, {"key": "value"})
# (next get_instance() still returns old cached object with old field values)
```

### `update_fields()` Internals

1. Updates Pydantic model fields in-place on the cached object
2. Calls `save_to_database()` → persists to MongoDB
3. The object in `collection.cache` is updated in place (same reference)

### Bundle Cache Invalidation

When a bundle is purchased or removed, reset the bundle-applied flag so the next `get_instance()` re-applies the new bundle:

```python
BotConfig.invalidate(bot_id)    # Resets _bundle_applied flag on cached model
UserConfig.invalidate(user_id)  # Same for UserConfig
```

> `invalidate()` does **not** remove the object from cache — it only resets the bundle flag.
> Do **not** call any `invalidate_cache()` or `clear_all_instances()` — these methods do not exist.

---

## ConfigManager (Startup Preload)

Called once in `bot/__main__.py`:

```python
from bot.config import ConfigManager
await ConfigManager.preload_all()

# After preload, service configs are available as class attributes:
ConfigManager.GlobalConfig     # GlobalConfig instance
ConfigManager.AriaConfig       # AriaConfig instance
ConfigManager.TelegramConfig   # TelegramConfig instance
# etc.

# Multi-instance configs stay as classes (use get_instance):
ConfigManager.BotConfig        # class — use BotConfig.get_instance(bot_id)
ConfigManager.UserConfig       # class — use UserConfig.get_instance(user_id)
ConfigManager.WalletConfig     # class — use WalletConfig.get_instance(wallet_id)
```

---

## BotConfig Fields

```python
bot_config = BotConfig.get_instance(bot_id)

bot_config.owner_id                 # int
bot_config.sudos                    # list[int]
bot_config.auths                    # dict — per-command authorized users
bot_config.blacklists               # list[int]
bot_config.plugins                  # list[str] — active plugins
bot_config.bot_disable_notification # bool
bot_config.accept_all_floodwait     # bool
bot_config.multi_bot_tokens         # list[str] — for TelegramAPIBridge
```

---

## UserConfig Fields

```python
user_config = UserConfig.get_instance(user_id)

# Path utilities:
rclone_conf = await user_config.get_rclone_conf()
thumbnail   = await user_config.get_thumbnail()
token       = await user_config.get_token_pickle()

# Category-based field access:
keys = UserConfig.get_category_keys("mirror_leech")
```

---

## GlobalConfig (System-Wide)

```python
from bot.config import ConfigManager
gc = ConfigManager.GlobalConfig

gc.max_concurrent_dl      # int — default 4
gc.max_concurrent_pr      # int — default 2
gc.max_concurrent_ul      # int — default 4
gc.max_concurrent_cl      # int — default 4
gc.download_dir           # str — default "downloads"
gc.status_limit           # int — tasks shown in /status
gc.status_update_interval # int — seconds between updates
gc.input_timeout_seconds  # int — wait_for_message timeout
gc.stop_duplicate_task    # bool
gc.min_wallet_balance     # float
gc.tax_rate               # float
gc.credit_quota_size      # int — bytes (1MB default)
gc.credit_quota_price     # float
gc.disable_aria           # bool
gc.disable_qbittorrent    # bool
gc.disable_rclone         # bool
gc.disable_youtube        # bool
gc.disable_gdrive         # bool
# ... etc.
```

---

## ServiceConfig Field Metadata

Service configs use `json_schema_extra` to classify fields:

```python
<<<<<<< HEAD
class AriaConfig(DaemonConfig):
    rpc_port: int = Field(
        default=6800,
        json_schema_extra={
            "require_restart": True,  # Daemon needs restart when changed
            "is_daemon_cli": True,    # Included in daemon CLI command
            "is_path": False,
            "required": False,
=======
class AriaModel(DaemonModel):
    aria_port: int = Field(
        default=6800,
        json_schema_extra={
            "require_restart": True,  # Daemon needs restart when changed
        }
    )
    enable_rpc: bool = Field(
        default=True,
        json_schema_extra={
            "require_restart": True,  # Daemon needs restart when changed
            "is_daemon_cli": True,    # Included in daemon CLI command
            "required": True,         # Always included (not skipped when default)
>>>>>>> 2ecb89d (update)
        }
    )

# Check field metadata:
<<<<<<< HEAD
aria_config.is_restart_field("rpc_port")  # True
aria_config.is_daemon_cli_field("rpc_port")  # True
cmd = await aria_config.build_daemon_cmd()
# → ["aria2c", "--rpc-listen-port=6800", ...]
=======
aria_config.is_restart_field("aria_port")      # True
aria_config.is_daemon_cli_field("enable_rpc")  # True
cmd = await aria_config.build_daemon_cmd()
# → ["aria2c", "--enable-rpc=true", "--rpc-listen-port=6800", ...]
>>>>>>> 2ecb89d (update)
```

---

## CommonConfig & Bundle System

`BotConfig` and `UserConfig` extend `CommonConfig` which applies purchased bundles:

```python
# Applied automatically in get_instance() via _apply_active_bundle()
# Bundles override config limits:
user_config.max_task_limit    # From UserBundle or default
user_config.max_client_slots  # From UserBundle or default
bot_config.max_sudos          # From BotBundle or default
bot_config.msg_store_unlocked # From BotBundle or default
```

Do not manually override these — they're re-applied on each `get_instance()`.

---

## From PyroClient

```python
class PyroClient:
    @property  # NOT cached_property — calls get_instance() every access
    def config_bot(self) -> BotConfig:
        return ConfigManager.BotConfig.get_instance(self.bot_id)

    @property  # NOT cached_property
    def wallet(self) -> WalletConfig:
        return ConfigManager.WalletConfig.get_instance(self.bot_id)
```

Because `config_bot` and `wallet` are plain `@property` (not `@cached_property`), they always call `get_instance()` which returns the live object from `collection.cache`. No cache reset is needed when fields change — `update_fields()` updates the cached object in-place and the next property access reflects the change automatically.
