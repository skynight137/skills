---
name: asyncio.wait requires Tasks on Python 3.11+
description: asyncio.wait forbids bare coroutines since Python 3.11 — must wrap in create_task(); cancel pending tasks in finally.
---

## Rule

`asyncio.wait(aws, ...)` requires every element of `aws` to be a Task or Future.

Since **Python 3.11**, passing a bare coroutine raises:
```
TypeError: Passing coroutines is forbidden, use tasks explicitly.
```

This project runs Python 3.14 — the error is always raised.

## Correct Pattern

```python
from asyncio import create_task, wait, FIRST_COMPLETED

t_a = create_task(event_a.wait())
t_b = create_task(event_b.wait())
try:
    done, _ = await wait({t_a, t_b}, timeout=N, return_when=FIRST_COMPLETED)
finally:
    t_a.cancel()   # cancel whichever did not win the race
    t_b.cancel()   # prevents "Task was destroyed but it is pending" warnings
```

**Why:** `asyncio.wait` returns a (done, pending) pair. Any task still in `pending` after the call is still live in the event loop. Not cancelling them leaks event-loop state and produces warnings on shutdown.

## Application in This Codebase

`bot/client/mixin_messaging.py` — `wait_for_message` wraps `event_flag.wait()` and `cancel_event.wait()` in `create_task()` before passing to `wait()`. Both tasks are cancelled in the single merged `finally` block.
