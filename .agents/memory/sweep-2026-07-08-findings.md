---
name: 2026-07-08 sweep findings
description: Running status of the 104-finding sweep; use before claiming any finding is open or fixed.
---

# 2026-07-08 Sweep Status

Authoritative source: `docs/superpowers/sweep-2026-07-08.md`.
Always read the sweep doc directly; this file is a **session-level quick-reference only**.

## Session 3 fixes (2026-07-08)

| Finding | Fix |
|---------|-----|
| N-1 | `_apply_remote_change` freshness guard now prefers `updated_at` over `created_at` |
| N-12 | v1 `product_verify` IDOR: uses `auth.wallet_id` (session) not `payload.wallet_id` |
| N-22 | `_load_force_sub_invite_links` now caps concurrent `get_chat` via `Semaphore(5)` |
| N-26 | `_operation_context` except blocks active; state transitions AFTER `cleanup_process()` in finally |
| N-48 | `resolve_target` returns `(None, False, "")` on failure (not raw target string) |
| N-50 | User settings restore validated via `UserConfig.model_validate({"id": user_id, **config_data})` |
| N-56 | RSS backup restore validates each entry via `RssModel.model_validate(...)` before `upsert_feed` |
| N-65 | `_is_blocked_address` / `validate_url_for_ssrf` are async; DNS via `await to_thread(socket.getaddrinfo, ...)` |
| N-84 | `update.py` git failure path renames `.git → .git.bak` (not `rm -rf`) |
| N-88 | `hard_reset()` called via `await asyncio.to_thread(...)` in `async def main()` |

## Session 4 fixes (2026-07-08)

| Finding | Fix |
|---------|-----|
| N-5 | `IndexedCollection.__init__` raises `ValueError` when `max_size > 0` (LRU mode), preventing stale index entries |
| N-27 | aria2 poll loops use exponential backoff: `_delay = min(_delay * 1.5, 5.0)` at lines 554–605 |
| N-66 | `add_pagination_buttons` uses sliding window + First/Last jump buttons; output bounded regardless of dataset size |
| N-86 | xproxy webhook forward uses `req._rawBody` when available; `JSON.stringify` fallback only when raw body absent |
| N-94 | `pyproject.toml` already pins `pymongo~=4.10.0` (inline `# N-94` comment) |

## Session 4 invalidated

| Finding | Reason |
|---------|--------|
| N-37 | Both providers return `{}` (falsy) for unpaid and non-empty dict (truthy) for paid; truthiness check is correct by design |

## Session 3 invalidated

| Finding | Reason |
|---------|--------|
| N-21 | asyncio single-threaded: no `await` between check and set in `_patch_methods`; no real race |
| N-87 | `deploy-heroku.yml` already uses single combined `heroku config:set` per app |
| N-59 | Pre-check is an optimization; CAS in `mark_rewarded` already handles the race safely |

## Key pitfalls learned

- **N-26**: `update_state_info` calls `state.sub.reset()` internally, replacing `self.state`. Must set status AFTER cleanup, not in except block before finally. Pattern: set `_fail_status` variable in except, call `update_state_info` at end of finally.
- **N-50**: `USER_CONFIG_EXCLUDE_KEYS` includes `"id"`, so model_validate needs `id=user_id` injected.
- **N-65**: `asyncio.to_thread` is already imported in `security.py` as `from asyncio import to_thread`.

## Session 5 fixes (2026-07-09)

| Finding | Fix |
|---------|-----|
| N-14 | Already fixed in code (`backend/services/wallet.py:204–218`); sweep doc updated to ✅ |
| N-76 | Already fixed in code (`session-context.jsx` `isRefreshingRef` guard); sweep doc updated to ✅ |
| N-78 | Already fixed in code (`use-api.js` 1800-char SSE guard); sweep doc updated to ✅ |
| N-92 | Already fixed in code (`pyproject.toml` `pytest-xdist[psutil]`); sweep doc updated to ✅ |
| N-60 | `reward.py`: 2-attempt retry (1 s delay) for `generate_and_send_access_link` |
| N-51 | `users.py menu`: skip path getters for non-path/main-menu branches; callback: 6 sequential awaits → `gather()` |
| N-75 | `product-details.jsx` + `use-buy-product.js` + `home.jsx`: stable packet index via `selectedPacketIndex` state; `indexOf` only as last-resort fallback |
| N-18 | `bot/config/base.py`: removed dead double-check code; replaced with clean fast-path + locked slow-path (create-only); `threading.Lock` retained for thread safety from executor paths |

## Session 6 fixes (2026-07-09)

| Finding | Fix |
|---------|-----|
| N-3 | `WalletModel` had two near-duplicate `mode='before'` validators on `balance` (`_round_balance` + `validate_balance`); collapsed into one `validate_balance` that also unwraps `bson.Decimal128` via `to_decimal()` before quantizing |

## Still open (as of session 6)

High: N-2, N-41, N-46, N-64, N-82
Medium: N-10, N-28, N-29, N-30, N-38, N-47, N-52, N-61, N-77, N-79, N-93, N-95
Low: LH-3

Always-skip: SEC-1, X3, S-19, S-33, S-35, S-40, N-4, N-6, N-23, N-53, N-85
