---
name: frontend-webview-patterns
description: Use this skill when working on frontend/ — adding pages, hooks, or contexts, understanding the useApi axios instance (error handling, interceptors, silent flags), AppContext/useApp, ToastContext/useToast, ProductContext/useProducts, storage (wallet_id), Telegram WebApp integration, haptic feedback, or the useBuyProduct purchase flow. Covers React + Vite SPA patterns for a Telegram WebApp.
---

# Frontend WebApp Patterns

Stack: React + Vite, Axios, Tailwind CSS, Framer Motion, Lucide icons. Runs as a Telegram WebApp (Mini App).

---

## Context Hierarchy

```
<AppProvider>         ← wallet, inventory, tg, loading, refreshData
  <ToastProvider>     ← addToast (shows alert in Telegram or DOM toast)
    <ProductProvider> ← products list, cursor pagination, fetchProductById
      <App />
```

All providers must be nested in this order. `ToastProvider` uses `useApp` so it must be inside `AppProvider`.

---

## useApi — Axios Instance

Location: `frontend/src/hooks/use-api.js`

```js
import useApi from "../hooks/use-api";

const { get, post, put, delete: del, createEventSource } = useApi();

// GET /wallet → { data: walletObject }
const response = await get("/wallet");

// POST /payment/order
const response = await post("/payment/order", { owner_id, product_id, ... });
```

**Base URL resolution:**
```js
const baseURL = import.meta.env.VITE_API_BASE_URL || (isDevelopment ? "/api" : "/api/v2");
// dev: /api  (Vite proxy → FastAPI v1)
// prod: /api/v2  (Cookie-auth version)
```

**Always sent with:**
- `withCredentials: true` (sends HttpOnly auth cookie)
- `Content-Type: application/json`
- `X-Telegram-Init-Data: <tg.initData>` (from request interceptor)

---

## useApi — Error Handling Rules

The response interceptor handles errors globally. **Do not add `catch` toasts in component code** — they'll duplicate.

| Status | Condition | Action |
|--------|-----------|--------|
| Network / timeout | `ECONNABORTED` or no response | Toast + reject |
| 401 | any | Toast + `redirectToLogin()` (unless `silent401: true`) |
| 403 | `SESSION_FAILURE_MESSAGES` | Toast + `redirectToLogin()` |
| 403 | other message | Toast only (permission denied, stay in app) |
| 429 | any | Toast "Too many requests" |
| 5xx | any | Toast "Internal server error" |
| other 4xx | has `response.data.message` | Toast with backend message |

**Silent opts** — pass in axios config to suppress global handling:

```js
// Caller handles 403 itself (e.g. login page):
await post("/auth/login", payload, { silent403: true });

// Caller handles 401 itself:
await get("/endpoint", { silent401: true });
```

**redirectToLogin:**
1. `storage.removeWalletId()` — clears stored session
2. `location.assign("/")` after 3s — returns to login screen

---

## SESSION_FAILURE_MESSAGES

Kept in sync with `backend/constants.py → HTTPErrorMessages`. A 403 with one of these messages is treated as a session expiry (same as 401):

```js
const SESSION_FAILURE_MESSAGES = new Set([
  "Authentication required",
  "Invalid session",
  "Session expired: logged in from another location",
  "Telegram WebApp authentication required",
  "Invalid Telegram WebApp authentication",
  "Hash mismatch",
  "Expired",
  "Missing parameters",
]);
```

Any other 403 message → toast only, no redirect (e.g. `DEV_PRIVILEGE_REQUIRED`).

---

## AppContext — useApp

Location: `frontend/src/contexts/app-context.jsx`

```js
import { useApp } from "../contexts/app-context";

const { tg, wallet, inventory, loading, error, refreshData, isAuthenticated } = useApp();
```

| Field | Type | Description |
|-------|------|-------------|
| `tg` | `Telegram.WebApp \| undefined` | Telegram WebApp instance; `undefined` outside Telegram |
| `wallet` | `object \| undefined` | Current user's wallet; `undefined` if not logged in |
| `inventory` | `array` | Purchased inventory items |
| `loading` | `bool` | True while initial data is fetching |
| `isAuthenticated` | `bool` | `!!wallet` |
| `refreshData` | `async fn` | Re-fetch wallet + inventory in parallel |

`useApp` never throws — returns `{}` if used outside `AppProvider` (allows wrapping providers).

---

## ToastContext — useToast

Location: `frontend/src/contexts/toast-context.jsx`

```js
import { useToast } from "../contexts/toast-context";

const { addToast } = useToast();

addToast("Operation successful!", "success");
addToast("Something went wrong.", "error");
addToast("Heads up!", "info");
```

**Telegram-aware:** If `tg` is available and `type === "error"`, uses `tg.showAlert(message)` instead of DOM toast (native Telegram modal — blocks until user dismisses). For `success`/`info`, falls back to DOM toast even in Telegram.

Toast auto-dismisses after 4 seconds (DOM toasts only).

---

## ProductContext — useProducts

Location: `frontend/src/contexts/product-context.jsx`

```js
import { useProducts } from "../contexts/product-context";

const {
  products,           // list of loaded products
  loading,            // paginated list loading
  hasMore,            // false when last page reached
  lastDocId,          // cursor for next page fetch
  searchTerm,
  fetchProducts,      // paginated load
  fetchProductById,   // single product by ID (deduped in-flight)
  singleProductLoading,
  setSearchTerm,
} = useProducts();
```

**Cursor pagination:**
```js
// First page:
await fetchProducts(undefined, "", true, walletId);  // isNewSearch=true resets list

// Next page:
await fetchProducts(lastDocId, searchTerm, false, walletId);
```

**Single product (deduped in-flight):**
```js
const product = await fetchProductById(productId);
if (product?.notFound) { /* show 404 */ }
```

In-flight dedup: multiple concurrent `fetchProductById(sameId)` calls all await the same promise — no duplicate requests.

---

## storage — wallet_id Persistence

Location: `frontend/src/utils/storage.js`

```js
import { storage } from "../utils/storage";

storage.getWalletId()          // localStorage.getItem("wallet_id")
storage.setWalletId(id)        // localStorage.setItem("wallet_id", id)
storage.removeWalletId()       // localStorage.removeItem("wallet_id")
```

`AppContext.refreshData()` checks `storage.getWalletId()` — if `null`, skips fetching (user is not logged in).

---

## Telegram WebApp Integration

```js
const tg = globalThis.Telegram?.WebApp;  // always safe (undefined outside Telegram)

// User identity:
const userId = tg?.initDataUnsafe?.user?.id;
const initData = tg?.initData;            // sent as X-Telegram-Init-Data header

// Native dialogs:
tg.showAlert("Message");                  // blocks until OK
tg.showConfirm("Sure?", (ok) => { ... }); // callback-based confirm

// Version guard:
if (tg?.isVersionAtLeast("6.1")) { ... }
```

**Rule:** Always null-check with `?.` — `tg` is `undefined` in non-Telegram browsers (dev mode).

---

## Haptic Feedback

Location: `frontend/src/utils/haptic-helper.js`

```js
import { triggerHaptic } from "../utils/haptic-helper";

triggerHaptic("light");                           // impact: light/medium/heavy
triggerHaptic("heavy");                           // heavy impact (e.g. buy button)
triggerHaptic("success", "notificationOccurred"); // notification: success/warning/error
triggerHaptic(undefined, "selectionChanged");      // selection change
```

No-op outside Telegram or on Telegram versions < 6.1.

---

## useBuyProduct — Purchase Flow

Location: `frontend/src/hooks/use-buy-product.js`

```js
import useBuyProduct from "../hooks/use-buy-product";

const { handleBuy } = useBuyProduct();

// Trigger purchase:
await handleBuy(product, packet, "trakteer", () => { /* onSuccess */ });
```

**Flow:**
1. Get `userId` from `tg.initDataUnsafe.user.id`
2. Trigger haptic `"heavy"`
3. Show confirm dialog (`tg.showConfirm` or `window.confirm`)
4. POST `/payment/order` with `{ owner_id, product_id, packet_index, target_id, provider }`
5. Validate returned `payment_url` against `ALLOWED_PAYMENT_HOSTS`
6. Redirect: `location.href = paymentUrl`

**Payment URL whitelist:**
```js
const ALLOWED_PAYMENT_HOSTS = new Set(["trakteer.id", "saweria.co"]);
// Must be https: + hostname in set — never navigate to untrusted URLs
```

**Error handling:** All API errors handled by `useApi` interceptor — `handleBuy` catches silently (no duplicate toasts).

---

## Page Structure Pattern

```jsx
// frontend/src/pages/my-page.jsx
import { useApp } from "../contexts/app-context";
import { useToast } from "../contexts/toast-context";
import useApi from "../hooks/use-api";

const MyPage = () => {
  const { wallet, refreshData } = useApp();
  const { addToast } = useToast();
  const { post } = useApi();

  const handleAction = async () => {
    try {
      await post("/endpoint", { ... });
      addToast("Done!", "success");
      await refreshData();   // refresh wallet/inventory after mutation
    } catch {
      // errors already toasted by useApi interceptor
    }
  };

  return <div>...</div>;
};
```

---

## Development vs Production

```js
import { isDevelopment, isProduction } from "../utils/constants";
// isDevelopment: import.meta.env.MODE === "development"

// useApi base URL:
// dev:  /api     → proxied by Vite to FastAPI v1 (JWT Bearer)
// prod: /api/v2  → FastAPI v2 (HttpOnly Cookie)
```

For local dev without Telegram: `tg` is `undefined`; `X-Telegram-Init-Data` header is skipped with a console warning; `test_mode` in backend falls back to `get_test_mode_user()`.

---

## EventSource (SSE)

```js
const { createEventSource } = useApi();

const es = createEventSource("/log/stream?file=bot.log");
es.onmessage = (e) => console.log(e.data);
es.onerror = () => es.close();
```

`createEventSource` uses `baseURL` + path with `withCredentials: true` — no separate auth needed.
