---
name: WalletModel Decimal/float arithmetic
description: WalletModel.balance is decimal.Decimal; all arithmetic partners are float — mixing the two raises TypeError at runtime.
---

# WalletModel Decimal/float arithmetic

## The rule
`WalletModel.balance` is `decimal.Decimal` (for precision — Pydantic validator converts any input via `Decimal(str(v))`).
All arithmetic partners are plain `float`:
- `GlobalsModel.min_wallet_balance: float`
- `WalletConfig._locked_balances: dict[int, dict[str, float]]`

Python raises `TypeError: unsupported operand type(s) for -: 'decimal.Decimal' and 'float'` on any arithmetic between the two, but **comparison operators** (`<`, `>`, `>=`) work fine.

**Why:** WalletModel was designed for precision; GlobalConfig and the in-memory lock store were written to `float` without coordination. Fixing WalletModel to emit `float` would lose the quantize/round-half-up semantics.

**How to apply:** Any code that does arithmetic with `balance` against a `float` must first call `float(balance)` or `float(self.balance)`. The three canonical sites:
- `bot/task/policy.py` — `total_balance = float(user_wallet.balance)` at start of `check_user_wallet_balance()`
- `bot/config/wallet.py` `get_available_balance()` — `float(self.balance) - self.get_total_locked_balance()`
- `bot/config/wallet.py` `lock_balance()` — `float(self.balance) - sum(locked.values())`

`database/expiration.py` only does comparisons (`>=`) — no change needed there.
