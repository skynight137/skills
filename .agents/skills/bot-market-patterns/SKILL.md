---
name: bot-market-patterns
<<<<<<< HEAD
description: Use this skill when working on the market module (bot/modules/market/). Covers product categories, callback schema, purchase flow, payment providers, and bundle products.
=======
description: >-
  Use this skill when working on the market module (bot/modules/market/). Covers
  product categories, callback schema, purchase flow, payment providers, and
  bundle products.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot — Market Patterns

Reference for the market system in `bot/modules/market/` (directory).

---

## File Structure

```
bot/modules/market/constants.py   # MarketSessionManager, all constants (category maps, templates)
bot/modules/market/helpers.py     # Pure utility functions (build_product_preview, parse_packet_lines, etc.)
bot/modules/market/payment.py     # Payment flows (handle_manual_validation, saweria/trakteer, test_buy, verify)
bot/modules/market/seller.py      # Seller CRUD (add/edit/remove product, backup/restore)
bot/modules/market/menu.py        # market_menu + market_callback (main entry points)
bot/modules/market/__init__.py    # Re-exports market_menu, market_callback
bot/plugins/basic.py              # Plugin: filters.command(BotCommands.market)
bot/config/wallet.py              # WalletConfig — holds products/inventory in memory
database/models/product.py        # Polymorphic product models (ProductItem discriminator)
backend/services/handle.py        # ProductHandleService, PurchaseResult
backend/services/product.py       # ProductService — CRUD
web/provider/saweria.py           # Saweria payment provider
web/provider/trakteer.py          # Trakteer payment provider
```

---

## Callback Schema (`mrkt`)

```
mrkt {identity} category                  # open category selector
mrkt {identity} edit {product_id}         # edit product flow
mrkt {identity} remove {product_id}       # delete product
mrkt {identity} testbuy {product_id}      # test purchase (owner/dev only)
mrkt {identity} validate {product_id}     # manual payment validation
mrkt {identity} verify {product_id}       # pre-verify deliverability
mrkt {identity} share {product_id}        # generate deep-link
<<<<<<< HEAD
=======
mrkt {identity} stats {product_id}        # vip_chat only — query.answer popup with media counts
>>>>>>> 2ecb89d (update)
mrkt {identity} trakteer_{method} {product_id}
mrkt {identity} saweria_{method} {product_id}
mrkt {identity} main_market               # switch to main bot's catalog
mrkt {identity} back {prev_key}           # navigate back
mrkt {identity} close                     # close, clear user state
mrkt {identity} ps {offset}              # pagination
mrkt {identity} filter {cat|all}          # filter by category
mrkt {identity} backup                    # export all products as JSON (is_dev only)
mrkt {identity} restore                   # import products from JSON file (is_dev only)
```

---

## Product Categories

| Category | Model | Available On |
|----------|-------|-------------|
| `general` | `ProductGeneralModel` | All bots |
| `vip_chat` | `ProductVIPChatModel` | All bots |
| `paid_message` | `ProductPaidMessageModel` | All bots |
| `topup` | `ProductTopupModel` | Main bot only |
| `user_bundle` | `ProductUserBundleModel` | Main bot only |
| `bot_bundle` | `ProductBotBundleModel` | Main bot only |

Category filter icons: `🔍 all`, `🌟 vip_chat`, `📨 paid_message`, `📦 general`, `💳 topup`, `👤 user_bundle`, `🤖 bot_bundle`

---

## Unified Purchase Processor

All purchase flows funnel through one call:

```python
from backend.services import ProductHandleService

result = await ProductHandleService.process_purchase(
    seller_id=bot_id,
    buyer_id=target_id,
    tx_id=transaction_id,
    product_id=product_id,
    packet_index=packet_index,
    amount=credits_amount,
    is_main_bot=client.is_main_bot(),
    test_mode=False,
)

if result.requires_notification:
    await client.send_message(chat_id=target_id, text=result.build_buyer_message())
```

`PurchaseResult` key properties: `event_type`, `category`, `product_name`, `access_link`, `error_message`, `requires_notification`.

---

## Product Verification

`vip_chat` and `paid_message` are **auto-verified before any purchase**:
```python
# Inside _handle_payment_flow and handle_test_buy
if category in (VIP_CHAT, PAID_MESSAGE):
    verify_result = await ProductHandleService.verify_product(bot_id, product_id, auto_remove=False)
    if not verify_result.ok:
        reason = verify_result.reason or "Product unavailable"
        await query.answer(f"❌ Product not deliverable: {reason}", show_alert=True)
        return
```

<<<<<<< HEAD
=======
## VIP Chat Stats

`mrkt {identity} stats {product_id}` — available only on `vip_chat` product detail pages.

**Button**: `ButtonText.VIP_CHAT_STATS` (`"📊 Chat Stats"`) — `position="header"`, `ButtonStyle.PRIMARY`.
Added in `menu.py` product detail block, exclusively for `ProductCategory.VIP_CHAT`.

**Callback handler** (`d4 == "stats" and d5`):
1. Fetch product via `ProductService.get_product_detail(d5, as_model=True)` — guard: category must be `vip_chat`
2. Resolve UserBot: `user_client = client.bot_manager.get_client(client.owner_id)` — NOT the bot client
   - If `None` or not connected → `query.message.reply(error_html)` and return
3. Call `fetch_vip_chat_stats(user_client, chat_id)` wrapped in `try/except`
   - On exception → `query.message.reply(error_html)` with `type(e).__name__: e` in `<blockquote>`
4. On success → `query.answer(stats_text, show_alert=True)` popup (no message edit)

**`fetch_vip_chat_stats(client, chat_id)` in `helpers.py`**:
- `search_messages_count` is **UserBot-only** — must pass owner's user client, NOT a bot client
- Uses `asyncio.gather` to call `client.search_messages_count(chat_id, filter=...)` concurrently for four `MessagesFilter` values: `PHOTO`, `VIDEO`, `DOCUMENT`, `AUDIO`
- Returns `dict` with keys `photo`, `video`, `document`, `audio`, `total` (all `int`)
- **Raises on any failure** — caller must wrap in `try/except` and handle errors

**Stats popup format** (fits within Telegram's 200-char `answerCallbackQuery` limit):
```
📷 Photos: 123
🎬 Videos: 456
📄 Documents: 789
🎵 Audio: 12
📊 Total: 1380
```

---

>>>>>>> 2ecb89d (update)
**`vip_chat` auto-remove rule (enforced inside `verify_product`):**
`vip_chat` products are **never** auto-removed regardless of the `auto_remove` argument passed by the caller. This is intentional: sellers can update the product's `chat_id` (e.g. after the original chat is restricted/TOS-removed) and existing buyers can re-claim a fresh invite link from their inventory. The `auto_remove` override happens at the service level inside `verify_product` itself — callers do not need to remember this.

---

## Packet Format

Input (one per line):
```
100 0        # 100 credits, Lifetime
200 30d      # 200 credits, 30 days
500 1y       # 500 credits, 1 year
```

Constraints: `price >= 1.0`, expire is `0` (Lifetime) or `86400s`–`31536000s` (1 day – 1 year).

---

## Price Convention

| Context | Format |
|---------|--------|
| Storage | Credits (`1` = Rp 1,000) |
| Display | IDR (`Rp 1,000`) |
| Saweria API | IDR (`price * 1000`) |
| Trakteer API | Quantity (`price`) |

---

## Security Guards

- All callbacks: `user_id == int(d1)` — rejects with `NOT_YOURS`
- `add`, `edit`, `remove`: requires `is_owner or is_dev`
- `testbuy`: only `owner_id` and `dev_id`
- `backup`, `restore`: `is_dev` only — button hidden for non-dev users, callback also guarded
- Replay attacks: `check_replay_attack()` on all webhook transactions
- `preview_url`: only accepts `https://t.me/...` links
- `product.owner_id == wallet_id` enforced in `ProductService.update_product`
<<<<<<< HEAD
=======
- Wallet callbacks: `from_wallet_id`/`to_wallet_id` (`d2`/`d3`) ownership is verified against `user_id`
  before any transfer/clear action runs (bot owner/dev exempted) — prevents crafting callback
  data with another user's wallet id
>>>>>>> 2ecb89d (update)

---

## Market Backup & Restore (Dev Only)

Buttons appear in the main market menu only when `user_id == client.dev_id`.

**Backup** — `backup_market_products(client, query, wallet)`:
- Serializes all `wallet.products` to JSON, excludes `owner_id`
- Sends `market_products_{wallet_id}.json` as a document reply

**Restore** — `restore_market_products(client, query, wallet, from_wallet_id, to_wallet_id)`:
- Prompts for a `.json` file via `wait_for_message(doc=True, text=False)`
- Iterates product list, calls `ProductService.add_product()` per entry
- Skips duplicate product IDs (`ValueError`), reports added/skipped/failed counts
- Uses `rfunc` to return to main market menu on cancel

Backup JSON shape:
```json
{
  "products": [
    { "id": "abc123", "product_name": "...", "category": "general", "packets": [...], ... }
  ]
}
```

---

## Bundle Products

**User bundle** (`ProductUserBundleModel`) — overrides task/resource limits:
`max_task_limit`, `max_playlist_limit`, `max_client_slots`, `max_queue_timeout`, `max_active_timeout`, `max_pause_timeout`, `max_size_dl/pr/up/cl_limit`

**Bot bundle** (`ProductBotBundleModel`) — overrides bot-level settings:
`max_sudos`, `max_auths`, `max_rss_chats`, `max_blacklists`, `max_range_msgstore`, `max_force_sub_chats`, `msg_store_unlocked`

Applied at runtime: `UserConfig._apply_active_bundle(user_id, bundle_payload)` / `BotConfig._apply_active_bundle(bot_id, bundle_payload)`
