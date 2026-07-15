---
name: API endpoint error hygiene
description: FastAPI handler and service-layer rules for safe error responses — no detail leaks, consistent guard pattern, structured log hygiene.
---

# API endpoint error hygiene

## The rule

**Every FastAPI handler** must have an `except Exception` guard that returns `detail="Internal server error"` (never `detail=str(e)`).

Standard handler guard pattern:
```python
try:
    ...
except ValueError as e:          # only when the endpoint has user-controlled inputs
    raise HTTPException(400, detail=str(e))   # str(e) OK here — ValueError msgs are ours
except HTTPException:
    raise                         # let explicit 4xx/5xx through
except Exception:
    LOGGER.exception("handler_name failed")   # plain string — exc_info captured automatically
    raise HTTPException(500, detail="Internal server error")
```

**Service-layer ValueErrors** must not embed raw third-party exception text:
```python
# BAD — leaks Pydantic internals:
raise ValueError(f"Invalid product data for category {category}: {e}")

# GOOD — log internally, surface only category:
LOGGER.error("Validation failed for category", category=category, error=str(e))
raise ValueError(f"Invalid product data for category '{category}'")
```

**AccessResult / user-visible failure messages** must not contain `str(e)`:
```python
# BAD:
return AccessResult(success=False, message=f"Failed: {e!s}", ...)

# GOOD:
LOGGER.exception("Failed to generate/send access link")   # no {e} — exc_info captures it
return AccessResult(success=False, message="Failed to send access link. Please try again.", ...)
```

**External-party webhook/payment responses** must never echo service-layer exception text:
```python
# BAD:
except ValueError as e:
    return JSONResponse(content={"message": str(e)}, status_code=200)

# GOOD:
except ValueError as e:
    LOGGER.warning("Webhook processing ValueError", error=str(e))
    return JSONResponse(content={"message": "Webhook processing failed"}, status_code=200)
```

**Bare `except:` is forbidden** — use `except Exception:` everywhere:
```python
# BAD — catches KeyboardInterrupt, SystemExit, GeneratorExit:
try:
    ...
except:
    pass

# GOOD — allows process shutdown signals through:
try:
    ...
except Exception:
    ...
```

**`LOGGER.exception` must precede every 500 raise:**
```python
# BAD — silent 500, no log entry:
except Exception:
    raise HTTPException(500, detail="Internal server error")

# GOOD:
except Exception:
    LOGGER.exception("inventory_list failed")
    raise HTTPException(500, detail="Internal server error")
```

**Completion status (as of Round 22 — 2026-06-25):**
- All route handlers in `backend/api/` (v1, v2, public) have outer try/except guards — 0 unguarded.
- All `except Exception:` blocks that raise HTTP 500 also call `LOGGER.exception(...)` first.
- Zero bare `except:` clauses (catching BaseException) anywhere in `bot/`, `backend/`, `database/`, `utils/`.

**Why:** `str(e)` in a 500 response can expose file paths, DB schema details, Pydantic field names, and internal class names. Webhook responses are B2B but still external. Guard parity across v1/v2/public is required — GET handlers are often left bare while mutations already have guards.

**How to apply:**
- When adding a new endpoint, wrap the entire handler body in try/except.
- When reviewing existing endpoints, check GET handlers specifically — mutations (POST/PUT/DELETE) tend to already have guards; reads are often left bare.
- When writing a service `raise ValueError`, the message should describe the user-level problem without embedding `{e}`.
- v1/v2/public endpoint guard parity: all three layers must have identical guard coverage.
