---
name: sys.executable vs bare python3
description: Always use sys.executable for subprocess calls inside the bot — bare "python3" resolves to Nix 3.12 on Replit, not the venv interpreter.
---

# sys.executable vs bare "python3"

## The rule

**Any subprocess call inside the bot process that needs Python must use `sys.executable`, never the string `"python3"` or `"python"`.**

```python
# BAD — resolves to Nix Python 3.12 on Replit, not the venv:
proc = await create_subprocess_exec("python3", "update.py")
out, err, code = await cmd_exec(["python3", "--version"])

# GOOD — same interpreter that's running the bot:
from sys import executable
proc = await create_subprocess_exec(executable, "update.py")
out, err, code = await cmd_exec([executable, "--version"])
```

## Why

On Replit, `PATH` contains Nix-managed Python 3.12 interpreters before any venv activation. While `start.sh` activates the venv (adding `.venv/bin/` to PATH), subprocess calls inherit the environment but the string `"python3"` may still resolve to the Nix 3.12 entry depending on PATH ordering. Using `sys.executable` is always an absolute path to the running interpreter — no PATH lookup required.

Known callsites where this was caught:
- `bot/modules/system/restart.py` — `create_subprocess_exec("python3", "update.py")` → would have run `update.py` under Python 3.12
- `bot/modules/system/stats.py` — `cmd_exec(["python3", "--version"])` → stats panel showed `3.12.x` instead of `3.14.6`

## How to apply

- Grep for `"python3"` or `"python"` string literals in subprocess/exec calls when adding new system commands.
- `sys.executable` is already available from stdlib; no extra import needed if `sys` is already imported.
- The `executable` name is available as a direct import: `from sys import executable`.
