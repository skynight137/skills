# Web content lanes — measured behavior

Four lanes, cheapest first. Measured on a Replit/Nix sandbox.

| Lane | Use for | Cost |
|------|---------|------|
| `web_search(query)` | finding URLs, answering a question | no browser |
| `web_extract([url])` | reading a page you already have the URL for | no browser, returns markdown |
| `browser_exec` | clicking, typing, JS, logins on ordinary sites | one Chromium tab |
| Camofox `:8008` | the lanes above returned a bot wall | ~20s cold launch, 60-90s first time |

## Block detection, by signature

Do not conclude "the page was empty" from a blank-looking result. Check the
signature:

- `browser_exec` on a WAF-blocked page: title is a placeholder with an
  emoji prefix and the bare hostname, and `document.body.innerText` is
  **length 0**. That is a block page, not an empty document.
- `web_extract` on a bot-walled URL: returns the challenge page itself with
  a **very short** content length. Check the length before trusting it.
- Camofox non-fatal challenge: `POST /tabs` answers `HTTP 200` but the JSON
  body carries `httpStatus: 403, navigationOk: false`, and the returned
  `url` may be rewritten to include a `__cf_chl_rt_tk` challenge token.

## Escalate on the signature, not on the domain

A domain is not permanently blocked. The escalation that actually worked:

1. First `POST /tabs` to a Cloudflare-fronted site -> `httpStatus: 403`.
2. **Retry the same `sessionKey`** (the profile now holds the CF clearance
   cookie) -> `httpStatus: 200, navigationOk: true` with the real document.

So: retry the same session before assuming a site needs a different tool.
A brand-new `sessionKey` repeats the challenge; reuse the one that got
through.

## Reading content out of Camofox

`POST /tabs` returns only `{tabId, url, httpStatus, navigationOk}` — not the
page. Fetch content with one of:

- `GET /tabs/<tabId>/snapshot?userId=<u>` -> `{url, snapshot, structure,
  refsCount, truncated, totalChars}`; `snapshot` is an accessibility tree
  with `[eNN]` refs you can click by.
- `POST /tabs/<tabId>/evaluate` with `{"userId": "<u>", "expression":
  "..."}` -> `{ok, result}` for `document.title`, `document.body.innerText`,
  etc.

The accessor needs `userId` (a bare `GET /tabs/<id>` is a 404/400 — that is
not a missing tab). Any endpoint that takes the id also takes the `userId`
query param.