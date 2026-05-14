---
name: backend-handle-service-patterns
description: Use this skill when working on ProductHandleService — the unified purchase processor and product verifier. Covers process_purchase routing by category, VerificationResult, PurchaseResult, _handle_tax_and_inventory, test_mode handling, auto-removal on verify failure, and handler methods for each product category.
---

# Backend Handle Service Patterns

---

## ProductHandleService Overview

Location: `backend/services/handle.py`

Single source of truth for **all purchase flows** and **product verification**. Used by: payment webhooks, product simulation, test buy, manual validation.

| Method | Description |
|--------|-------------|
| `process_purchase(seller_id, buyer_id, ...)` | Unified purchase router; routes to handler by category |
| `verify_product(bot_id, product_id, ...)` | Centralized verification (vip_chat / paid_message) |
| `verify_vip_chat(bot_id, chat_id, ...)` | Check bot can access chat and create invite links |
| `verify_paid_message(bot_id, source_chat_id, msg_range, ...)` | Check bot can access sampled messages |
| `remove_product_on_verify_failure(product_id, reason)` | Auto-remove product from DB on failed verify |
| `handle_topup(...)` | Topup handler — credits only, no inventory |
| `handle_general_purchase(...)` | General product sale |
| `handle_bundle_purchase(...)` | bot_bundle / user_bundle sale |
| `handle_vip_chat_purchase(...)` | VIP chat invite link creation |
| `handle_paid_message_purchase(...)` | Paid message encrypted token creation |

---

## process_purchase — Unified Purchase Processor

```python
from backend.services.handle import ProductHandleService, PurchaseResult

result: PurchaseResult = await ProductHandleService.process_purchase(
    seller_id=bot_id,          # owner/seller (bot's wallet_id)
    buyer_id=target_id,        # buyer's Telegram/wallet ID
    tx_id=transaction_id,      # unique transaction ID
    product_id=product_id,
    packet_index=packet_index, # 0-based index into product.packets
    amount=net_amount,         # raw amount in base units (×1000 vs packet.price)
    is_main_bot=False,         # True for topup/bundle — must be main bot
    test_mode=False,           # True = short expiry, skip real transactions
)
```

**Routing by category:**

| Category | Handler | Notes |
|----------|---------|-------|
| `topup` | `handle_topup` | Requires `is_main_bot=True`; skips inventory; no tax |
| `bot_bundle` | `handle_bundle_purchase` | Requires `is_main_bot=True` |
| `user_bundle` | `handle_bundle_purchase` | Requires `is_main_bot=True` |
| `vip_chat` | `handle_vip_chat_purchase` | Creates invite link via bot client |
| `paid_message` | `handle_paid_message_purchase` | Encrypts access token |
| `general` | `handle_general_purchase` | No delivery link |

**Amount guard** (before routing):
```
price = packet.price * 1000   # packets store price in thousands (e.g. price=50 → 50,000 units)
if amount < price:
    raise ValueError("Insufficient amount")
```

For non-topup categories, `amount` is normalized to `packet.price * 1000` after the guard (overpayment is accepted but charged at packet price).

---

## PurchaseResult

```python
@dataclass
class PurchaseResult:
    event_type: str        # ProductDisplay constant (e.g. "VIP Chat", "Top Up")
    wallet_status: str     # Human-readable description for notification
    category: str          # ProductCategory value
    product_name: str
    access_link: str | None = None    # invite_link or msg_store_link
    error_message: str | None = None  # if link generation failed

    def build_buyer_message(self, is_test: bool = False) -> str:
        """Build Telegram HTML message to send to buyer."""
        ...

    @property
    def requires_notification(self) -> bool:
        """True for vip_chat and paid_message — must send message to buyer."""
        ...
```

Usage after `process_purchase`:
```python
if result.requires_notification:
    msg = result.build_buyer_message(is_test=web_config.test_mode)
    await client.send_message(buyer_id, msg)
```

---

## _handle_tax_and_inventory

Called internally by `process_purchase` for all non-topup categories. **Never call directly from endpoints.**

```
1. Add IN transaction to seller wallet (records sale)
2. If tax_rate > 0: deduct_credits from seller (platform fee)
3. Add item to inventory for buyer with expiry
```

In `test_mode`:
- Skips real wallet transactions
- Sets `expire_after_seconds = 300` (5 min) regardless of packet value

---

## VerificationResult

```python
@dataclass
class VerificationResult:
    ok: bool
    reason: str = ""               # human-readable failure message
    chat_id: int | None = None
    chat_title: str = "Unknown"
    source_chat_id: int | None = None
    msg_range: str = ""
    sampled_ids: list[int] = field(default_factory=list)
    accessible_count: int = 0
    issues: list[str] = field(default_factory=list)

    def to_tuple(self) -> tuple[bool, str]:
        return (self.ok, self.reason)

    @property
    def has_warnings(self) -> bool:
        """True if ok=True but some sampled messages were inaccessible."""
        return len(self.issues) > 0 and self.ok
```

---

## verify_product — Centralized Verifier

```python
result: VerificationResult = await ProductHandleService.verify_product(
    bot_id=auth.wallet_id,    # must be product.owner_id
    product_id=product_id,
    auto_remove=False,         # always pass False; vip_chat enforces False internally
)

if not result.ok:
    raise HTTPException(status_code=400, detail=result.reason)
if result.has_warnings:
    LOGGER.warning(f"Verification warnings: {result.issues}")
```

**Category routing:**
- `vip_chat` → `verify_vip_chat` (checks `chat_id`)
- `paid_message` → `verify_paid_message` (checks `source_chat_id` + `msg_range`)
- others → always `ok=True` (no verification needed)

**`vip_chat` auto-remove immunity (enforced inside `verify_product`):**
`vip_chat` products are **never** auto-removed regardless of the `auto_remove` argument.
The service overrides `auto_remove = False` before delegation when `category == VIP_CHAT`.
Reason: sellers can update the product's `chat_id` (e.g. after TOS restriction) and buyers can re-claim a fresh invite link from inventory — removing the product would break this warranty flow.

---

## verify_vip_chat

```python
result = await ProductHandleService.verify_vip_chat(
    bot_id=bot_id,
    chat_id=product.chat_id,
    product_id=product_id,   # None if pre-add verification (no product in DB yet)
    auto_remove=True,
)
```

Steps:
1. Check bot client is available and connected
2. `client.get_chat(chat_id)` — confirm bot is a member
3. `create_chat_invite_link` + `revoke_chat_invite_link` — confirm admin rights

---

## verify_paid_message

```python
result = await ProductHandleService.verify_paid_message(
    bot_id=bot_id,
    source_chat_id=product.source_chat_id,
    msg_range="1000-1050",   # "start_id-end_id"
    product_id=product_id,
    auto_remove=True,
)
```

Message sampling strategy:
- ≤10 messages: check all
- >10 messages: check `[start_id, mid, end_id]` (3 samples)

`result.accessible_count` tells how many sampled messages were accessible. `has_warnings` is True if some but not all were accessible.

---

## remove_product_on_verify_failure

Called automatically when `auto_remove=True` and verification fails. Also available for explicit use:

```python
await ProductHandleService.remove_product_on_verify_failure(
    product_id=product_id,
    reason="Cannot access VIP chat: Forbidden",
)
```

Silently swallows any DB error (logs it) — never raises.

---

## Category-Specific Handler Returns

| Handler | Returns |
|---------|---------|
| `handle_topup` | `(event_type: str, wallet_status: str)` |
| `handle_general_purchase` | `(event_type: str, wallet_status: str)` |
| `handle_bundle_purchase` | `(event_type: str, wallet_status: str)` |
| `handle_vip_chat_purchase` | `(event_type, wallet_status, invite_link \| None, error_message \| None)` |
| `handle_paid_message_purchase` | `(event_type, wallet_status, msg_store_link \| None, error_message \| None)` |

All wrapped into `PurchaseResult` by `process_purchase`.

---

## ProductDisplay Constants (`backend/constants.py`)

```python
from backend import constants

constants.ProductDisplay.TOPUP        # "Top Up"
constants.ProductDisplay.VIP_CHAT     # "VIP Chat"
constants.ProductDisplay.PAID_MESSAGE # "Paid Message"
constants.ProductDisplay.GENERAL      # "General"
constants.ProductDisplay.BOT_BUNDLE   # "Bot Bundle"
constants.ProductDisplay.USER_BUNDLE  # "User Bundle"
constants.ProductDisplay.TAX_FEE_NAME
constants.ProductDisplay.TAX_RECORD_NAME
```

---

## paid_message Encryption

Encrypted token format: `_paid_{source_chat_id}_{start_id}_{end_id}_{buyer_id}`

```python
from bot.utils.crypto import Encryption

paid_data = f"_paid_{source_chat_id}_{start_id}_{end_id}_{buyer_id}"
token = Encryption.encrypt(seller_id, text=paid_data, max_len=64)

if token and len(token) <= 64:
    link = f"https://t.me/{client.me.username}?start={token}"
else:
    # Token too long — log and return error_message
```

Telegram deep-link parameter has a 64-char limit — always validate token length before sending.

---

## test_mode Behavior

When `test_mode=True` (passed to `process_purchase`):
- `_handle_tax_and_inventory` skips real wallet transactions
- Expiry set to 300 seconds instead of `packet.expire_after_seconds`
- VIP chat invite link name prefix changes from `"VIP-"` to `"TEST-"`

```python
from backend.core.config import web_config

result = await ProductHandleService.process_purchase(
    ...,
    test_mode=web_config.test_mode,
)
```
