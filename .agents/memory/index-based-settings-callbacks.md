---
name: Index-based settings callbacks
description: Settings callback schema uses positional integer index, not field names or hashes — alias_generator was removed from all settings models.
---

# Index-based settings callbacks

## Rule
Settings module callbacks (both `bot_manage` and `userset`) use a **positional integer index** to identify which field is being edited — not a field name, hash, or alias. `alias_generator` was removed from all settings models to prevent alias drift causing callback mismatches.

**Why:** Earlier versions used field-name-based callbacks. When models added/removed/reordered fields, callbacks referencing old names silently broke. Positional index is stable within a version and fails loudly if the model changes incompatibly.

**How to apply:**
- When adding a new settings field, append it to the end of the model so existing positional indexes stay valid.
- Callback button text comes from `Field(title=...)` — the index is derived from `model_fields` ordering (Python 3.7+ guarantees insertion order).
- Never reintroduce `alias_generator` on settings models — it will desync the index ↔ field binding.
- When reordering model fields, bump the relevant callback schema version and update all in-flight button states.
