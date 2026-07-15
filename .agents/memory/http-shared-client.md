---
name: httpx shared client pattern
description: bot/utils/http.py uses a module-level pooled AsyncClient for verify=True calls; verify=False gets a throwaway client. close_http_clients() must be called at shutdown.
---

`bot/utils/http.py` introduced a module-level `_shared_client: AsyncClient` that is reused across all `async_request` / `async_request_stream` / `get_content_type` calls where `verify=True`. This keeps the underlying TCP + TLS connection pool alive, avoiding a fresh handshake per call.

**Rule**: `verify=False` callers (self-signed hosts) always get a throwaway `async with AsyncClient(verify=False)` — httpx fixes `verify` at construction time, so you cannot toggle it per-request on a shared client. Never try to unify the two paths onto one client.

**Shutdown**: `close_http_clients()` (async) closes the shared client and resets `_shared_client = None`. It must be called during application shutdown (e.g., in the bot/service shutdown hook) to cleanly drain the connection pool.

**How to apply**: when adding a new HTTP call in `bot/`, always go through `async_request` / `async_request_stream` rather than creating your own `AsyncClient` — the shared pool handles efficiency automatically. Pass `verify=False` only when the target is a self-signed host.
