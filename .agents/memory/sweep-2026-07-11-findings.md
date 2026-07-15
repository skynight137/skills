---
name: 2026-07-11 sweep findings
description: 20-finding sweep (5 CRITICAL/HIGH money+security); tracks open/fixed status
---

## Status as of 2026-07-11 (session end)

### Fixed this session
- **PERF-B1** FIXED — `_probe_port` async helper + `asyncio.open_connection`; `to_thread(gethostname)`
- **CORR-B2** FIXED — same_dir_lock condition wired correctly with notify_all
- **CI-I1** FIXED — `start.sh --lint` now runs mypy + bandit after ruff; pyproject.toml `[[tool.mypy.overrides]]` double-bracket fix; nosec annotations on B501/B102/B604/B108/B104; `usedforsecurity=False` on MD5; B608 added to bandit skips
- **MAINT-B3** FIXED — seller.py (1121→29 re-export + 3 sub-modules); heroku_management.py (1093→686 + 3 sub-modules); rss/menu.py (1011→699 + rss_builders.py)

### Previously invalidated
- **SEC-W1** INVALIDATED — guard centralised in ProductHandleService.process_purchase
- **PERF-W3** INVALIDATED — already wrapped in asyncio.to_thread
- **CORR-B2** INVALIDATED → then FIXED
- **DI-D1** INVALIDATED — TTL index on expired_at already in place

### Still open (priority order)
1. **SEC-W2** HIGH — Saweria HMAC signature accepted but never validated (intentionally deferred per always-skip-recs.md)
2. **SCALE-W4** HIGH — no rate limiter on payment webhook endpoints
3. **DI-F1** HIGH — balance deducted atomically but audit log write is not; no rollback on failure
4. **DI-F2** MEDIUM — seller tax failure swallowed; inventory delivered, revenue leaked
5. **SEC-A1** MEDIUM — no rate limit on authenticated v1/v2 endpoints
6. **MAINT-A2** MEDIUM — regex-parsed webhook message_data; silent format mismatch
7. **CORR-B4** MEDIUM — broad except swallows FloodWait in market/payment.py
8. **PERF-D2** MEDIUM — BaseCollection global lock serializes all readers during load()
9. **CORR-D3** MEDIUM — IndexedCollection.load() rebuilds index under global lock; lock not held during individual upserts
10. **CORR-I2** LOW — Blogger/ directory referenced in .replit workflow but may be absent
