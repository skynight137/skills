# Project Log Reader

## Overview

This project writes structured JSON logs to `logs/bot.log.json` (relative to the workspace root).  
**Always read logs from this file** instead of using the workflow log tool, which may be incomplete or truncated.

This is the shared source of truth between the developer and the agent — both sides see exactly the same log entries.

---

## File Locations

| File | Description |
|---|---|
| `logs/bot.log.json` | Primary structured log — one JSON object per line (NDJSON) |
| `logs/bot.log` | Plain-text fallback (less detail) |
| `logs/qbit.log` | QBittorrent service log |

---

## How to Read Logs

### Quick tail (last N entries, filtered by keyword)

```bash
tail -200 logs/bot.log.json | python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin if l.strip()]
for line in lines:
    try:
        d = json.loads(line)
        lvl   = d.get('level', '')
        event = d.get('event', '')
        logger_parts = d.get('logger', '').split('.')
        src   = '.'.join(logger_parts[-2:])
        # Change keywords below to match what you are debugging
        if any(k in event.lower() for k in ['expir', 'error', 'warning', 'delete']):
            print(f'[{lvl}] {src}: {event}')
    except:
        pass
"
```

### Read all fields for a specific event pattern

```bash
grep -i "expir" logs/bot.log.json | tail -20 | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        print(json.dumps(d, indent=2, default=str))
    except:
        pass
"
```

### Count log levels (quick health check)

```bash
python3 -c "
import json
counts = {}
with open('logs/bot.log.json') as f:
    for line in f:
        try:
            d = json.loads(line.strip())
            lvl = d.get('level','?')
            counts[lvl] = counts.get(lvl, 0) + 1
        except: pass
for k,v in sorted(counts.items()): print(f'{k}: {v}')
"
```

### Filter by logger module

```bash
grep '"logger":"database.expiration' logs/bot.log.json | tail -30
```

---

## Log Schema (NDJSON)

Each line is a valid JSON object with at minimum these fields:

```json
{
  "level":     "debug | info | warning | error | critical",
  "event":     "Human-readable message",
  "logger":    "dotted.module.path.ClassName",
  "func_name": "method_name",
  "lineno":    42,
  "pathname":  "/home/runner/workspace/path/to/file.py",
  "timestamp": "2026-03-17T03:44:35.027430Z"
}
```

Extra fields (context-specific) are appended inline, e.g.:
- `wallet_id`, `product_id`, `inv_id` on expiration events
- MongoDB `DeleteResult`, `UpdateResult` objects from collection methods

---

## What to Look For

### Confirming a fix worked (example: expiration delete)
- ✅ Good: `DeleteResult({'n': 1, ...})` — document was actually deleted
- ❌ Bug: `DeleteResult({'n': 0, ...})` — filter matched nothing (wrong ID used)

### Confirming Multi-VPS guard triggered
- Look for: `ExpirationManager skipped on this node (designated node: X, current node: Y)`

### Startup sequence
- Each service logs `✅ {SERVICE} - ServiceStartup completed in X.XXs`
- ExpirationManager logs: `🚀 ExpirationManager loop started (interval: N seconds)`

---

## When to Use This Skill

- After restarting a workflow, check `logs/bot.log.json` to verify behavior
- When debugging silent failures (e.g., `n: 0` in MongoDB results)
- To confirm that newly uncommented code paths are actually being executed
- To compare expected vs actual log output without relying on workflow console
