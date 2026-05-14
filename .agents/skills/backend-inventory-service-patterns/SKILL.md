---
name: backend-inventory-service-patterns
description: Use this skill when working on InventoryService, inventory endpoints, purchased item management, access link generation (vip_chat/paid_message), inventory expiry, or bot_bundle/user_bundle cache invalidation. Covers add/update/remove/list, AccessResult, and schema patterns.
---

# Backend Inventory Service Patterns

---

## InventoryService Overview

Location: `backend/services/inventory.py`

| Method | Description |
|--------|-------------|
| `add_inventory(wallet_id, tx_id, item, expired_at)` | Add purchased product to inventory; polymorphic by category |
| `update_inventory(wallet_id, item_id, **kwargs)` | Update inventory item; ownership check; re-validates polymorphically |
| `remove_inventory(wallet_id, item_id)` | Delete; ownership check; invalidates config cache for bundles |
| `get_inventory_list(wallet_id)` | Sync — reads from in-memory cache |
| `get_inventory_detail(wallet_id, item_id)` | Async — DB fetch; returns `{}` if not found or access denied |
| `get_sales_count()` | Count purchases per product across all inventory |
| `generate_and_send_access_link(wallet_id, item_id)` | Generate + send access link for vip_chat/paid_message |

---

## Key Concept: Inventory vs Product

| Concept | ID field | Purpose |
|---------|----------|---------|
| `ProductItem` | `product.id` — reusable product identifier | Seller's product listing |
| `InventoryModel` | `inv.id` — unique per-purchase token_hex(5) | Buyer's purchased copy |

`item_id` in inventory endpoints always refers to `inv.id`, **not** `product.id`.

---

## add_inventory

Called by `ProductHandleService._handle_tax_and_inventory` — rarely called directly from endpoints.

```python
from database.models.inventory import InventoryModel

result, model = await InventoryService.add_inventory(
    wallet_id=buyer_id,
    tx_id=tx_id,
    item=product_model,      # ProductItem or dict
    expired_at=expired_at,   # datetime with tzinfo=UTC
)
```

Expiry patterns:
```python
from datetime import UTC, datetime, timedelta

LIFETIME = datetime(9999, 12, 31, 23, 59, 59, tzinfo=UTC)  # expire_after_seconds == 0

# Time-limited:
expired_at = datetime.now(UTC) + timedelta(seconds=packet.expire_after_seconds)

# Lifetime:
expired_at = LIFETIME
```

---

## Cache Invalidation on Bundle Changes

When `category == "bot_bundle"` or `"user_bundle"`, config caches are automatically invalidated on `add_inventory` and `remove_inventory`:

```python
# Handled internally by InventoryService:
from bot.config import BotConfig, UserConfig
BotConfig.invalidate(wallet_id)   # bot_bundle
UserConfig.invalidate(wallet_id)  # user_bundle
```

No manual invalidation needed when calling `InventoryService.add_inventory` or `remove_inventory`.

---

## remove_inventory

```python
try:
    await InventoryService.remove_inventory(
        wallet_id=auth.wallet_id,
        item_id=payload.item_id,   # inv.id, not product.id
    )
except ValueError as e:
    raise HTTPException(status_code=404, detail=str(e))
```

Raises `ValueError` if: item not found, or `inv.wallet_id != wallet_id`.

---

## generate_and_send_access_link — AccessResult

Only supported for `vip_chat` and `paid_message` categories.

```python
from backend.services.inventory import AccessResult

result: AccessResult = await InventoryService.generate_and_send_access_link(
    wallet_id=auth.wallet_id,
    item_id=payload.item_id,
)

if result.success:
    return JSONResponse(content=result.model_dump())
else:
    raise HTTPException(status_code=400, detail=result.message)
```

```python
@dataclass
class AccessResult:
    success: bool
    message: str
    category: str | None = None  # "vip_chat" or "paid_message"

    def model_dump(self):
        return {"success": self.success, "message": self.message, "category": self.category}
```

**vip_chat flow**: Creates a Telegram invite link (`create_chat_invite_link`) via the owner's bot client and sends it to `wallet_id` (buyer).

**paid_message flow**: Encrypts `_paid_{source_chat_id}_{start_id}_{end_id}_{buyer_id}` with `Encryption.encrypt(owner_id, max_len=64)` and builds `https://t.me/{bot_username}?start={token}`.

**Expiry check**: If `inv.expired_at < datetime.now(UTC)`, returns `AccessResult(success=False, message="Inventory item has expired")`.

**Lifetime detection**: `expired_at.year >= 9999` → no `expire_date` set on Telegram invite link.

---

## get_inventory_list

```python
# Sync — reads from in-memory cache (synced via change stream):
items: list[InventoryModel] = await InventoryService.get_inventory_list(wallet_id=auth.wallet_id)

return JSONResponse(content={
    "items": [item.model_dump(mode="json") for item in items]
})
```

---

## get_sales_count

```python
sales: dict[str, int] = await InventoryService.get_sales_count()
# {"product_id": count, ...}
```

Used by the `/inventory/sales` endpoint to show seller analytics.

---

## Schemas (`backend/schemas/inventory.py`)

```python
from backend.schemas.inventory import (
    InventoryAddRequest,      # wallet_id, tx_id, item: dict, expired_at
    InventoryUpdateRequest,   # wallet_id, item_id, item?: dict, expired_at?: datetime
    InventoryRemoveRequest,   # item_id (inv.id, not product.id)
    InventoryAccessRequest,   # wallet_id, item_id
    InventoryListRequest,     # wallet_id
    InventoryDetailRequest,   # wallet_id, item_id
)
```

Important: `InventoryRemoveRequest.item_id` uses `pattern=constants.PRODUCT_ID_PATTERN` and has a description clarifying it is `inv.id`, not `product.id`. Always document this distinction in endpoint docstrings.

---

## Endpoint Pattern (v2)

```python
# GET /inventory — list buyer's purchased items
@router.get("")
async def list_inventory(
    auth: AuthRequest = Depends(require_auth_cookies_login),
) -> JSONResponse:
    items = await InventoryService.get_inventory_list(auth.wallet_id)
    return JSONResponse(content={"items": [i.model_dump(mode="json") for i in items]})

# POST /inventory/access — generate + send access link
@router.post("/access")
async def get_access_link(
    payload: InventoryAccessRequest,
    auth: AuthRequest = Depends(require_auth_cookies_login),
) -> JSONResponse:
    result = await InventoryService.generate_and_send_access_link(
        wallet_id=auth.wallet_id,
        item_id=payload.item_id,
    )
    if not result.success:
        raise HTTPException(status_code=400, detail=result.message)
    return JSONResponse(content=result.model_dump())

# GET /inventory/sales — seller analytics (dev or owner-scoped)
@router.get("/sales")
async def get_sales_count(
    auth: AuthRequest = Depends(require_auth_cookies_login),
) -> JSONResponse:
    sales = await InventoryService.get_sales_count()
    return JSONResponse(content={"sales": sales})
```

---

## Route Order Rule

In v2 `inventory` router, fixed paths (`/sales`, `/add`, `/update`, `/remove`, `/access`) must be registered **before** the path-param route (`/{item_id}/detail`) to avoid route conflicts:

```python
# backend/api/v2/endpoints/inventory.py
router.include_router(sales_router)   # /sales
router.include_router(add_router)     # /add
router.include_router(detail_router)  # /{item_id}/detail  ← must be last
```
