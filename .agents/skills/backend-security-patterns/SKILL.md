---
name: backend-security-patterns
<<<<<<< HEAD
description: Use this skill when working on backend auth, guards, session management, rate limiting, Telegram WebApp validation, replay attack prevention, or IP handling. Covers JWT vs Cookie auth, dependency selection, session lifecycle, rate limiters, and security configuration.
=======
description: >-
  Use this skill when working on backend auth, guards, session management, rate
  limiting, Telegram WebApp validation, replay attack prevention, or IP
  handling. Covers JWT vs Cookie auth, dependency selection, session lifecycle,
  rate limiters, and security configuration.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Backend Security Patterns

---

## Auth Models: v1 vs v2

| Feature | v1 | v2 |
|---------|----|----|
| Token transport | `Authorization: Bearer <jwt>` | HttpOnly Cookie `access_token` |
| Token lifetime | 10 minutes | 24 hours |
| Login requirement | `wallet_id` + `password` | `wallet_id` + `password` + `X-Telegram-Init-Data` |
| `user_id` source | `wallet_id` (same value) | Telegram initData (cryptographically signed — cannot be spoofed) |

---

## Guard Dependency Reference

```python
from backend.api.dependencies import (
    require_auth_token,          # v1: JWT Bearer via Security() — for non-login endpoints
    require_auth_token_login,    # v1: JWT Bearer via Depends() — for login/logout endpoints
    require_auth_cookies,        # v2: HttpOnly Cookie via Security()
    require_auth_cookies_login,  # v2: HttpOnly Cookie via Depends() — for login/logout endpoints
    require_auth,                # any: Cookie first, then Bearer fallback
    require_role_dev_v1,         # v1: Bearer + user_id == dev_id
    require_role_dev_v2,         # v2: Cookie + user_id == dev_id
    require_telegram_webapp,     # v2 login: validates X-Telegram-Init-Data header
)
```

All auth guards return `AuthRequest`:

```python
from backend.schemas.auth import AuthRequest

# Fields available after auth:
auth.user_id    # int — Telegram user ID
auth.wallet_id  # int — wallet ID (same as user_id in v1; from initData in v2)
```

Dev guards are applied **at router level**, not per-endpoint:

```python
api_router_v1.include_router(log.router, dependencies=[Depends(require_role_dev_v1)])
```

---

## Session Lifecycle

Sessions are stored in MongoDB `sessions` collection.

### Login (v1)

```python
session_id = str(uuid.uuid4())
ip_address  = get_client_ip(request)   # TCP layer only — never X-Forwarded-For
user_agent  = request.headers.get("User-Agent", "")

<<<<<<< HEAD
await db_manager.sessions.store_session(
=======
await db_manager.web_sessions.store_session(
>>>>>>> 2ecb89d (update)
    wallet_id, session_id,
    user_id=user_id,
    ip_address=ip_address,
    user_agent=user_agent,
)
# DuplicateKeyError → 409 Conflict (one active session per wallet enforced at DB level)
```

### Login (v2)

`user_id` is taken from `X-Telegram-Init-Data` (not from `wallet_id`) — prevents spoofing by a malicious client passing a crafted `wallet_id`.

### Logout

```python
<<<<<<< HEAD
await db_manager.sessions.revoke_session(auth.wallet_id)
=======
await db_manager.web_sessions.revoke_session(auth.wallet_id)
>>>>>>> 2ecb89d (update)
# v2 also clears the access_token cookie from browser
```

### Session Validation (ongoing requests)

<<<<<<< HEAD
`require_auth_session` validates the session via DB `sessions` collection. Telegram re-validation is **intentionally omitted** on subsequent requests (validated once at login, cached session used thereafter for performance).
=======
`require_auth_session` validates the session via DB `web_sessions` collection. Telegram re-validation is **intentionally omitted** on subsequent requests (validated once at login, cached session used thereafter for performance).
>>>>>>> 2ecb89d (update)

---

## Telegram WebApp initData Validation

```python
# HMAC-SHA256 using "WebAppData" as key prefix
key   = hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()
check = hmac.new(key, data_check_string.encode(), hashlib.sha256).hexdigest()

# auth_date freshness check:
max_age = 86400  # 24 hours
if (time.time() - auth_date) > max_age:
    raise WebAppValidationError("initData expired")
```

In `test_mode`, missing `X-Telegram-Init-Data` falls back to `get_test_mode_user()` instead of raising an error.

```python
from backend.common import get_test_mode_user

# Returns a default UserData instance for local development
user_data = get_test_mode_user()
```

---

## Rate Limiting

Two implementations — same interface:

| Class | Backend | Use Case |
|-------|---------|----------|
| `RateLimiter` | In-memory dict | Single-worker deployments |
| `MongoRateLimiter` | MongoDB | Multi-worker (production) |

`make_rate_limiter()` factory selects based on `web_config.rate_limit_backend`:

```python
from backend.api.dependencies import make_rate_limiter, rate_limit_dependency

# Create a limiter tied to a config key:
auth_rate_limiter = make_rate_limiter(
    config_key="rate_limit_auth_requests",  # field name in WebsConfig
    window_seconds=60,
)

# Use as a FastAPI dependency:
@router.post("/login")
async def login(
    request: Request,
    payload: AuthLoginRequest,
    _: bool = Depends(rate_limit_dependency(auth_rate_limiter)),
) -> JSONResponse:
    ...
```

**Whitelist**: IPs in `web_config.allowed_ips` bypass the rate limiter entirely. All other IPs — including loopback — are subject to the same limit.

**No automatic LAN/loopback exemption** — prevents `X-Forwarded-For` spoofing bypass.

---

## IP Address Determination

```python
from backend.common import get_client_ip

ip = get_client_ip(request)
# → request.client.host  (TCP connection IP)
# Never reads X-Forwarded-For — client-spoofable, always use TCP layer
```

---

## Replay Attack Prevention

Payment webhook handlers call `check_replay_attack` before processing:

```python
from backend.core.security import check_replay_attack

is_replay = await check_replay_attack(tx_id)
if is_replay:
    raise HTTPException(status_code=409, detail="Duplicate transaction")
```

**Fail-closed**: if MongoDB is unavailable, `check_replay_attack` returns `True` (blocks) — never lets a duplicate through during DB outages.

---

## Security Headers

Applied automatically by `security_headers_middleware` in `main.py`:

```
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
Referrer-Policy: strict-origin-when-cross-origin
Content-Security-Policy: <full directives for Telegram WebApp>
```

**Exception**: `text/event-stream` responses (SSE) are skipped — injecting headers into a `StreamingResponse` drains the body channel and breaks the live stream.

---

## JWT Utilities (`backend/core/security.py`)

```python
from backend.core.security import (
    create_access_token,  # create JWT (HS256)
    verify_token,         # verify JWT → dict; raises HTTPException if expired/invalid
    set_auth_cookie,      # set access_token HttpOnly cookie on response
    get_auth_cookie,      # read access_token cookie from request
    verify_password,      # bcrypt verify(plain, hashed)
    get_password_hash,    # bcrypt hash(password)
    check_replay_attack,  # check duplicate tx_id in DB; fail-closed
)

# Create a 24-hour token:
token = create_access_token(
    data={"user_id": user_id, "wallet_id": wallet_id},
    expires_delta=timedelta(hours=24),
)

# Set as HttpOnly cookie (v2):
set_auth_cookie(response, token)
```

---

## WebsConfig Security Fields

```python
from backend.core.config import web_config

web_config.jwt_secret_key                # str — HS256 signing key
web_config.access_token_expire_seconds   # int — JWT lifetime
web_config.cors_allowed_origins          # list[str] — ["*"] or specific domains
web_config.trusted_hosts                 # list[str] — TrustedHostMiddleware
web_config.rate_limit_backend            # "memory" | "db"
web_config.rate_limit_auth_requests      # int — max login requests per window
web_config.allowed_ips                   # list[str] — rate limit whitelist
web_config.test_mode                     # bool — True when NODE_ENV=development
web_config.main_bot_id                   # int | None
web_config.dev_id                        # int | None — user with developer privilege
web_config.bot_token                     # str | None — for initData HMAC validation
```

---

## Password Comparison

Always use constant-time comparison to prevent timing attacks:

```python
import secrets

if not secrets.compare_digest(wallet.password, payload.password):
    raise HTTPException(status_code=401, detail="Incorrect username or password")

# ❌ WRONG — timing side-channel
if wallet.password != payload.password:
    ...
```
