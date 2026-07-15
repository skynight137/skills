---
name: Project conventions
description: Owner-confirmed decisions that should not be revisited without explicit instruction.
---

## API v1 / v2 split

v1 uses JWT (Bearer token), v2 uses HttpOnly cookies. This is intentional — not a code smell or duplication problem. The two versions share the same endpoint logic; only the auth guard differs. **Never propose deprecating or removing v1.** The split is a permanent design choice: some clients need stateless JWT; others need session cookies. Both stay indefinitely.

**Why:** JWT and session-cookie auth serve different client environments. The owner explicitly confirmed: keep both v1 and v2 permanently.

**How to apply:** When adding a new endpoint, mirror it in both v1 and v2 with the appropriate guard. Do not raise v1/v2 coexistence as a concern in audits. Do not add `Deprecation` headers to v1 responses.

## Python runtime

Python 3.14 is the confirmed, intentional runtime for this project. Do not suggest pinning to 3.12 or 3.13 for "stability", and do not flag 3.14 as pre-release in recommendations. The project is already using 3.14 features (e.g. `type X = ...` type alias syntax).

**Why:** Owner explicitly confirmed — keep Python 3.14.

**How to apply:** All new code may use Python 3.14 syntax freely. `pyproject.toml` `requires-python` stays at `>=3.14`.
