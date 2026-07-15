---
name: aiogoogle migration
description: Completed full migration from google-api-python-client + google-auth to aiogoogle==5.17.0. No google-auth/googleapiclient imports remain in project code.
---

## Rule
Use `aiogoogle==5.17.0` for all Google API work. Use `utils.google_creds.GDriveCredentials` for credential pickling. **Zero google-auth/googleapiclient direct imports in project code.**

**Why:** google-api-python-client is sync-only (39+ `asyncio.to_thread` calls). google-auth's `Request.refresh()` is a blocking HTTP call inside async code. Both eliminated. aiogoogle is native async. GDriveCredentials is a plain dataclass — no google-auth dep at runtime.

## Status — FULLY COMPLETE (2026-06-26)
- `bot/modules/tools/sa_generator.py` — DONE. All to_thread calls removed. Blocking `creds.refresh(Request())` replaced with `await refresh_gdrive_creds(creds)`.
- `bot/service/gdrive.py` — DONE. All 30+ to_thread/build() calls removed. Proactive token refresh on expiry added to `_authorize_with_token`. Blanket `sleep(1)` between pagination pages removed (tenacity handles 429s).
- `bot/modules/tools/sa_stats.py` — DONE. `get_drive_quota` uses `ServiceAccountCreds` + `drive.about.get` natively via aiogoogle.
- `backend/api/public/endpoints/oauth.py` — DONE. `google.oauth2.credentials.Credentials` replaced with `utils.google_creds.GDriveCredentials`. `expires_in` now parsed and stored in `GDriveCredentials.expiry`.

## Packages removed
- `google-api-python-client` — eliminated
- `google-auth-httplib2`, `google-auth-oauthlib`, `google-api-core`, `httplib2` — all gone
- `feedparser` — removed (zero imports; Category A unused dep)
- `google-auth` — no direct project imports; remains only as transitive dep pulled by aiogoogle itself

## Credential handling (utils/google_creds.py)
- `GDriveCredentials` — plain dataclass, pickle-safe, has `.expired` property
- `load_gdrive_creds(bytes) → GDriveCredentials` — loads both new and legacy `google.oauth2.credentials.Credentials` pickles via `_CompatUnpickler` (no google-auth needed)
- `refresh_gdrive_creds(creds)` — async httpx POST to token endpoint, mutates creds in-place; also writes refreshed pickle back to disk when called from `_authorize_with_token`
- `pyproject.toml` isort: `utils` in `known-first-party`; stale entries (anytree, apscheduler, colorlog, jsonwebtoken, feedparser) removed from `known-third-party`; `bcrypt` added

## Key patterns

**Auth setup (per operation):**
```python
# User token auth — with proactive refresh
credentials = load_gdrive_creds(token_bytes)
if credentials.expired and credentials.refresh_token:
    await refresh_gdrive_creds(credentials)
    await token_path.write_bytes(pickle_dumps(credentials))
user_creds = UserCreds(access_token=credentials.token, ...)
self._google = Aiogoogle(user_creds=user_creds, client_creds=client_creds)
await self._google.__aenter__()
self._drive = await self._google.discover("drive", "v3")

# SA auth
sa_creds = ServiceAccountCreds(scopes=OAUTH_SCOPE, **sa_json_dict)
self._google = Aiogoogle(service_account_creds=sa_creds)
await self._google.__aenter__()
self._drive = await self._google.discover("drive", "v3")
```

**Session lifecycle:** `__aenter__` in `_authorize_with_token` / `_switch_service_account`; `__aexit__` in `_close_session()`. `cleanup(close_session=True)` for top-level methods; `cleanup()` (close_session=False) mid-operation (rate limit retry).

**API dispatch helper:** `_api_call(request)` dispatches `as_user()` or `as_service_account()` based on `self.use_sa`.

**Error type:** `aiogoogle.excs.HTTPError` (aliased to `AioHTTPError`). Parse via `err.res.status_code` and `err.res.json`.

**Upload with progress:** `pipe_from=_TrackingReader(fh, proxy, lambda: self._cancelled)`.

**Download with progress:** `pipe_to=_TrackingWriter(fh, proxy, lambda: self._cancelled)`.

**Progress proxy:** `_ProgressProxy` has `.progress()` and `.total_size` — compatible with existing `GoogleDriveHelper.progress()` method.

**Cancellation in I/O:** `_TrackingReader.read()` and `_TrackingWriter.write()` check the `is_cancelled` lambda and raise `GDriveError(CANCELLED)`.

**`_execute_paginated_list`:** fully async; no blanket inter-page sleep (removed). Tenacity handles actual 429/403 rate limit responses with exponential backoff.

**Missing method fix:** `_get_files_by_drive_id_src_sync` was undefined in original. Replaced with `_get_files_by_folder_id` (same semantics).

**Drive API endpoint names in aiogoogle:**
- Download: `drive.files.get(fileId=..., alt="media", pipe_to=fh)` (NOT `get_media`)
- Export: `drive.files.export(fileId=..., mimeType=..., pipe_to=fh)` (NOT `export_media`)
- Upload: `drive.files.create(json=metadata, pipe_from=reader, supportsAllDrives=True)`
- Permissions: `drive.permissions.create(fileId=..., json=perms, supportsAllDrives=True)` — `permissions` is a top-level resource, NOT `drive.files.permissions` (v2 sub-resource). Body: `{"role": "reader", "type": "anyone"}` only — `value`/`withLink` are v2-only fields.

**`ServiceAccountCreds`:** accepts `**sa_json_dict` which maps directly from parsed SA JSON file.

## pipe_to / pipe_from contract (critical)

aiogoogle's aiohttp session calls `await pipe_to.write(chunk)` for downloads (aiohttp_session.py:77).
The `write()` method on any `pipe_to` object **must be `async def`** or `await int` crashes with
`TypeError: 'int' object can't be awaited`.

For uploads (`pipe_from`), aiogoogle calls `yield self.pipe_from.read()` (models.py:105) — no await —
so `read()` must remain **sync**.

| Method | Used for | Must be |
|--------|----------|---------|
| `pipe_to.write(chunk)` | download | `async def` |
| `pipe_from.read(n)` | upload | `def` (sync) |

## How to apply
- New Google API code: always use `Aiogoogle` + `discover()` + `_api_call()` helper pattern.
- `aiohttp` is already in requirements.txt (aiogoogle's HTTP backend — no re-install needed).
- `tenacity` stays (aiogoogle has no retry layer). `retry_if_exception_type(AioHTTPError)`.
- Any custom `pipe_to` wrapper passed to aiogoogle: `write()` must be `async def`.
- Token expiry: always check `creds.expired` before building `UserCreds`; refresh + write back to disk.
- oauth.py token exchange: always parse `expires_in` from response and store in `GDriveCredentials.expiry`.
