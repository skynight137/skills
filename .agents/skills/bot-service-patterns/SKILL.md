---
name: bot-service-patterns
<<<<<<< HEAD
description: Use this skill when working on bot/service/ — adding a new service, modifying ServiceController, understanding service types/lifecycle, state classes, or the bot startup sequence. Covers BaseService, ServiceController, ServiceType, config integration, and state management.
=======
description: >-
  Use this skill when working on bot/service/ — adding a new service, modifying
  ServiceController, understanding service types/lifecycle, state classes, or
  the bot startup sequence. Covers BaseService, ServiceController, ServiceType,
  config integration, and state management.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot Service Patterns

Services in `bot/service/` manage background daemons and task-level integrations. `ServiceController` is the central orchestrator.

---

## Module Structure

```
bot/service/
├── __init__.py          # ServiceController, ServiceAction
├── base.py              # BaseService — abstract base class
├── aria2.py             # AriaService (DAEMON_CLIENT)
├── qbittorrent.py       # QBitService (DAEMON_CLIENT)
├── telegram.py          # TelegramService (CLIENT_ONLY)
├── webserver.py         # WebServerService (DAEMON_ONLY)
├── ffmpeg.py            # FFMpegService (UTILITY_FACTORY)
├── gdrive.py            # GDriveService (UTILITY_FACTORY)
├── rclone.py            # RcloneService (UTILITY_FACTORY)
├── youtube.py           # YouTubeService (UTILITY_FACTORY)
├── sevenz.py            # SevenZService (UTILITY_FACTORY)
├── chat_cloner.py       # ChatClonerService (UTILITY_FACTORY)
├── rss.py               # RssService (background monitor — registered in service_map)
└── state/               # Per-task state classes
    ├── base.py          # BaseState, SubState, ReportState
    ├── aria.py          # AriaState
    ├── qbit.py          # QbittorrentState
    ├── telegram.py      # TelegramState
    ├── ffmpeg.py        # FFMpegState
    ├── gdrive.py        # GDriveState
    ├── rclone.py        # RcloneState
    ├── youtube.py       # YoutubeState
    ├── sevenz.py        # SevenZState
    ├── chat_cloner.py   # CloneChatState
    └── queue.py         # QueueState
```

> `bot/service/utils/` does NOT exist — `ServiceMetadata`, `ServiceRegistry`, and `DependencyChecker` have been removed.

---

## Service Types (`database.models.service.ServiceType`)

```python
from database.models.service import ServiceType

class ServiceType(Enum):
    DAEMON_CLIENT   = auto()  # Aria2, qBittorrent — daemon + client both needed
    CLIENT_ONLY     = auto()  # Telegram — only client connection
    DAEMON_ONLY     = auto()  # WebServer — only daemon process
    UTILITY_FACTORY = auto()  # FFmpeg, Rclone, yt-dlp, 7z, GDrive — on-demand per task
```

---

## ServiceController

Central orchestrator — used as a class (not an instance).

```python
from bot.service import ServiceController, ServiceAction

# Direct service access (auto-generated class attributes from service_map):
ServiceController.aria        # AriaService singleton
ServiceController.qbittorrent # QBitService singleton
ServiceController.telegram    # TelegramService singleton
ServiceController.ffmpeg      # FFMpegService singleton
ServiceController.gdrive      # GDriveService singleton
ServiceController.rclone      # RcloneService singleton
ServiceController.youtube     # YouTubeService singleton
ServiceController.sevenz      # SevenZService singleton
ServiceController.webserver   # WebServerService singleton
ServiceController.chat_cloner # ChatClonerService singleton

# Lifecycle:
await ServiceController.start_all_enabled()
await ServiceController.stop_all_enabled()
await ServiceController.restart_all_enabled()

# Per-service actions:
await ServiceController.handle_service_action(ServiceAction.RESTART, "aria")
await ServiceController.handle_service_action(ServiceAction.DISABLE, "qbittorrent")
await ServiceController.start_service("ffmpeg")
await ServiceController.stop_service("rclone")

# Get service object:
service = ServiceController.get_service("aria")   # BaseService | None
client  = ServiceController.get_client("aria")    # service.client | None

# Enable/disable:
await ServiceController.set_enabled_disabled("aria", disabled=True)
await ServiceController.set_enabled_disabled("all", disabled=False)

# Cleanup active tasks for running services:
await ServiceController.cleanup_tasks("all")
await ServiceController.cleanup_tasks("aria")
```

```python
class ServiceAction(StrEnum):
    ENABLE  = "enable"
    DISABLE = "disable"
    START   = "start"
    STOP    = "stop"
    RESTART = "restart"
```

---

## Startup Sequence (bot/__main__.py)

```
1. ensure_config_dirs()
2. db_manager.startup()               # MongoDB connect + load collection caches
3. ConfigManager.preload_all()        # Load all service configs from DB
4. task_manager.initialize(...)       # 4 ConcurrentManagers + watchdog
5. ServiceController.start_all_enabled()   # Start Telegram, Aria, qBit, RSS, etc.
6. bot_loop.run_forever()
```

Shutdown (SIGINT/SIGTERM):
```
1. task_manager.stop()
2. ServiceController.stop_all_enabled()   # includes RSS
3. cleanup_interval_tasks()
4. cleanup_background_tasks()
5. ExecutorManager.shutdown_executor()
6. db_manager.disconnect()
```

Note: `Telegram` service is always started regardless of disable flags — it's the core service.

---

## BaseService — Identity & Properties

Each service derives its identity from its `config` property:

```python
class BaseService(ABC):
    @property
    def alias(self) -> str:
        return self.config.id       # e.g. "aria", "ffmpeg"

    @property
    def name(self) -> str:
        return self.alias.upper()   # e.g. "ARIA", "FFMPEG"

    @property
    def service_type(self) -> ServiceType:
        return self.config.service_type

    @property
    def is_disabled(self) -> bool:
        return self.config.is_disabled

    @property
    def port(self) -> int:
        return self.config.port

    # Manager references (lazy):
    @cached_property
    def db_manager(self): ...
    @cached_property
    def config_manager(self): ...

    # State:
    is_running: bool = False
    pid: int | None = None
    client: Any = None
```

---

## Adding a New Service

### Step 1: Config class defines service identity

The config class (in `bot/config/`) must declare `service_type` and `disabled_key` as `ClassVar`:

```python
# bot/config/my_service.py
from database.models.service import ServiceType

class MyServiceConfig(ServiceConfig):
    alias = "myservice"       # maps to ConfigAlias constant
    service_type: ClassVar[ServiceType] = ServiceType.UTILITY_FACTORY
    disabled_key: ClassVar[str] = "disable_myservice"  # GlobalConfig field name
    binary_path: str = "/usr/bin/mytool"
    # ... other config fields
```

Add `MYSERVICE = "myservice"` to `ConfigAlias` in `bot/utils/constants/routing.py`.

### Step 2: Service class (`bot/service/my_service.py`)

```python
from bot.config.my_service import MyServiceConfig
from bot.service.base import BaseService
from bot.utils.constants import ConfigAlias
from bot.utils.executor import cmd_exec

class MyService(BaseService):
    @property
    def config(self) -> MyServiceConfig:
        return MyServiceConfig.get_instance(ConfigAlias.MYSERVICE)

    async def set_version(self) -> None:
        stdout, _, code = await cmd_exec([self.config.binary_path, "--version"])
        if code == 0:
            self._version = stdout.strip().splitlines()[0]

    async def _check_dependencies(self) -> None:
        _, stderr, returncode = await cmd_exec([self.config.binary_path, "--version"])
        if returncode != 0:
            raise ServiceError(self.name, f"Binary not found: {self.config.binary_path} — {stderr}")

    def build_manager(self, task: TaskConfig) -> MyManager:
        return MyManager(self, task)

my_service = MyService()  # Singleton
```

For `DAEMON_CLIENT` / `DAEMON_ONLY` types also override:
```python
async def _start_daemon(self) -> None:
    cmd = await self.config.build_daemon_cmd()
    self.process = await asyncio.create_subprocess_exec(*cmd, ...)
```

For `CLIENT_ONLY` / `DAEMON_CLIENT` also override:
```python
async def _start_client(self) -> None:
    self.client = await connect_to_service(self.config.port)
```

### Step 3: State class (`bot/service/state/my_service.py`)

```python
from bot.service.state.base import BaseState
from bot.task.status import TaskStatus

class MyServiceState(BaseState):
    async def update(self) -> None:
        await super().update()
        # Pull progress metrics from subprocess / API
```

### Step 4: Register in ServiceController (`bot/service/__init__.py`)

```python
from bot.service.my_service import my_service

class ServiceController:
    service_map: ClassVar[dict[str, BaseService]] = {
        service.alias: service
        for service in (
            aria2_service,
            # ... existing ...
            my_service,        # add here
        )
    }
```

---

## BaseService Key Methods

| Method | Description |
|--------|-------------|
| `start()` | Full startup sequence with timed operation logging |
| `stop()` | Graceful stop |
| `restart()` | Stop + start |
| `set_enabled_disabled(bool)` | Toggle via `config.disabled_key` |
| `update_fields(dict)` | Delegates to `config.update_fields()` |
| `live_options()` | `config.model_dump()` — current config state |
| `cleanup_tasks()` | Override per-service to cancel active tasks |
| `build_manager(task)` | Create task-specific manager (override per-service) |
| `handle_process_returncode(code, op, stderr)` | Standardized error handling for subprocesses |

### start() Sequence (per service type)

```python
match self.service_type:
    case ServiceType.DAEMON_CLIENT:
        await self._check_dependencies()
        await self._force_kill_service()
        await self._start_daemon()
        await asyncio.sleep(self.config.post_daemon_startup_delay)
        await self._capture_pid()
        await self._start_client()
    case ServiceType.CLIENT_ONLY:
        await self._check_dependencies()
        await self._start_client()
    case ServiceType.DAEMON_ONLY:
        await self._check_dependencies()
        await self._force_kill_service()
        await self._start_daemon()
        await asyncio.sleep(self.config.post_daemon_startup_delay)
        await self._capture_pid()
    case ServiceType.UTILITY_FACTORY:
        await self._check_dependencies()
        self.is_running = True  # Always "ready" after deps check
```

---

## State Classes (bot/service/state/)

Each task has its own state instance created by the service's `build_manager()`. All inherit `BaseState`:

| State Class | Service |
|-------------|---------|
| `AriaState` | Aria2 |
| `QbittorrentState` | qBittorrent |
| `TelegramState` | Telegram upload/download |
| `FFMpegState` | FFmpeg processing |
| `GDriveState` | Google Drive |
| `RcloneState` | Rclone cloud sync |
| `YoutubeState` | yt-dlp |
| `SevenZState` | 7-Zip archiving |
| `CloneChatState` | Chat Cloner |
| `QueueState` | Queue waiting |

### BaseState Key Properties

```python
state.name              # Task/file name
state.size              # Total bytes
state.processed_bytes   # Bytes done
state.progress          # 0–100 float
state.speed             # bytes/sec
state.eta               # Estimated seconds remaining
state.elapsed           # Seconds elapsed
state.status            # TaskStatus enum

await state.update()                         # Refresh from service/subprocess
message = await state.to_readable_message()  # Format for display
await state.cancel_task(reason)              # Cancel + cleanup
```

Helper subclasses:
- `SubState` — subprocess tracking (files, process handle, count, memory monitor)
- `ReportState` — result tracking (links, stats)

---

<<<<<<< HEAD
=======
## Force-Kill Safety — Never Target the Current Process

`_force_kill_service()` (in `base.py`) runs three concurrent strategies to clear a
service's daemon before (re)starting it: `kill_by_pid`, `kill_by_pkg` (`pgrep`/`kill -f
binary_path`), and `kill_by_port` (`lsof -ti :port`). All three exclude `os.getpid()`
(the bot's own PID) before sending any signal.

This guard exists because **`WebServerService` runs uvicorn in-process** — the
listening socket and any matching `binary_path`/port belong to the bot's own PID, not
an external subprocess. Without the exclusion, restarting WEBS (e.g. via "Start All
Enabled" while it's already running) could pattern-match or port-match the bot's own
PID and SIGTERM the entire process instead of a stray daemon. `WebServerService`
additionally closes its uvicorn listening sockets explicitly in `_force_kill_service`
Phase 1 (cancelling the task alone doesn't run uvicorn's own socket-closing shutdown
logic), so the port is actually free before Phase 2's `kill_by_port` / `_wait_for_port_free`
runs.

When adding a new service, if it ever runs in-process (shares the bot's PID) rather
than as an external subprocess, treat this the same way: never assume `kill_by_pid` /
`kill_by_pkg` / `kill_by_port` are safe by default — verify the self-PID exclusion
still covers it, or override `_force_kill_service` to skip generic kill-by-pattern
logic entirely.

---

>>>>>>> 2ecb89d (update)
## Parallel vs Sequential Startup

Controlled by `GlobalConfig.service_action_mode_parallel` (default: parallel):

```python
# Parallel (faster, default)
await asyncio.gather(*(svc.start() for svc in enabled), return_exceptions=True)

# Sequential (debug mode)
for svc in enabled:
    result = await svc.start()
```
