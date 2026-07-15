---
name: backend-wallet-service-patterns
<<<<<<< HEAD
description: Use this skill when working on WalletService, wallet endpoints, transaction history, balance operations, or wallet config updates. Covers atomic balance ops, cursor-based history pagination, TransactionType, WalletDetailResponse, and schema patterns.
=======
description: >-
  Use this skill when working on WalletService, wallet endpoints, transaction
  history, balance operations, or wallet config updates. Covers atomic balance
  ops, cursor-based history pagination, TransactionType, WalletDetailResponse,
  and schema patterns.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Backend Wallet Service Patterns

---

## WalletService Overview

Location: `backend/services/wallet.py`

| Method | Description |
|--------|-------------|
| `get_wallet(wallet_id)` | Sync — reads from in-memory cache only |
| `get_wallet_detail(wallet_id)` | Async — DB fetch, returns dict with `is_dev` flag |
| `add_credits(wallet_id, amount, ...)` | Atomic `$inc` top-up; logs TOPUP transaction |
| `deduct_credits(wallet_id, amount, ...)` | Atomic conditional `$inc`; raises `ValueError` if insufficient |
| `add_transaction(wallet_id, amount, ...)` | Low-level: write transaction record only (no balance change) |
| `get_wallet_history(wallet_id, ...)` | Cursor-based pagination via `last_doc_id` |
| `update_config(wallet_id, data)` | Update trakteer/saweria usernames & API keys |

---

## Atomic Balance Operations

Both use MongoDB `$inc` — safe for concurrent multi-VPS writes:

```python
# Top-up (never fails on low balance):
await WalletService.add_credits(
    wallet_id=buyer_id,
    amount=round(amount, 1),         # always round to 1 decimal
    product_id=product.id,
    product_name=product.product_name,
    product_desc="Topup (+100 credits)",
    tx_id=tx_id,                     # optional; random hex if omitted
)

# Deduct (raises ValueError if wallet not found or balance < amount):
try:
    await WalletService.deduct_credits(
        wallet_id=seller_id,
        amount=round(tax_amount, 1),
        product_id=product_id,
        product_name="Platform Fee",
        product_desc=f"Tax (5%) for {product_id}",
    )
except ValueError as e:
    raise HTTPException(status_code=400, detail=str(e))
```

**Rules:**
- Always `round(amount, 1)` before passing — balance is stored with 1 decimal precision
- `deduct_credits` is fail-closed: raises `ValueError`, never produces a negative balance
- The methods log their own transactions automatically; never call `add_transaction` alongside them

---

## Transaction Types

```python
from database.models.transaction import TransactionType

TransactionType.TOPUP   # credit from payment provider
TransactionType.IN      # credit from a sale (seller receives)
TransactionType.OUT     # debit (fee, withdrawal)
```

`add_credits` always logs `TOPUP`. `deduct_credits` always logs `OUT`. `add_transaction` defaults to `IN` if no `tx_type` given.

---

## get_wallet_history — Cursor Pagination

```python
from bson.objectid import ObjectId

history, total = await WalletService.get_wallet_history(
    wallet_id=auth.wallet_id,
    limit=50,
    tx_type="all",           # "all" | "topup" | "in" | "out"
    keywords=None,
    start_date=None,
    end_date=None,
    last_doc_id=None,        # pass last item's ObjectId str for next page
)
```

Response pattern:
```python
items = [tx.model_dump(mode="json") for tx in history]
return JSONResponse(content={"items": items, "total": total, "last_doc_id": items[-1]["doc_id"] if items else None})
```

---

## get_wallet_detail — is_dev Flag

```python
detail = await WalletService.get_wallet_detail(wallet_id)
# Returns dict (password and trakteer_api_key are excluded)
# detail["is_dev"] == True if wallet_id == web_config.dev_id
```

If the wallet doesn't exist in DB, a default `WalletModel(id=wallet_id)` is returned — never `None`.

---

## update_config

Only updates these three fields (others are ignored):

```python
await WalletService.update_config(wallet_id, {
    "trakteer_username": "username",
    "saweria_username": "username",
    "trakteer_api_key": "key",
})
```

---

## Schemas (`backend/schemas/wallet.py`)

```python
from backend.schemas.wallet import (
    WalletDetailRequest,       # wallet_id: int
    WalletDetailResponse,      # extends WalletModel + is_dev: bool
    WalletHistoryRequest,      # limit, tx_type, keywords, start_date, end_date, last_doc_id
    WalletTopupRequest,        # wallet_id, amount, product_id, product_name, product_desc, tx_id
    WalletDeductRequest,       # wallet_id, amount, product_id, product_name, product_desc, tx_id
    WalletUpdateConfigRequest, # wallet_id, trakteer_username, saweria_username, trakteer_api_key
)
```

Key schema patterns:
```python
class WalletHistoryRequest(BaseModel):
    limit: int = Field(default=50, ge=1, le=10000)
    tx_type: str = Field(default="all")
    last_doc_id: str | None = Field(default=None)  # cursor

class WalletTopupRequest(BaseModel):
    tx_id: str = Field(default_factory=lambda: str(uuid.uuid4()))  # auto-generated if omitted
    product_id: str = Field(..., pattern=constants.PRODUCT_ID_PATTERN)
    product_name: str = Field(..., pattern=constants.PRODUCT_NAME_PATTERN)
```

---

## Endpoint Patterns

<<<<<<< HEAD
=======
Every handler requires an outer guard — `except HTTPException: raise` then `except Exception → LOGGER.exception + 500`.

>>>>>>> 2ecb89d (update)
```python
# v2: POST /wallet/topup  (dev-only router)
@router.post("/topup")
async def topup_wallet(
    payload: WalletTopupRequest,
    auth: AuthRequest = Depends(require_auth_cookies_login),
) -> JSONResponse:
<<<<<<< HEAD
    await WalletService.add_credits(
        wallet_id=payload.wallet_id,
        amount=payload.amount,
        product_id=payload.product_id,
        product_name=payload.product_name,
        product_desc=payload.product_desc,
        tx_id=payload.tx_id,
    )
    return JSONResponse(content={"message": "Credits added"})
=======
    try:
        await WalletService.add_credits(
            wallet_id=payload.wallet_id,
            amount=payload.amount,
            product_id=payload.product_id,
            product_name=payload.product_name,
            product_desc=payload.product_desc,
            tx_id=payload.tx_id,
        )
        return JSONResponse(content={"message": "Credits added"})
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception:
        LOGGER.exception("topup_wallet failed")
        raise HTTPException(status_code=500, detail="Internal server error")
>>>>>>> 2ecb89d (update)

# v2: POST /wallet/history
@router.post("/history")
async def wallet_history(
    payload: WalletHistoryRequest,
    auth: AuthRequest = Depends(require_auth_cookies_login),
) -> JSONResponse:
<<<<<<< HEAD
    history, total = await WalletService.get_wallet_history(
        wallet_id=auth.wallet_id, **payload.model_dump()
    )
    items = [tx.model_dump(mode="json") for tx in history]
    return JSONResponse(content={"items": items, "total": total})
=======
    try:
        history, total = await WalletService.get_wallet_history(
            wallet_id=auth.wallet_id, **payload.model_dump()
        )
        items = [tx.model_dump(mode="json") for tx in history]
        return JSONResponse(content={"items": items, "total": total})
    except HTTPException:
        raise
    except Exception:
        LOGGER.exception("wallet_history failed")
        raise HTTPException(status_code=500, detail="Internal server error")
>>>>>>> 2ecb89d (update)
```

---

## Cache vs DB

- `get_wallet()` (sync) — in-memory cache only, fast for hot path (e.g. payment validation)
- `get_wallet_detail()` (async) — always hits MongoDB, returns fresh data for user-facing endpoints
