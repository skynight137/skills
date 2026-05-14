---
name: backend-payment-patterns
description: Use this skill when working on backend payment webhooks, payment order creation, provider integrations (Trakteer, Saweria), purchase message parsing, or adding a new payment provider. Covers webhook security, replay attack prevention, PaymentService, and ProductHandleService fulfillment flow.
---

# Backend Payment Patterns

---

## Payment Providers

| Provider | Class | File |
|----------|-------|------|
| Trakteer | `Trakteer` | `backend/provider/trakteer.py` |
| Saweria | `Saweria` | `backend/provider/saweria.py` |

Both providers implement a common verification interface — they call the provider's own API to confirm the transaction is legitimate before processing.

```python
from backend.provider.trakteer import Trakteer
from backend.provider.saweria import Saweria
from backend.provider.base import PaymentType  # Enum: QRIS, etc.
```

Provider enum in `backend/constants.py`:

```python
class PaymentProvider(StrEnum):
    TRAKTEER = "trakteer"
    SAWERIA  = "saweria"

    @property
    def field_mapping(self) -> dict:
        """Maps provider-specific webhook field names to internal names."""
        ...
```

---

## Webhook Endpoints

Both webhooks live in `backend/api/public/endpoints/payment.py` and are registered in both v1 and v2 routers.

| Path | Provider | Auth Mechanism |
|------|----------|---------------|
| `POST /payment-webhook/trakteer` | Trakteer | `x-webhook-token` header matches `wallet.trakteer_webhook_token` |
| `POST /payment-webhook/saweria` | Saweria | `saweria-callback-signature` header (presence required by FastAPI; content verified via Saweria API) |

> Both paths use hyphens, not underscores: `/payment-webhook/trakteer`

### Trakteer Webhook Flow

```
1. Validate x-webhook-token against wallet.trakteer_webhook_token
2. check_replay_attack(transaction_id)   ← fail-closed
3. Trakteer.verify(transaction_id)        ← calls Trakteer API
4. Parse supporter_message → (target_id, product_id, packet_index)
5. PaymentService.process_purchase(...)
6. Send bot notification
```

### Saweria Webhook Flow

```
1. check_replay_attack(id)                ← fail-closed (no token header check — verified via API)
2. Saweria.verify(id)                      ← calls Saweria API
3. Parse message → (target_id, product_id, packet_index)
4. PaymentService.process_purchase(...)
5. Send bot notification
```

---

## Purchase Message Format

Encoded inside `supporter_message` (Trakteer) / `message` (Saweria):

```
<target_id> <product_id> [packet_index] [custom_message]
```

Examples:
```
123456789 prod_abc123
123456789 prod_abc123 0
123456789 prod_abc123 1 Thank you!
```

Parsed via `PURCHASE_MESSAGE_PATTERN` regex in `backend/constants.py`:

```python
from backend import constants
import re

match = re.match(constants.PURCHASE_MESSAGE_PATTERN, message)
if match:
    target_id    = int(match.group(1))
    product_id   = match.group(2)
    packet_index = int(match.group(3) or 0)
```

---

## Payment Order Creation

`POST /payment/order` — public endpoint, no auth required.

```python
from backend.services.payment import PaymentService

result = await PaymentService.create_order(
    owner_id=payload.owner_id,
    product_id=payload.product_id,
    packet_index=payload.packet_index,
    target_id=payload.target_id,
    provider=payload.provider,  # "trakteer" or "saweria"
)
# Returns QRIS URL, instructions, etc.
```

`PaymentOrderRequest` schema:

```python
class PaymentOrderRequest(BaseModel):
    owner_id: int      # Product owner Telegram ID
    product_id: str    # Product to purchase
    packet_index: int  # Which price packet (0-based)
    target_id: int     # Buyer Telegram ID
    provider: str      # "trakteer" or "saweria"
```

---

## Fulfillment: ProductHandleService

After payment is verified, `ProductHandleService` handles the actual delivery:

```python
from backend.services.handle import ProductHandleService, VerificationResult

# Process a purchase after webhook verification:
await ProductHandleService.process_purchase(
    target_id=target_id,
    product_id=product_id,
    packet_index=packet_index,
    amount=net_amount,
    tx_id=transaction_id,
    provider=PaymentProvider.TRAKTEER,
    bot_id=bot_id,
)

# Verify product ownership/access:
result: VerificationResult = await ProductHandleService.verify_product(
    wallet_id=wallet_id,
    product_id=product_id,
    auto_remove=True,   # Remove one-time-delivery items after access
)
if result.ok:
    ...
else:
    raise HTTPException(400, result.reason)
```

`process_purchase` flow:
1. Load product + owner wallet
2. Validate amount vs packet price
3. Credit buyer wallet (topup) or add to inventory
4. Debit payment platform fee
5. Credit seller wallet
6. Send Telegram notification via `bot_manager.get_client(bot_id)`

---

## Replay Attack Prevention

**Always** call `check_replay_attack` before processing any webhook:

```python
from backend.core.security import check_replay_attack

is_replay = await check_replay_attack(tx_id)
if is_replay:
    return JSONResponse(content={"message": "Duplicate transaction ignored"}, status_code=200)
    # Return 200 to prevent provider retries, but do not process
```

`check_replay_attack` stores `tx_id` in the `transactions` collection. **Fail-closed**: returns `True` (blocks) when MongoDB is unavailable — prevents replay attacks from slipping through during DB outages.

---

## Adding a New Payment Provider

### Step 1: Create provider client (`backend/provider/my_provider.py`)

```python
from backend.provider.base import PaymentType

class MyProvider:
    @staticmethod
    async def verify(transaction_id: str) -> bool:
        """Call provider API to confirm transaction is legitimate."""
        ...

    @staticmethod
    def get_payment_type(amount: float) -> PaymentType:
        return PaymentType.QRIS
```

### Step 2: Add to `PaymentProvider` enum (`backend/constants.py`)

```python
class PaymentProvider(StrEnum):
    TRAKTEER    = "trakteer"
    SAWERIA     = "saweria"
    MY_PROVIDER = "my_provider"   # add here

    @property
    def field_mapping(self) -> dict:
        match self:
            case PaymentProvider.MY_PROVIDER:
                return {"id": "transaction_id", "message": "message", "amount": "amount_raw"}
            ...
```

### Step 3: Add webhook schema (`backend/schemas/payment.py`)

```python
class MyProviderWebhookRequest(BaseModel):
    transaction_id: str
    message: str
    amount_raw: float
```

### Step 4: Add webhook endpoint (`backend/api/public/endpoints/payment.py`)

```python
@router.post("/payment-webhook/my-provider")
async def my_provider_webhook(
    bot_id: int,
    request: Request,
    payload: MyProviderWebhookRequest,
) -> JSONResponse:
    # 1. Validate provider-specific auth header
    # 2. check_replay_attack(payload.transaction_id)
    # 3. MyProvider.verify(payload.transaction_id)
    # 4. Parse payload.message → target_id, product_id, packet_index
    # 5. PaymentService.process_purchase(...)
    return JSONResponse(content={"message": "Payment processed"})
```

### Step 5: Register in both v1 and v2 routers

```python
api_router_v1.include_router(payment.router)
api_router_v2.include_router(payment.router)
```

---

## Webhook Security Summary

| Provider | Header | Validation Method |
|----------|--------|-------------------|
| Trakteer | `x-webhook-token` | Compare against `wallet.trakteer_webhook_token` |
| Saweria | `saweria-callback-signature` | Header presence required; content verified via Saweria API |

Both: `check_replay_attack(tx_id)` before any processing. Both: verify via provider's own API before crediting wallet.
