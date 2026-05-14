---
name: project-blogger-integration
description: Use this skill when working on anything that bridges xBotz with the Blogger shortlink-rotator project. Covers the Blogger architecture, how the shortlink system works, how the bot generates/shares shortlinks via the XMissions rotator_blogs mission type, environment wiring, database management, build pipeline, and deployment integration patterns.
---

# Blogger Integration — Shortlink Rotator

## What Is Blogger?

`Blogger/` is a **fully static React + Vite insurance blog** that earns AdSense revenue by routing visitors through N random articles before revealing the destination URL. It is a **separate, independently deployed** front-end project that integrates with xBotz at the shortlink-generation layer.

**Stack**: React 19 · Vite 8 · Wouter (routing) · TanStack Query · Tailwind v4 · Radix UI · CryptoJS · sql.js (SQLite in WASM) · Framer Motion

---

## Directory Layout

```
Blogger/
├── client/
│   ├── public/
│   │   └── data/
│   │       ├── articles.db          # SQLite — encrypted content field
│   │       └── images/              # Article SVG images
│   └── src/
│       ├── App.tsx                  # Root — providers, router, lazy-loads
│       ├── components/
│       │   ├── shortlink-redirect-handler.tsx   # ?z= param → article rotator
│       │   ├── shortlink-generator.tsx          # Admin UI at /s
│       │   ├── article-completion-verification.tsx
│       │   ├── adblock-detector.tsx
│       │   └── anti-bot-verification.tsx
│       ├── lib/
│       │   ├── security.ts          # XOR rotator (?z=) + AES (DB content only)
│       │   ├── config.ts            # VITE_ env vars + path helpers
│       │   ├── content-loader.ts    # ContentLoader interface (SQLite-backed)
│       │   ├── secure-content.ts    # Thin helpers over betterSQLiteStaticLoader
│       │   ├── better-sqlite-loader.ts  # sql.js WASM loader for browser
│       │   ├── types.ts             # BlogPost, AppConfig interfaces
│       │   └── site-config.ts       # SITE_CONFIG object (static site content)
│       ├── pages/                   # home, post, category, shortlink, ...
│       └── hooks/                   # use-active-time-tracker, use-visitor-retention, ...
├── scripts/
│   ├── build.js                     # Custom Vite build wrapper (--obf flag)
│   ├── serve.js                     # Local dev/prod server
│   ├── convert-database.js          # .db ↔ JSON conversion
│   ├── rekey-database.js            # Re-encrypt DB with new VITE_ENC_KEY
│   ├── postbuild-obfuscate.js       # JS obfuscation pass
│   └── generate-seo.js              # Sitemap / robots / SEO files
├── .env.example                     # All env vars documented
└── vite.config.ts                   # base=BASE_PATH, output=dist/public/
```

---

## Environment Variables

All `VITE_` variables are **embedded at build time** into the browser bundle. They are intentionally client-visible — the encryption protects against bots, not determined users.

| Variable | Required | Default | Description |
|---|---|---|---|
| `VITE_ENC_KEY` | ✅ | — | **Pure integer — digits only** (e.g. `987654321`). Dual purpose: (1) XOR key for `?z=` rotator shortlinks — must match `rotator_enc_key` in the bot's WebsConfig; (2) AES passphrase (as string) for decrypting article content in `articles.db`. ⚠️ `parseInt("1234abcd")` silently returns `1234` — a mixed key causes silent decryption failure on all `?z=` links. |
| `VITE_SITE_URL` | ✅ | `https://example.com` | Canonical site URL for SEO / OG tags. |
| `VITE_AUTHOR_NAME` | — | `Admin` | Author name shown in UI. |
| `VITE_CONTACT` | — | `""` | Contact link (e.g. `https://t.me/username`). |
| `VITE_TOTAL_TIME_REQUIRED` | — | `120000` | Total active reading time (ms) before final redirect. |
| `VITE_MIN_READING_DELAY` | — | `10000` | Minimum per-article delay (ms). |
| `VITE_MAX_READING_DELAY` | — | `20000` | Maximum per-article delay (ms). |
| `VITE_MAX_VISITED_SLUGS` | — | `4` | Number of articles visitor must read. |
| `BASE_PATH` | — | `/` | Set to `/repo-name` for GitHub Pages project pages. |

---

## Shortlink System — Full Flow

### 1. Generate a shortlink (bot side)

The bot shares a link in this format:
```
https://yoursite.com/?z=<XOR_encrypted_destination_url>
```

**Why XOR instead of AES for `?z=`?**
CryptoJS AES produces standard base64 which contains `+`, `/`, and `=`. Percent-encoding these (`%2B`, `%2F`, `%3D`) doesn't help — Telegram force-decodes percent-encoded URLs back to raw characters before opening them in the browser, breaking path routing. XOR + URL-safe base64 produces only `[A-Za-z0-9_-]`, which is safe in any URL position without any encoding.

**JS side** (`lib/security.ts`):
```typescript
// Encodes destination for ?z= — uses XOR + URL-safe base64
export function shortUrl(text: string): string {
  return rotatorEncode(text);   // integer key from VITE_ENC_KEY
}

// Decodes ?z= token back to destination URL
export function rotatorDecode(token: string): string { ... }

// resolveShortUrl() is AES — for SQLite DB content ONLY, not ?z=
```

**Bot integration** (`bot/utils/rotator.py`):
```python
from bot.utils.rotator import generate_rotator_link

# enc_key = int from WebsConfig.rotator_enc_key (same as VITE_ENC_KEY)
rotator_url = generate_rotator_link(telegram_link, enc_key, rotator_links)
# → "https://yoursite.com/?z=<url_safe_base64_token>"
```

The Python side uses `bot/utils/crypto.py → Encryption.encrypt(key, text=...)` which is XOR + `base64.urlsafe_b64encode`. The JS side in `security.ts → rotatorEncode/rotatorDecode` mirrors this exactly (little-endian 8-byte key, repeating XOR, URL-safe base64).

### 2. Admin UI at `/s`

| Route | Behavior |
|---|---|
| `/s` | Form UI — paste URL, click Generate, copy shortlink |
| `/s?url=<destination>` | Auto-encrypts and immediately starts the rotator |

### 3. Visitor receives `?z=` link

`ShortlinkRedirectHandler` (wraps entire app in `App.tsx`) intercepts `?z=` on page load:
1. Decrypts to get destination URL
2. Loads all blog posts from SQLite
3. Picks a random first article
4. Creates `verification-state` in `sessionStorage`
5. Redirects to `/post/<random-slug>`

### 4. Verification state machine (sessionStorage)

```typescript
interface VerificationState {
  shortParam: string;          // encrypted destination (kept encrypted)
  currentStep: number;
  totalSteps: number;          // = VITE_MAX_VISITED_SLUGS
  completedSteps: number;
  visitedSlugs: string[];
  startTime: number;
  totalTimeRequired: number;   // = VITE_TOTAL_TIME_REQUIRED
  articleCompletionTimes: number[];
  activeTime: number;          // ms of active tab time
  lastActiveTime: number;
}
```

### 5. Article completion → next article or final redirect

`completeVerification()` (from `shortlink-redirect-handler.tsx`) is called when a visitor finishes reading:
- Adds current slug to `visitedSlugs`
- Checks `visitedSlugs.length >= totalSteps` AND `activeTime >= totalTimeRequired`
- If both met → decrypt `shortParam` → `window.location.href = destination`
- Otherwise → pick next unvisited random article → redirect to `/post/<slug>`

---

## Content / Database

Articles live in `client/public/data/articles.db` — a SQLite file loaded in the browser via **sql.js (WASM)**. The `content` field is AES-encrypted with `VITE_ENC_KEY`.

```typescript
// BlogPost shape (lib/types.ts)
interface BlogPost {
  title: string;
  excerpt: string;
  slug: string;
  category: string;
  content: string;      // AES-encrypted HTML content
  readTime: string;
  tags: string[];
  publishedDate: string;
  imageUrl: string;
}
```

### Database scripts

```bash
# Convert .db ↔ JSON (for inspection/editing)
node scripts/convert-database.js

# Re-encrypt all content with a new key
OLD_KEY=previousKey VITE_ENC_KEY=newKey node scripts/rekey-database.js
```

---

## Build Pipeline

```bash
# Development (build + local serve)
npm run dev

# Standard production build → dist/public/
npm run build

# Secure build (+ JS obfuscation via javascript-obfuscator)
npm run build:secure
```

Build output: `dist/public/` — deploy this directory to any static host.

File names are content-hashed (`[hash].js`, `[hash].[ext]`) — no source maps in production.

---

## Deployment Options

| Host | Config |
|---|---|
| **GitHub Pages** | `BASE_PATH=/repo-name`, upload `dist/public/` to `gh-pages` branch |
| **Cloudflare Pages** | `BASE_PATH=/`, build command: `npm run build:secure`, output: `dist/public/` |
| **Vercel / Netlify** | Same as Cloudflare — set `BASE_PATH=/` in env vars |

`client/public/_redirects` and `client/public/_headers` handle SPA fallback routing on Cloudflare/Netlify.

---

## Integration Points with xBotz Bot

### How the bot uses Blogger

1. **Per-mission config** — each `rotator_blogs` mission in MongoDB stores its own `rotator_enc_key` (integer) and `rotator_links` (list of URL prefixes). Owners set these once through the bot's `/xmissions` → Manage Missions UI. There is no global WebsConfig field for the rotator anymore.

2. **Bot generates shortlinks** — when a user opens a rotator_blogs mission, `rotator_blogs_task()` reads the mission's `rotator_enc_key` and `rotator_links`, XOR-encrypts the Telegram deep link with `bot/utils/rotator.py`, and sends:
   ```
   https://yoursite.com/?z=<XOR_url_safe_base64_token>
   ```

3. **Sharing flow** — bot sends `?z=` links in Telegram messages. Recipients click → land on Blogger → read N articles → `rotatorDecode()` recovers destination → user is redirected back to the bot via a `_xm_` deep link → reward is credited.

4. **Auto-rotator link** — bot can also share `/s?url=<raw_destination>` for admin-level access (no encryption needed, the site handles it).

### Key shared secret

`rotator_enc_key` (per-mission `MissionModel` field) and `VITE_ENC_KEY` (Blogger `.env`) **must be the same pure integer value** — digits only, no letters or symbols.

> ⚠️ **Silent failure trap**: The Blogger JS uses `parseInt(VITE_ENC_KEY, 10)`, which stops at the first non-digit character. Setting `VITE_ENC_KEY=1234abcd` silently uses `1234` as the key. The bot (Python) receives the full string and stores it as an `int` field, so both sides must be set to identical digit-only integers or all `?z=` tokens will decrypt to garbage with no error raised.

### Generating `?z=` links from Python (bot side)

Use `bot/utils/rotator.py` — do **not** replicate CryptoJS AES in Python, that approach was abandoned because Telegram force-decodes percent-encoded slashes.

```python
from bot.utils.rotator import generate_rotator_link

# mission is a MissionModel loaded from db_manager.missions
rotator_url = generate_rotator_link(
    destination_url=telegram_link,       # e.g. "https://t.me/bot?start=_xm_TOKEN"
    enc_key=mission.rotator_enc_key,     # integer — must match VITE_ENC_KEY
    rotator_links=mission.rotator_links, # ["https://yoursite.com/?z="]
)
# Returns: "https://yoursite.com/?z=<url_safe_base64_token>"
```

Internally this calls `Encryption.encrypt(enc_key, text=destination_url)` from `bot/utils/crypto.py`, which uses XOR + `base64.urlsafe_b64encode` — output is `[A-Za-z0-9_-]` only, no percent-encoding ever needed.

The Blogger JS (`security.ts → rotatorDecode`) mirrors the algorithm exactly: little-endian 8-byte key, repeating XOR, URL-safe base64 decode.

---

## XMissions — Rotator Blogs Integration

The primary use of the Blogger rotator in xBotz is the **`rotator_blogs` mission type** inside the XMissions system. This replaced the old `/freecredits` (`_fc_`) system entirely.

> ⚠️ **Migration note**: The old `bot/modules/free_credits.py`, `bot/modules/daily_task.py`, `_fc_` token prefix, and `db_manager.free_credits` collection no longer exist. Everything is now handled through `bot/modules/xmissions/rotator_blogs.py` and the shared `db_manager.claim_records` collection.

### Key files

| File | Responsibility |
|---|---|
| `bot/modules/xmissions/rotator_blogs.py` | `rotator_blogs_task(client, user_id, mission)` — generates the Blogger shortlink and returns it as text |
| `bot/modules/xmissions/xmissions.py` | Menu router — dispatches to `rotator_blogs_task` for `MissionType.ROTATOR_BLOGS` missions |
| `bot/plugins/xmissions.py` | Registers `/xmissions` command and all `xm` callbacks |
| `bot/modules/core/start.py → _handle_xm_deeplink()` | Validates the returning `_xm_` deep link and credits the reward |

### User-facing commands

`/xmissions` — private chats only. Shows a menu of all active missions for the bot. The Rotator Blogs mission appears as a 🎁-prefixed button.

### Per-mission config (stored in MissionModel, set by owner via bot UI)

| Field | Type | Description |
|---|---|---|
| `rotator_links` | `list[str]` | Rotator URL prefixes, e.g. `["https://yoursite.com/?z="]` |
| `rotator_enc_key` | `int` | XOR key — **must match `VITE_ENC_KEY` in Blogger `.env`**. Pure integer only. |
| `reward_type` | `MissionRewardType` | `credits` or `product` |
| `reward_amount` | `float \| None` | Credits awarded on completion (when `reward_type=credits`) |
| `reward_product_id` | `str \| None` | Product ID granted on completion (when `reward_type=product`) |

Config is stored per-mission in MongoDB (`db_manager.missions`), not in WebsConfig. Bot checks `if not mission.rotator_links or not mission.rotator_enc_key` and returns a config-missing error if either is unset.

### Token format (`_xm_` prefix)

```
plaintext : "_xm_<mission_id>_<user_id>_<YYYYMMDD>"
encrypted : Encryption.encrypt(bot_id, text=plaintext)   # XOR + URL-safe base64
deep link : "https://t.me/<bot_username>?start=<token>"
```

The deep link is then wrapped by `generate_rotator_link(telegram_link, enc_key, rotator_links)` → final Blogger URL the user receives. Token built by `build_xm_token(client, mission_id, user_id, task_date)` in `rotator_blogs.py`.

### Validation in `_handle_xm_deeplink()` (start.py)

Sub-prefix routing: any token NOT starting with `ref` goes through the rotator_blogs path.

1. Splits decrypted token on `_` → `[mission_id, token_user_id, YYYYMMDD]`
2. **Anti-sharing check**: `token_user_id` must equal `message.from_user.id` — rejects forwarded/shared links
3. **Duplicate check**: `db_manager.claim_records.has_claimed(user_id, mission_id, task_date)` must be False
4. Loads `MissionModel` from `db_manager.missions.get(mission_id)`
5. On success: `grant_reward(client, user_id, mission)` then `db_manager.claim_records.record_claim(...)`

### DB collections used

| Collection | Method | Purpose |
|---|---|---|
| `db_manager.missions` | `get(mission_id)` | Load mission config + reward fields |
| `db_manager.claim_records` | `has_claimed(user_id, mission_id, task_date)` | Check if today already claimed |
| `db_manager.claim_records` | `record_claim(user_id, mission_id, task_date, ...)` | Mark as claimed after reward |

Claim record key format: `<user_id>_<mission_id>_<YYYYMMDD>` — resets at midnight UTC.

---

## Component Reference

| Component | Location | Purpose |
|---|---|---|
| `ShortlinkRedirectHandler` | `components/shortlink-redirect-handler.tsx` | App-level interceptor for `?z=` param |
| `ShortlinkGenerator` | `components/shortlink-generator.tsx` | Admin UI at `/s` |
| `ArticleCompletionVerification` | `components/article-completion-verification.tsx` | Per-article timer + next-step trigger |
| `AdBlockDetector` | `components/adblock-detector.tsx` | Detects adblockers (for AdSense revenue protection) |
| `AntiBotVerification` | `components/anti-bot-verification.tsx` | Bot challenge before redirect |
| `VisitorEngagementTracker` | `components/visitor-engagement-tracker.tsx` | Tracks active tab time |

---

## Path Helpers (lib/config.ts)

```typescript
getBasePath()          // returns "" or "/repo-name" (no trailing slash)
getDataPath(filename)  // → "/data/articles.db" or "/repo-name/data/articles.db"
getRouterBase()        // base for Wouter router
getImagePath(url)      // handles absolute URLs vs relative paths
getFullPath(path)      // for navigation/redirects with basePath prefix
getEnvConfig()         // returns all VITE_ env config as typed object
```

---

## Common Tasks

### Add a new article to the database
1. Use `node scripts/convert-database.js` to export to JSON
2. Add the article entry with encrypted `content` field
3. Re-import using the same script
4. Rebuild: `npm run build`

### Rotate the encryption key
```bash
OLD_KEY=<current_key> VITE_ENC_KEY=<new_key> node scripts/rekey-database.js
```
Then update `VITE_ENC_KEY` in `.env` and in xBotz bot config. Rebuild. Old shortlinks break.

### Test shortlink generation locally
```bash
npm run dev   # serves at localhost with the dev server
# Visit /s → paste URL → Generate → copy the ?z= link
# Test by pasting ?z= link in browser
```

### Deploy to Cloudflare Pages
1. Set `BASE_PATH=/` in Cloudflare env vars
2. Set `VITE_ENC_KEY`, `VITE_SITE_URL`, etc.
3. Build command: `npm run build:secure`
4. Output directory: `dist/public`
