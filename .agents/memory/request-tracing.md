---
name: Request tracing / X-Request-ID middleware
description: Outermost FastAPI middleware propagates X-Request-ID and binds it to every structlog line for the request lifetime.
---

## Rule
`request_id_middleware` in `backend/main.py` is the outermost middleware (added last → runs first).
It MUST call `structlog.contextvars.clear_contextvars()` before binding to prevent context leakage
between keep-alive requests that reuse the same asyncio Task.

## Behaviour
1. Reads `X-Request-ID` from the incoming request header, or generates a `uuid4()` if absent.
2. Clears all structlog contextvars, then binds `request_id=<id>`.
3. Every `LOGGER.*` call inside handlers, services, and collections automatically includes `request_id`.
4. Echoes the ID back on the response as `X-Request-ID`.

## Integration points
- **Client-side:** Pass `X-Request-ID` on outbound requests to correlate across logs.
- **Structlog:** Uses `structlog.contextvars` — not thread-locals; safe for async.
- **No bot-side propagation yet:** Bot log lines do not carry a request_id. If a request triggers
  a bot action, correlate by timestamp or add explicit forwarding.

**Why:** Outermost position ensures the ID is present in every log line including middleware
errors and early-exit paths.

**How to apply:** Never add a second `clear_contextvars()` call inside handlers — the middleware
already clears at the request boundary. When writing tests that check log output for request_id,
call `clear_contextvars()` in setUp/tearDown to avoid bleed between test cases.
