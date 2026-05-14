---
name: backend-product-service-patterns
description: Use this skill when working on ProductService, product endpoints, product categories, polymorphic product models, cursor-based product listing, or product CRUD operations. Covers add/update/remove/list, ProductListResult, owner-scoped cache vs global DB listing, and schema patterns.
---

# Backend Product Service Patterns

---

## ProductService Overview

Location: `backend/services/product.py`

| Method | Description |
|--------|-------------|
| `add_product(wallet_id, ...)` | Insert new product; polymorphic by category; raises `ValueError` on duplicate |
| `update_product(wallet_id, product_id, ...)` | Update existing; ownership check; re-validates polymorphically |
| `remove_product(wallet_id, product_id, ...)` | Delete; ownership check (bypassed if `is_dev=True`) |
| `get_product_detail(product_id, as_model)` | Returns dict or `ProductItem`; empty dict if not found |
| `get_product_list(wallet_id, ...)` | Cursor-based pagination; cache or DB depending on `wallet_id` |
| `batch_remove_product(owner_id, product_ids)` | Bulk delete by owner |

---

## Product Categories (Polymorphic Models)

```python
from database.models.product import (
    ProductModel,            # category="general" (default)
    ProductVIPChatModel,     # category="vip_chat"
    ProductPaidMessageModel, # category="paid_message"
    ProductTopupModel,       # category="topup"
    ProductBotBundleModel,   # category="bot_bundle"
    ProductUserBundleModel,  # category="user_bundle"
    ProductCategory,         # Enum of all category strings
)
```

**Always select model by category** — never use `ProductModel` directly for specialized categories:

```python
def _select_model(category: str, data: dict):
    match category:
        case "vip_chat":      return ProductVIPChatModel.model_validate(data)
        case "paid_message":  return ProductPaidMessageModel.model_validate(data)
        case "topup":         return ProductTopupModel.model_validate(data)
        case "bot_bundle":    return ProductBotBundleModel.model_validate(data)
        case "user_bundle":   return ProductUserBundleModel.model_validate(data)
        case _:               return ProductModel.model_validate(data)
```

---

## add_product

```python
from backend.services.product import ProductService

await ProductService.add_product(
    wallet_id=auth.wallet_id,
    product_name="VIP Access",
    product_desc="Monthly VIP chat membership",
    packets=[{"price": 50.0, "expire_after_seconds": 2592000}],
    product_id=None,          # auto-generated token_hex(5) if None
    category="vip_chat",
    chat_id=-1001234567890,   # category-specific extra field via **kwargs
)
# Raises ValueError("Product already exists") on DuplicateKeyError
```

---

## update_product

```python
await ProductService.update_product(
    wallet_id=auth.wallet_id,
    product_id="abc12",
    product_name="Updated Name",     # only pass fields to change
    packets=[{"price": 75.0, "expire_after_seconds": 0}],
    chat_id=-1009876543210,
)
# Raises ValueError("Product {id} not found") if not found or not owner
```

---

## get_product_list — Dual Strategy

```python
from backend.services.product import ProductListResult

# Owner-scoped (uses in-memory cache — fast, multi-VPS safe via change-stream):
result: ProductListResult = await ProductService.get_product_list(
    wallet_id=auth.wallet_id,
    keywords="vip",       # searches product_name (substring) or exact product_id
    limit=50,
    last_doc_id=None,     # cursor: last doc_id (ObjectId str) from previous page
)

# Global/admin (queries MongoDB directly — always real-time accurate):
result = await ProductService.get_product_list(
    wallet_id=None,       # None = global listing
    keywords=None,
    limit=50,
)
```

```python
@dataclass
class ProductListResult:
    products: list[ProductItem]
    total: int
    limit: int
    last_doc_id: str | None  # None if last page
```

Response serialization:
```python
return JSONResponse(content={
    "products": [p.model_dump(mode="json") for p in result.products],
    "total": result.total,
    "limit": result.limit,
    "last_doc_id": result.last_doc_id,
})
```

**Rule:** Owner-scoped listing reads from `db_manager.products.get_by_owner(wallet_id)` (in-memory). Global listing calls `db_manager.products.query_global(flt, limit=limit)` (MongoDB).

---

## ProductListResult — Cursor Pagination

Pagination uses `doc_id` (MongoDB ObjectId), not `_id`:
- Pass `last_doc_id` from the previous response's `last_doc_id` field
- `last_doc_id=None` means first page
- Response `last_doc_id=None` means last page reached

---

## Schemas (`backend/schemas/product.py`)

```python
from backend.schemas.product import (
    ProductAddRequest,      # product_name, category, packets, chat_id, msg_range, etc.
    ProductUpdateRequest,   # same fields but all Optional; extra="allow"
    ProductListRequest,     # wallet_id?, keywords?, limit, last_doc_id
    ProductDetailRequest,   # product_id
    ProductVerifyRequest,   # wallet_id, product_id
    ProductShareRequest,    # owner_id
    ProductBase,            # base model for responses
    ProductDetail,          # extends ProductBase with category-specific fields
    ProductPacket,          # price + expire_after_seconds
)
```

Key schema patterns:
```python
class ProductPacket(BaseModel):
    price: float = Field(..., ge=1.0)
    expire_after_seconds: int = Field(default=86400, ge=0, le=31536000)
    # 0 = Lifetime; otherwise minimum 86400 (1 day) — validated by field_validator

class ProductAddRequest(BaseModel):
    model_config = {"extra": "allow"}   # allows category-specific fields (chat_id, msg_range, etc.)
    product_id: str | None = Field(None, pattern=constants.PRODUCT_ID_PATTERN)
    category: str = Field("general")
    packets: list[ProductPacket] = Field(default_factory=list)
    chat_id: int | None = None           # vip_chat
    msg_range: str | None = None         # paid_message, format: "start_id-end_id"
    source_chat_id: int | None = None    # paid_message
    one_time_delivery: bool = False      # general deliverable products
    max_task_limit: int | None = None    # bot_bundle
    max_sudos: int | None = None         # bot_bundle
    max_auths: int | None = None         # bot_bundle
```

---

## Endpoint Pattern (v2)

```python
@router.post("/add")
async def add_product(
    payload: ProductAddRequest,
    auth: AuthRequest = Depends(require_auth_cookies_login),
) -> JSONResponse:
    try:
        result, model = await ProductService.add_product(
            wallet_id=auth.wallet_id,
            **payload.model_dump(exclude_none=True),
        )
    except ValueError as e:
        raise HTTPException(status_code=409, detail=str(e))
    return JSONResponse(content={"message": "Product added", "product_id": model.id})

@router.post("/remove")
async def remove_product(
    payload: ProductDetailRequest,
    auth: AuthRequest = Depends(require_auth_cookies_login),
) -> JSONResponse:
    is_dev = bool(web_config.dev_id and web_config.dev_id == auth.wallet_id)
    try:
        await ProductService.remove_product(auth.wallet_id, payload.product_id, is_dev=is_dev)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    return JSONResponse(content={"message": "Product removed"})
```

---

## batch_remove_product

```python
from backend.schemas.product import ProductBatchRemoveRequest  # list[product_ids]

await ProductService.batch_remove_product(
    owner_id=auth.wallet_id,
    product_ids=["abc12", "def34"],
)
```
