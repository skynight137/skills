---
name: bot-task-patterns
<<<<<<< HEAD
description: Use this skill when working on the task system — TaskConfig, TaskListener, TaskManager, ConcurrentManager, TaskPolicy, TaskProcessor, or adding a new task-based command. Covers task phases, argument parsing, policy checks, cancellation, and multi-destination workflows.
=======
description: >-
  Use this skill when working on the task system — TaskConfig, TaskListener,
  TaskManager, ConcurrentManager, TaskPolicy, TaskProcessor, or adding a new
  task-based command. Covers task phases, argument parsing, policy checks,
  cancellation, and multi-destination workflows.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot Task Patterns

The task system is a multi-phase pipeline: Download → Process → Upload (or Clone). All task-based commands flow through `bot/task/`.

---

## Module Map

```
bot/task/
├── config.py      # TaskConfig — task state container + configure_task()
├── listener.py    # TaskListener — phase callbacks (on_download_start, etc.)
├── manager.py     # TaskManager + ConcurrentManager — queue & execution
├── policy.py      # TaskPolicy — limits, balance, duplicates
├── processor.py   # TaskProcessor — post-download processing (extract, ffmpeg, etc.)
├── status.py      # TaskStatus enum
└── __init__.py    # Minimal exports (avoid circular imports)
```

---

## High-Level Flow

```
User /mirror command
  → Plugin handler (bot/plugins/*.py)
  → YourTask(TaskConfig).new_event()
      → parse args via arg_parser()
      → await self.configure_task()
  → task_manager.dl_manager.submit(task_config)
  → ConcurrentManager._runner() picks up
  → TaskListener.on_download_start()
  → service_controller.{service}.build_manager(task).download()
  → dl_event.wait()
  → on_download_complete() → pr_manager.submit()
  → on_processing_complete() → ul_manager.submit()
  → on_upload_complete() → cleanup_and_finish()
```

---

## Arguments

Parsed via `bot/utils/fmt.py::arg_parser()`:

```python
args = arg_parser(input_list, {
    "link": "",
    "-n": "",
    "-up": "",
    "-z": False,
    "-e": False,
    "-doc": False,
    "-med": False,
})
```

### Common Flags

| Flag | Type | Description |
|------|------|-------------|
| `link` | str | Download source URL/magnet/gdrive |
| `-n` | str | Rename file |
| `-up` | str | Upload destination (see formats below) |
| `-z` | bool | Archive to zip |
| `-e` | bool | Extract archive |
| `-d` | bool | Seed torrent |
| `-s` | bool | Interactive file selector |
| `-f` | bool | Force run (bypass queue) |
| `-doc` | bool | Force upload as document |
| `-med` | bool | Force upload as media |
| `-t` | str | Thumbnail URL |
| `-ss` | bool/str | Generate screenshots |
| `-sv` | bool/str | Sample video |
| `-cv` | str | Convert video format |
| `-ex` | str | Exclude extensions |
| `-wh` | int | Worker hint (specific bot_id) |
| `-yo` | str | yt-dlp options JSON |
| `-ff` | str | FFmpeg commands JSON |
| `-rcf` | str | Rclone flags JSON |

### Destination Formats (`-up`)

```
tg:                          # Default Telegram dump chat
tg:-1001234567               # Specific chat
tg:-1001234567:123           # Chat + thread_id
gdrive:                      # Default GDrive folder
gdrive:mtp:folder_id         # User token + folder
gdrive:sa:/path/sa.json:fid  # Service account
rclone:                      # Default rclone remote
rclone:mrc:remote:path       # User config + remote:path
```

Multi-destination (comma-separated):
```
-up tg:-1001234,gdrive:mtp:folder_id,rclone:mrc:remote:path
```

---

## Creating a New Task Module

```python
# bot/modules/your_module.py
from bot.task.config import TaskConfig
from bot.utils.fmt import arg_parser

class YourTask(TaskConfig):
    async def new_event(self):
        # 1. Parse args
        args = arg_parser(self.message.text.split(), {"link": "", "-flag": False})
        self.link = args["link"]
        self.is_your_type = True  # classify task type

        # 2. Configure task (validates, sets up paths, destinations)
        await self.configure_task()

        # 3. Submit to appropriate manager
        await self.client.task_manager.dl_manager.submit(self)
```

---

## configure_task() — What It Does

Called before submission. Sets up:
1. `set_worker()` — assign execution worker
2. `_setup_excluded_extensions()`
3. `_setup_split_configuration()`
4. `_setup_stop_duplicate()`
5. `_setup_ffmpeg_commands()`
6. `_setup_rclone_flags()`
7. `_setup_yt_dlp_options()`
8. `_setup_thumbnail()`
9. `_handle_special_links()` — GDL/RCL file selection
10. `_check_credentials_exist()`
11. `_configure_upload_destination()` — parse `-up`
12. `_set_mode_engine()` — set mode [in, pr, out]
13. `_validate_service_access()`
14. `await self.dir.mkdir()` — create task directory

---

## TaskManager & ConcurrentManager

```python
# 4 managers, each with a semaphore:
task_manager.dl_manager   # Download phase
task_manager.pr_manager   # Processing phase
task_manager.ul_manager   # Upload phase
task_manager.cl_manager   # Clone phase

# Submit a task:
await task_manager.dl_manager.submit(task_config)

# Cancel a task:
await task_manager.cancel_task(task_config, "reason")

# Query tasks:
tasks = await task_manager.get_tasks_by(user_id=user_id)
tasks = await task_manager.get_tasks_by(task_link=link)
```

### Submission Flow (Atomic)

```python
# ConcurrentManager.submit() ensures race-free policy + queue:
async with user_lock:
    await task_config.policy.check_duplicate_task()
    await task_config.policy.check_user_tasks_limit()
    await task_config.policy.check_user_wallet_balance()
    async with self.tasks_lock:
        self.tasks[task_config.id] = task_config
        self.queue.put_nowait(task_config)
```

---

## TaskPolicy Checks

Executed in order during submission:

```python
# 1. Duplicate task (same link already queued)
await policy.check_duplicate_task()

# 2. Per-user concurrent task limit
await policy.check_user_tasks_limit()

# 3. Minimum wallet balance + credit lock
await policy.check_user_wallet_balance()

# 4. Task size limit (checked during execution)
await policy.check_task_size_limit()

# 5. GDrive destination duplicate check
await policy.stop_duplicate_on_destination()
```

All raise `TaskPolicyError` on failure (user gets notified, task not added).

---

## TaskStatus Enum

```python
class TaskStatus(Enum):
    # Queue states
    QUEUEDL = "queued_download"
    QUEUEPR = "queued_process"
    QUEUEUL = "queued_upload"
    QUEUECL = "queued_clone"

    # Active states
    DOWNLOAD = "downloading"
    UPLOAD = "uploading"
    CLONE = "cloning"

    # Processing substates
    EXTRACT = "extracting"
    ARCHIVE = "archiving"
    SPLIT = "splitting"
    JOIN = "joining"
    CONVERTVIDEO = "converting_video"
    FFMPEGPROCESS = "ffmpeg_processing"
    SCREENSHOT = "taking_screenshots"
    SAMPLEVIDEO = "sampling_video"

    # Other
    SEED = "seeding"
    PAUSE = "paused"

    # Terminal
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    TIMEOUT = "timeout"
```

Transition path: `QUEUEDL → DOWNLOAD → QUEUEPR → [process states] → QUEUEUL → UPLOAD → COMPLETED`

---

## Cancellation

```python
# Cancel via task_manager:
await task_manager.cancel_task(task_config, "User requested")

# Cancellation sources:
# 1. /cancel command
# 2. Queue/active/pause timeout (watchdog)
# 3. Policy violation
# 4. Service error
# 5. Worker shutdown
```

Cleanup is guaranteed via `try/finally` in `_execute_task()`.

---

## Multi-Destination Workflow

```
1. Download once
2. Process once
3. Upload to destination[0] → deduct cost → charged_destinations.add(0)
4. If pending_destinations: next_destination() → resubmit to ul_manager
5. Repeat until all destinations done → cleanup_and_finish()
```

---

## TaskManager Initialization (Startup)

```python
await task_manager.initialize(
    max_concurrent_dl=ConfigManager.GlobalConfig.max_concurrent_dl,
    max_concurrent_pr=ConfigManager.GlobalConfig.max_concurrent_pr,
    max_concurrent_ul=ConfigManager.GlobalConfig.max_concurrent_ul,
    max_concurrent_cl=ConfigManager.GlobalConfig.max_concurrent_cl,
)
```

Called once in `bot/__main__.py` before `ServiceController.start_all_enabled()`.

---

## ConcurrentManager Callback Map

| Manager | Queue Status | Active Status | Callback |
|---------|-------------|---------------|----------|
| DownloadManager | QUEUEDL | DOWNLOAD | on_download_start |
| ProcessManager | QUEUEPR | varies | on_processing_start |
| UploadManager | QUEUEUL | UPLOAD | on_upload_start |
| CloneManager | QUEUECL | CLONE | on_clone_start |
