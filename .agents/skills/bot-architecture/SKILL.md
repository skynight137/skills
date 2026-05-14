---
name: bot-architecture
description: Use this skill when designing, refactoring, or reviewing code structure in bot/, web/, or database/ modules. Covers layer responsibility, file size limits, existing abstractions (TaskPolicy, AsyncPath), and the bot-to-database integration strategy.
---

# Bot Architecture Patterns

Standards for code structure, layer boundaries, and existing abstractions in this project.

---

## 1. File Size & Modularization

- **Hard limit**: 500–700 lines or ~20KB per file.
- **Split strategy**: If a file bloats (e.g., `web/services/__init__.py`), split into focused files inside the same folder (`web/services/wallet.py`, `web/services/product.py`).
- **Centralized exports**: Use `__init__.py` to re-export so imports stay simple: `from web.services import WalletService`.
- **Standardized reading**: Always read files with a line limit — never read a 1000-line file in one block.

---

## 2. Layer Responsibility

**Standard path**: `web/client.py (WebClient) → web/routers → web/services → database`

| Layer | Responsibility |
|-------|---------------|
| **Routers** | Request/response validation only |
| **Services** (`web/services/`) | Business logic, orchestrate calls, never reach into `collection.collection` raw |
| **Collections** (`database/collections/`) | DB queries, query decisions, caching, Pydantic model validation |

**Rules:**
- DB-level decisions stay in Collection classes. If a method needs extra DB queries to determine outcome (e.g., not found vs. insufficient balance), that logic lives in the Collection — not in Service.
- `WalletsCollection.atomic_deduct_balance()` raises `ValueError("Wallet not found")` or `ValueError("Insufficient balance")` internally. Services call, Collections decide.
- Services must not access `collection.collection` (raw Motor handle) directly — create a Collection method instead.

---

## 3. Use Existing Abstractions — Not Parallel Utilities

Before adding new helpers, always check if an existing abstraction covers the need:

- **`TaskPolicy`** (`bot/task/policy.py`) — size limits, task limits, duplicate checking, wallet balance. Do NOT create standalone size-check or count-check helpers.
- **`AsyncPath`** (`aiopath`) — already imported in all processor and config files. Prefer `.exists()`, `.mkdir()`, `.stat()` over `os.*` equivalents. For deletion use `.remove(missing_ok=True)` for cleanup (files **or** directories — smart dispatch via `lstat`) and `.remove()` when the path must exist. Never use `shutil.rmtree` or `asyncio.to_thread(shutil.rmtree, ...)` directly.
- **Centralize in parent, not each caller**: If a validation applies to all subclasses (e.g., `TaskConfig`), add it to the base class method (`configure_task()`) — not duplicated in every concrete caller.

```python
# ❌ Anti-pattern
# importing validate_url_for_ssrf in both mirror_leech.py AND ytdlp.py

# ✅ Correct
# call validate_url_for_ssrf once inside TaskConfig.configure_task()
```

---

## 4. Developer Guidelines (Mandatory)

- **No hardcoding**: Values like `user_id`, `wallet_id` must be dynamically retrieved from context (Telegram WebApp/Session). If unavailable, return a clear error — never a default fallback on the front-end.
- **Strict model typing**: Products and models are Pydantic instances, not dicts. Access `product.field` directly — do not use `getattr(product, "field", fallback)`.
- **Field naming consistency**: Keep field names identical across DB, model, and API response layers.
- **No fallbacks on front-end**: All default/empty-value logic must be handled at the back-end layer.

---

## 5. Bot-to-Database Integration Strategy

**Direct Database Access (preferred for bot modules):**
- `BotConfig`, `UserConfig`, `WalletConfig` must use `BaseCollection` with `self.cache` — not the legacy `PayAPIClient` flow.
- Reason: real-time, validated (Pydantic), cached data without API overhead.

**Service-Level Integration (for complex business logic):**
- Complex flows (e.g., `bot/modules/market.py`) use `web/services/` which have proper fulfillment handles (`handle.py`).

**WebClient (legacy/fallback only):**
- `PayAPIClient` is slated for removal. For inter-process HTTP, use `WebClient` mapped to Web Routers.

---

## 6. Proactive Improvement

- **Post-task review**: After completing a task, review surrounding code for improvements.
- **Proactive refactoring**: Fix suboptimal or risky code even if slightly outside scope when it benefits project health.
- **Iterative planning**: At the end of each iteration, identify next steps and remaining technical debt.
