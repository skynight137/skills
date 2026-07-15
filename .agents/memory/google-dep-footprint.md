---
name: Google dependency footprint
description: Which Google packages are needed, which are transitive, and which are orphaned — when using aiogoogle as the sole client.
---

# Google dependency footprint

## Rule
`aiogoogle` is the sole Google API client. Its deps flow as:

```
aiogoogle → google-auth → pyasn1-modules → pyasn1
         → tonyg-rfc3339
```

All of the above arrive as **transitives** — do not add them as direct deps in `pyproject.toml`.

## uritemplate — keep pinned explicitly
`uritemplate` is a runtime dep of aiogoogle but **not declared in its package metadata**. Without an explicit pin it would be missing from the venv. Keep it in `pyproject.toml` under `# Google APIs` with the comment explaining why.

## Removed orphans (2026-06-29)
These had no Required-by in the installed env and zero import sites in code:
- `googleapis-common-protos` — Google Cloud client lib dep, not aiogoogle
- `proto-plus` — same
- `protobuf` — pulled only by the above two; goes with them

**Why:** They were probably declared when an older `google-api-python-client` or `google-cloud-*` library was in use. aiogoogle uses REST/JSON Discovery, not protobuf.

## google_creds.py — no google-auth import needed
`utils/google_creds.py` replaces `google.oauth2.credentials.Credentials` with `GDriveCredentials` (dataclass). Legacy pickles are loaded via `_CompatUnpickler` which remaps the google class without importing google-auth. Token refresh uses `httpx.AsyncClient` directly. This module is self-contained even if google-auth were removed.

**How to apply:** When adding new Google API calls, use `aiogoogle` + `aiogoogle.auth.creds`. Do not reach for `google-auth` directly — it is an implementation detail of aiogoogle, not a public dep of this project.
