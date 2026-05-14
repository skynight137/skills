---
name: bot-wallet-patterns
description: Use this skill when working on wallet or market features that use WalletConfig. Covers WalletConfig API, balance operations, inventory management, product access checks, and wallet access control.
---

# Bot — Wallet Patterns

Reference for `WalletConfig` (`bot/config/wallet.py`) and the wallets module.

---

## File Structure

```
bot/modules/wallets.py       # Wallet UI and handlers
bot/plugins/basic.py         # Plugin: filters.command(BotCommands.wallet)
bot/config/wallet.py         # WalletConfig — in-memory wallet data
database/models/inventory.py # InventoryModel for purchased items
```

---

## WalletConfig Properties

| Property | Type | Description |
|----------|------|-------------|
| `id` | `int` | Wallet ID (user_id or bot_id) |
| `balance` | `float` | Current balance |
| `products` | `list[ProductItem]` | Products owned/sold |
| `inventory` | `list[InventoryModel]` | Purchased items |

---

## Balance Operations

```python
await wallet.add_credits(amount, tx)
await wallet.deduct_credits(amount, tx)
await wallet.lock_balance(task_id, amount)
await wallet.unlock_balance(task_id)
```

---

## Product Management

```python
await wallet.add_product(product_data)
await wallet.update_product(product_id, updates)
await wallet.delete_product(product_id)
product = wallet.get_product(product_id)
```

---

## Inventory Management

```python
await wallet.add_inventory_item(product, tx, expire_seconds)
active = wallet.get_active_purchased()
bundle = wallet.get_active_bundle_item("user_bundle")  # or "bot_bundle"
```

---

## Access Checks

```python
wallet.is_product_purchased(product_id)
wallet.has_vip_chat_access(user_id, chat_id)
wallet.has_paid_message_access(user_id, source_chat_id, msg_range)
```

---

## Target Wallet Resolution

```
/wallet              # Bot's wallet (default)
/wallet me           # User's personal wallet
/wallet <bot_id>     # Specific bot's wallet (if owner/dev)
```

Access control:

| Role | Access |
|------|--------|
| User | Own wallet only |
| Bot Owner | Bot's wallet they own |
| Developer | Any wallet |

---

## Wallet Callback Prefix

Callbacks use `wallets` prefix — see `bot-buttons-patterns` for callback data format.
