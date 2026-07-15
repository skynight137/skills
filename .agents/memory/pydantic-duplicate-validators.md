---
name: Duplicate Pydantic before-validators on the same field
description: Pydantic v2 silently allows two @field_validator(..., mode="before") decorators on the same field — both run, no error, no warning.
---

# Duplicate Pydantic before-validators on the same field

## The rule
Pydantic v2 does not detect or warn when two separate `@field_validator("x", mode="before")`
methods are defined for the same field on the same model. Both run in declaration order;
neither shadows the other. This is easy to introduce across separate sweep/fix sessions
when a later fix re-solves a problem an earlier validator already addressed, since nothing
fails at import time or at runtime — the duplication only surfaces on manual code review.

**Why:** `database/models/wallet.py` accumulated `_round_balance` (added to fix balance
rounding drift) and `validate_balance` (added later, independently, for the same
non-negative + quantize behavior) — both `mode="before"` on `balance`. Both executed on
every construction/assignment with no error; the second one's output simply overwrote
the first's.

**How to apply:** Before adding a new `field_validator` for a field, grep the model for
existing validators on that field name first (`grep -n 'field_validator("balance"' file.py`).
If duplicates already exist, consolidate into one method rather than adding a third.
