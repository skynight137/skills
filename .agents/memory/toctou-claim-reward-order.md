---
name: TOCTOU claim-first / reward-second pattern
description: All reward flows (instant_claim, rotator_blogs, referral) must insert the claim record BEFORE granting the reward to prevent double-credit races.
---

# TOCTOU: claim-first, reward-second

## The rule

For any "check then reward" flow, the idempotency record must be **inserted first**. Use the unique `_id` `DuplicateKeyError` as the race guard, not a pre-check read.

**Correct order:**
1. `await record_claim(...)` / `await mark_rewarded(...)` — atomic insert/update
2. On `DuplicateKeyError` → already claimed, return early (no reward)
3. `await grant_reward(...)` — only reached by the winner
4. On `grant_reward` failure → delete the claim record so the user can retry

**Why:** Between a `has_claimed` read and the `grant_reward` write there is an await. Two concurrent requests both pass the check and both call `grant_reward` — wallet is credited twice. MongoDB `insert_one` with a unique `_id` and `DuplicateKeyError` is the atomic guard.

**How to apply:**
- `xmissions.py` `claim_<mission_id>`: `record_claim` first → `DuplicateKeyError` → return; then `grant_reward` → rollback on failure
- `start.py` `_handle_xm_deeplink` (rotator_blogs): same pattern — `record_claim` first
- `start.py` `_handle_xm_ref_deeplink` (referral): `mark_rewarded(referrer_id, mission_id)` returns `bool` (`modified_count == 1`); only grant if `True`
- `referral_records.mark_rewarded`: filter includes `{"rewarded": False}` — MongoDB only applies once; returns `modified_count == 1` as the winner signal
- `start.py` `_handle_paid_msgstore` OTD: `inventory.delete_one(inventory_id)` before delivery; `deleted_count == 0` → already delivered, skip
