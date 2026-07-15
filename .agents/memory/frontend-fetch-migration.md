---
name: Frontend use-api.js axios→fetch migration
description: axios removed from use-api.js; replaced with native fetch; external interface preserved so call sites need no changes.
---

# Frontend: axios → native fetch in use-api.js

## What changed
`frontend/src/hooks/use-api.js` was rewritten (2026-06-28) to use the native `fetch` API instead of axios. The axios package is no longer a dependency.

## External interface is identical
Call sites do **not** need updating. The hook still exposes:
- `get(path, options?)` → resolves to `{ data }` (parsed JSON body)
- `post(path, body, options?)` → same
- `put(path, body, options?)` → same
- `createEventSource(path)` → returns native `EventSource`

Error objects from rejected promises still carry the axios-compatible shape:
```js
error.response.status        // HTTP status code
error.response.data          // parsed JSON body
error.response.data.message  // backend error message string
```
This is enforced by `makeApiError()` inside the hook. Call sites that branch on `err.response.status` (e.g. `torrent-selector.jsx`) work without modification.

## Auth/session error handling (unchanged)
- 401 → always clears session + redirects to login (unless `silent401: true` in options)
- 403 + session-failure message → clears session + redirects (unless `silent403: true`)
- 403 + permission-denied message (e.g. `DEV_PRIVILEGE_REQUIRED`) → toast only, no redirect
- 5xx → generic server error toast

`SESSION_FAILURE_MESSAGES` set is kept in sync with `backend/constants.py → HTTPErrorMessages`.

**Why:** Removes a bundled external dependency (axios) for a capability now natively available in all modern browsers. Eliminates potential version drift between axios error shapes and backend expectations.

**How to apply:** When adding new API call patterns, use the existing `get`/`post`/`put` methods from `useApi()`. Never re-introduce axios. If a new error shape is needed, update `makeApiError()` in the hook.
