---
name: Service force-kill must exclude the current process's own PID
description: >-
  Durable invariant — BaseService's generic force-kill helpers must never
  target os.getpid(). Diagnosis cue for "restarting one service killed the
  whole bot" style bugs.
---

## The invariant

`BaseService._force_kill_service()`'s kill strategies (by PID, by
binary-name pattern, by port) are written for *external* daemon
subprocesses. Any service that could ever run **in-process** (sharing the
bot's own PID/event loop instead of spawning a subprocess) breaks that
assumption: its binary-path pattern, captured PID, or bound port can
legitimately resolve to the bot's own PID, especially in the moment right
after that service's task is cancelled but before its listening socket is
actually released.

**Why:** a kill-by-pattern/port/pid strategy that doesn't know it might BE
the current process will happily SIGTERM it, and the bot's own signal
handler then treats that as an external shutdown request — tearing down
every other running service too. This is a "one service restart kills the
whole app" class of bug, not just a WebServer-specific quirk.

**How to apply:** whenever adding or touching a `BaseService` subclass —
especially one that runs in-process rather than as a real subprocess —
confirm the self-PID exclusion still covers its kill path, or have it skip
generic kill-by-pattern/port logic entirely. Don't assume "it's just
killing its own daemon" is safe by construction.
