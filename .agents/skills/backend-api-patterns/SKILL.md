---
name: backend-api-patterns
description: Use this skill when working on backend/ — adding a new endpoint, understanding the router/service/DB layering, selecting the correct dependency guard, writing schemas, or registering a new router. Covers FastAPI structure, endpoint patterns, service calls, test mode, and SSE streaming.
---

# Backend API Patterns

FastAPI backend serving both a Telegram bot marketplace and a React SPA. Two versioned API namespaces (`v1`, `v2`) plus a shared `public` layer.

---

## Module Structure

```
backend/
├── main.py                    # App root: middleware, router registration, SPA fallback
├── api/
│   ├── dependencies.py        # All FastAPI dependency functions (guards, rate limiters)
│   ├── v1/
│   │   ├── router.py          # api_router_v1 (/api/v1)
│   │   └── endpoints/         # auth, product, inventory, wallet
│   ├── v2/
│   │   ├── router.py          # api_router_v2 (/api/v2)
│   │   └── endpoints/         # auth, product (+ update/remove/add), inventory (+ sales/add/update/remove), wallet
│   └── public/
│       └── endpoints/         # log, stats, oauth, payment, torrent (shared by v1 & v2)
├── services/                  # Business logic
│   ├── wallet.py              # WalletService
│   ├── product.py             # ProductService
│   ├── handle.py              # ProductHandleService (fulfillment)
│   ├── inventory.py           # InventoryService
│   ├── payment.py             # PaymentService
│   ├── stats.py               # StatisticsCache
│   ├── oauth.py               # OAuthService
│   ├── log.py                 # log_service
│   └── torrent.py             # TorrentService
├── schemas/                   # Pydantic request/response models
├── models/                    # Non-DB models (e.g. telegram.UserData)
├── provider/                  # Payment provider clients (Trakteer, Saweria)
├── core/
│   ├── config.py              # web_config (WebsConfig singleton)
│   └── security.py            # JWT, cookie, bcrypt, replay-attack helpers
├── constants.py               # URL prefixes, PaymentProvider, HTTPErrorMessages
├── common.py                  # FRONTEND_DIR, get_client_ip, is_ajax_request, result_to_dict
└── exceptions/                # WebAppException, WebAppValidationError
```

---

## Layer Responsibilities

| Layer | Location | Role |
|-------|----------|------|
| Endpoint | `backend/api/*/endpoints/*.py` | HTTP handler, request validation, `JSONResponse` formatting |
| Service | `backend/services/*.py` | Business logic, no HTTP types |
| DB | `database/collections/` | MongoDB interactions, collection cache |

**Rule**: Endpoints never touch DB directly. Services never import FastAPI types.

---

## Endpoint Pattern

```python
# backend/api/v1/endpoints/my_feature.py
from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import JSONResponse
import structlog

from backend.api.dependencies import require_auth_token_login
from backend.schemas.my_feature import MyRequest, MyResponse
from backend.services.my_feature import MyFeatureService

LOGGER = structlog.get_logger(__name__)
router = APIRouter(prefix="/my-feature", tags=["my-feature"])


@router.get("", response_class=JSONResponse)
async def list_items(
    limit: int = Query(50, ge=1, le=100),
    auth: AuthRequest = Depends(require_auth_token_login),
) -> JSONResponse:
    result = await MyFeatureService.get_list(limit=limit)
    return JSONResponse(content={"items": result, "total": len(result)})


@router.post("/{item_id}/action", response_class=JSONResponse)
async def do_action(
    item_id: str,
    payload: MyRequest,
    auth: AuthRequest = Depends(require_auth_token_login),
) -> JSONResponse:
    result = await MyFeatureService.perform_action(item_id, payload)
    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Item not found")
    return JSONResponse(content={"message": "Action completed"})
```

---

## Guard Selection

| Version | Use Case | Dependency |
|---------|----------|------------|
| v1 | Standard endpoint auth | `require_auth_token_login` |
| v1 | Dev-only (log, stats) | `require_role_dev_v1` (mounted at router level) |
| v2 | Standard endpoint auth | `require_auth_cookies_login` |
| v2 | Dev-only (log, stats) | `require_role_dev_v2` (mounted at router level) |
| any | Accept cookie OR bearer | `require_auth` |
| any | Telegram WebApp login | `require_telegram_webapp` |
| public | No auth | No dependency |

Dev guards are applied at **router** level (not per-endpoint):

```python
# backend/api/v1/router.py
api_router_v1.include_router(log.router, dependencies=[Depends(require_role_dev_v1)])
api_router_v1.include_router(stats.router, dependencies=[Depends(require_role_dev_v1)])
```

---

## Registering a New Router

### Step 1: Create the endpoint file

```python
# backend/api/v1/endpoints/my_feature.py
router = APIRouter(prefix="/my-feature", tags=["my-feature"])
```

### Step 2: Register in the router

```python
# backend/api/v1/router.py
from backend.api.v1.endpoints import auth, inventory, my_feature, product, wallet

api_router_v1.include_router(my_feature.router)
```

### Step 3: Add to `__init__.py` if needed

```python
# backend/api/v1/endpoints/__init__.py
from . import auth, inventory, my_feature, product, wallet
```

For **public** endpoints (shared by v1 and v2), place the file in `backend/api/public/endpoints/` and register in both `v1/router.py` and `v2/router.py`.

---

## Accessing `auth` from the JWT/Cookie

Both guards return `AuthRequest`:

```python
from backend.schemas.auth import AuthRequest

# AuthRequest fields:
auth.user_id    # int — Telegram user ID (from initData in v2, from wallet_id in v1)
auth.wallet_id  # int — wallet identifier
```

---

## Test Mode Guard

`web_config.test_mode` is `True` when `NODE_ENV=development`. Skip DB operations that are irrelevant for local dev:

```python
from backend.core.config import web_config

if not web_config.test_mode:
    await db_manager.sessions.store_session(...)
```

For Telegram WebApp validation, missing `X-Telegram-Init-Data` falls back to `get_test_mode_user()` in test mode.

---

## Error Handling

Always use `HTTPException` in endpoints. Use centralized messages from `backend/constants.py`:

```python
from backend import constants

raise HTTPException(
    status_code=status.HTTP_404_NOT_FOUND,
    detail=constants.HTTPErrorMessages.not_found("Product")
)
```

Custom exceptions for Telegram WebApp validation failures:

```python
from backend.exceptions import WebAppException, WebAppValidationError

raise WebAppValidationError("Invalid initData hash")
# → 403 Forbidden: {"message": "...", "details": "..."}
```

---

## SSE (Server-Sent Events) Pattern

Used in `log.py` for streaming log output. **Critical**: Do not apply security headers middleware to SSE — it breaks the stream.

```python
from fastapi.responses import StreamingResponse

@router.get("/stream")
async def stream_logs(file: str = Query(...)) -> StreamingResponse:
    async def event_generator():
        async for line in log_service.tail(file):
            yield f"data: {line}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")
```

The `security_headers_middleware` in `main.py` already skips `text/event-stream` responses automatically.

---

## Accessing Bot from Backend

Endpoints can reach live bot clients via `bot_manager`:

```python
from bot.core.bot_manager import bot_manager

bot_client = bot_manager.get_client(owner_id)
if not bot_client:
    raise HTTPException(status_code=503, detail="Bot client not available")
if not bot_client.is_connected:
    raise HTTPException(status_code=503, detail="Bot client is offline")
```

Common uses: generating deep links (`encode_deep_link`), sending bot messages, checking client state.

---

## Schema Conventions

```python
# backend/schemas/my_feature.py
from pydantic import BaseModel, Field

class MyRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)
    amount: float = Field(..., ge=0)

class MyResponse(BaseModel):
    id: str
    name: str
    created_at: datetime
```

Schemas live in `backend/schemas/`. Request schemas are validated automatically by FastAPI. Response content is manually serialized via `.model_dump(mode="json")` before passing to `JSONResponse`.

---

## `result_to_dict()` — pymongo Result Conversion

```python
from backend.common import result_to_dict

raw = await db_manager.products.insert_one(data)
return JSONResponse(content=result_to_dict(raw))
# → {"acknowledged": true, "inserted_id": "<id>"}
```

Handles `InsertOneResult`, `UpdateResult`, `DeleteResult`.

---

## Route Order Rule (v2 Inventory)

Fixed paths must be registered **before** path-param routes to avoid conflicts:

```python
# ✅ CORRECT order:
router.include_router(sales_router)    # /sales
router.include_router(add_router)      # /add
router.include_router(detail_router)   # /{item_id}/detail

# ❌ WRONG — /{item_id}/detail would swallow /sales
router.include_router(detail_router)
router.include_router(sales_router)
```
