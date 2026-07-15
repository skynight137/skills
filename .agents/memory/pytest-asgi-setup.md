---
name: pytest ASGI test client setup
description: Three non-obvious gotchas when writing httpx ASGITransport tests against this FastAPI app.
---

## Rule 1 — Use `https://localhost`, not `http://localhost`

`set_auth_cookie` sets `secure=True`.  httpx honours the `secure` flag and won't
send that cookie over plain HTTP.  Use `base_url="https://localhost"` —
ASGITransport is local so no real TLS is involved, but httpx treats it as HTTPS
and the cookie jar works correctly.

**Why:** Cookies silently dropped → v2 logout returns 401 in tests even though
login succeeded and the cookie was set.

**How to apply:** Always create the test client as
`AsyncClient(transport=ASGITransport(app=app), base_url="https://localhost")`.

---

## Rule 2 — TrustedHostMiddleware rejects `Host: test`

The app's `trusted_hosts` list contains `localhost` and `127.0.0.1`.  If you
use `base_url="http://test"`, httpx sends `Host: test` and the middleware
returns `400 Invalid host header`.

**How to apply:** Always use `https://localhost` (covers Rule 1 and Rule 2 together).

---

## Rule 3 — Session-scoped async fixtures conflict with `asyncio_default_fixture_loop_scope = "function"`

pytest-asyncio 1.4.0 with the project's `asyncio_default_fixture_loop_scope =
"function"` setting hangs (exit code -1, no output) when you declare a
`scope="session"` async fixture.

**How to apply:** Keep the `AsyncClient` fixture function-scoped.  Apply
session-wide patches via a sync `scope="session"` fixture using direct attribute
assignment (not `monkeypatch`); Python module caching ensures `backend.main` is
only imported once per process so the MongoDB startup cost is paid only on the
first test.

---

## Additional notes

- `PRODUCT_ID_PATTERN = r"^[A-Za-z0-9]{10}$"` — exactly 10 alphanumeric chars,
  no underscores or hyphens.  Use e.g. `"AbCdEf1234"` in tests.
- `MIN_USER_ID = 100_000_000` — test wallet IDs must be ≥ this.
- Error responses use `{"error": "...", "message": "...", "details": null}`,
  not FastAPI's default `{"detail": "..."}`.  Assert with
  `body.get("detail") or body.get("message", "")` to handle both.
- `WalletService.get_wallet` reads `db_manager.wallets.cache` (sync, in-memory).
  Mock it as a `staticmethod` directly on the class.
- `web_config.rate_limit_enabled = False` disables all in-process rate limiters
  without needing to patch individual `RateLimiter` instances.
