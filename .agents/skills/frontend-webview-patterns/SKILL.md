---
name: frontend-webview-patterns
<<<<<<< HEAD
description: Use this skill when working on frontend/ — adding pages, hooks, or contexts, understanding the useApi axios instance (error handling, interceptors, silent flags), AppContext/useApp, ToastContext/useToast, ProductContext/useProducts, storage (wallet_id), Telegram WebApp integration, haptic feedback, or the useBuyProduct purchase flow. Covers React + Vite SPA patterns for a Telegram WebApp.
=======
description: >-
  Use this skill when working on frontend/ — adding pages, hooks, or contexts,
  understanding the useApi native-fetch instance (error handling, timeout,
  silent flags), the three-context split (AppContext/useApp for tg,
  SessionContext/useSession for wallet+auth, InventoryContext/useInventory for
  inventory pagination), ToastContext/useToast, ProductContext/useProducts,
  storage (wallet_id), Telegram WebApp integration, haptic feedback, or the
  useBuyProduct purchase flow. Covers React + Vite SPA patterns for a Telegram
  WebApp.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Frontend WebApp Patterns

<<<<<<< HEAD
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
=======
Stack: React 19 + Vite, native fetch (axios removed), Tailwind CSS, Framer Motion, Lucide icons. Runs as a Telegram WebApp (Mini App).

---

## Provider Tree (actual mount order)

```
<React.StrictMode>           main.jsx
  <ToastProvider>            addToast (DOM toast or tg.showAlert)
    <ProductProvider>        products list, cursor pagination
      <AppWrapper>           app.jsx — ErrorBoundary wrapper
        <AppProvider>        tg: Telegram.WebApp (stable reference)
          <SessionProvider>  wallet, loading, isAuthenticated, refreshSession
            <InventoryProvider> inventory, inventoryCursor, inventoryHasMore, refreshInventory
              <Router>
                <App />
```

**Critical ordering rule**: `SessionProvider` and `InventoryProvider` must be inside `AppProvider` — they both call `useApi()` which calls `useApp()` to get `tg`.

**Known limitation**: `ToastProvider` is mounted *above* `AppProvider` in `main.jsx`, so `useApp()` inside `ToastProvider` always returns `{}` with `tg = undefined`. The `tg.showAlert()` path in `addToast` effectively never fires — all toasts are DOM toasts. This is pre-existing behaviour; fixing it requires moving `ToastProvider` inside `AppProvider`.

---

## Context 1 — AppContext / useApp

Location: `frontend/src/contexts/app-context.jsx`

```js
import { useApp } from "../contexts/app-context";

const { tg } = useApp();
```

| Field | Type | Description |
|-------|------|-------------|
| `tg` | `Telegram.WebApp \| undefined` | Telegram WebApp instance; `undefined` outside Telegram or in dev mode |

`tg` is derived from `globalThis.Telegram?.WebApp` at provider mount — it is a stable reference that never changes. `useApp()` returns `{}` when used outside `AppProvider` (safe default).

**Consumers**: `use-api.js`, `toast-context.jsx`, `product-details.jsx`, `use-buy-product.js`, `login.jsx`, `profile.jsx`, `App`, `TelegramGuard` in `app.jsx`.

---

## Context 2 — SessionContext / useSession

Location: `frontend/src/contexts/session-context.jsx`

```js
import { useSession } from "../contexts/session-context";

const { wallet, loading, error, isAuthenticated, refreshSession } = useSession();
```

| Field | Type | Description |
|-------|------|-------------|
| `wallet` | `object \| undefined` | Current user's wallet; `undefined` if not logged in |
| `loading` | `bool` | True while initial `/wallet` fetch is in progress |
| `error` | `Error \| undefined` | Set if the wallet fetch throws |
| `isAuthenticated` | `bool` | `!!wallet` |
| `refreshSession` | `async fn` | Re-fetch `/wallet` and update state |

**Consumers**: `AuthGuard`, `DevelopmentGuard`, `Home`, `Wallet` in `app.jsx`.

---

## Context 3 — InventoryContext / useInventory

Location: `frontend/src/contexts/inventory-context.jsx`

```js
import { useInventory } from "../contexts/inventory-context";

const { inventory, inventoryCursor, inventoryHasMore, loading, refreshInventory } = useInventory();
```

| Field | Type | Description |
|-------|------|-------------|
| `inventory` | `array` | First page of purchased inventory items |
| `inventoryCursor` | `string \| null` | Cursor for the next page |
| `inventoryHasMore` | `bool` | False when last page is reached |
| `loading` | `bool` | True while initial `/inventory` fetch is in progress |
| `refreshInventory` | `async fn` | Re-fetch `/inventory` (first page) and update state |

**Consumer**: `Inventory` page.

---

## AuthGuard — combined loading gate

`AuthGuard` in `app.jsx` waits for **both** `SessionProvider.loading` AND `InventoryProvider.loading` before rendering children:

```js
const { isAuthenticated, loading: sessionLoading, refreshSession } = useSession();
const { loading: inventoryLoading, refreshInventory } = useInventory();
const loading = sessionLoading || inventoryLoading;
```

This ensures pages always mount with fully populated context values. After login success, both `refreshSession()` and `refreshInventory()` are called:

```js
const handleLoginSuccess = useCallback(() => {
  refreshSession();
  refreshInventory();
}, [refreshSession, refreshInventory]);
```

---

## useApi — Native Fetch Instance
>>>>>>> 2ecb89d (update)

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
<<<<<<< HEAD
- `withCredentials: true` (sends HttpOnly auth cookie)
- `Content-Type: application/json`
- `X-Telegram-Init-Data: <tg.initData>` (from request interceptor)
=======
- `credentials: "include"` (sends HttpOnly auth cookie)
- `Content-Type: application/json`
- `X-Telegram-Init-Data: <tg.initData>` (injected per-request from `tgRef.current`)

**Timeout:** Every request has a 30-second `AbortController` timeout. The timer is cleared in a `finally` block on fast responses.

**`tg` ref pattern:** `tg` is captured via `useRef` and updated on every render — the `useMemo` instance is NOT recreated when `tg` changes:
```js
const tgRef = useRef(tg);
tgRef.current = tg;  // always up-to-date without causing instance recreation
```
>>>>>>> 2ecb89d (update)

---

## useApi — Error Handling Rules

<<<<<<< HEAD
The response interceptor handles errors globally. **Do not add `catch` toasts in component code** — they'll duplicate.

| Status | Condition | Action |
|--------|-----------|--------|
| Network / timeout | `ECONNABORTED` or no response | Toast + reject |
=======
The response handler covers errors globally. **Do not add `catch` toasts in component code** — they'll duplicate.

| Status | Condition | Action |
|--------|-----------|--------|
| Timeout | `AbortError` (30s exceeded) | Toast "Request timed out" + reject |
| Network | No response (connection refused etc.) | Toast "Network error" + reject |
>>>>>>> 2ecb89d (update)
| 401 | any | Toast + `redirectToLogin()` (unless `silent401: true`) |
| 403 | `SESSION_FAILURE_MESSAGES` | Toast + `redirectToLogin()` |
| 403 | other message | Toast only (permission denied, stay in app) |
| 429 | any | Toast "Too many requests" |
| 5xx | any | Toast "Internal server error" |
| other 4xx | has `response.data.message` | Toast with backend message |

<<<<<<< HEAD
**Silent opts** — pass in axios config to suppress global handling:
=======
**Silent opts** — pass as options object (third arg for `post`/`put`, second arg for `get`/`delete`):
>>>>>>> 2ecb89d (update)

```js
// Caller handles 403 itself (e.g. login page):
await post("/auth/login", payload, { silent403: true });

// Caller handles 401 itself:
await get("/endpoint", { silent401: true });
```

**redirectToLogin:**
1. `storage.removeWalletId()` — clears stored session
<<<<<<< HEAD
2. `location.assign("/")` after 3s — returns to login screen
=======
2. `location.assign("/")` after 500ms — returns to login screen

**Error shape** (axios-compatible, enforced by `makeApiError()`):
```js
error.response.status        // HTTP status code
error.response.data          // parsed JSON body
error.response.data.message  // backend error message string
```
>>>>>>> 2ecb89d (update)

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

<<<<<<< HEAD
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

=======
>>>>>>> 2ecb89d (update)
## ToastContext — useToast

Location: `frontend/src/contexts/toast-context.jsx`

```js
import { useToast } from "../contexts/toast-context";

const { addToast } = useToast();

addToast("Operation successful!", "success");
addToast("Something went wrong.", "error");
addToast("Heads up!", "info");
```

<<<<<<< HEAD
**Telegram-aware:** If `tg` is available and `type === "error"`, uses `tg.showAlert(message)` instead of DOM toast (native Telegram modal — blocks until user dismisses). For `success`/`info`, falls back to DOM toast even in Telegram.

Toast auto-dismisses after 4 seconds (DOM toasts only).
=======
Toast auto-dismisses after 4 seconds. `useToast()` throws if called outside `ToastProvider`.
>>>>>>> 2ecb89d (update)

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

<<<<<<< HEAD
In-flight dedup: multiple concurrent `fetchProductById(sameId)` calls all await the same promise — no duplicate requests.

=======
>>>>>>> 2ecb89d (update)
---

## storage — wallet_id Persistence

Location: `frontend/src/utils/storage.js`

```js
import { storage } from "../utils/storage";

storage.getWalletId()          // localStorage.getItem("wallet_id")
storage.setWalletId(id)        // localStorage.setItem("wallet_id", id)
storage.removeWalletId()       // localStorage.removeItem("wallet_id")
```

<<<<<<< HEAD
`AppContext.refreshData()` checks `storage.getWalletId()` — if `null`, skips fetching (user is not logged in).
=======
Both `SessionProvider` and `InventoryProvider` check `storage.getWalletId()` at fetch time — if `null`, they skip fetching (user is not logged in) and set their loading state to `false` immediately.
>>>>>>> 2ecb89d (update)

---

## Telegram WebApp Integration

```js
<<<<<<< HEAD
const tg = globalThis.Telegram?.WebApp;  // always safe (undefined outside Telegram)
=======
const { tg } = useApp();   // from AppContext — stable reference
>>>>>>> 2ecb89d (update)

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
<<<<<<< HEAD
await handleBuy(product, packet, "trakteer", () => { /* onSuccess */ });
=======
handleBuy(product, packet, "trakteer", () => { /* onSuccess — called before redirect */ });
>>>>>>> 2ecb89d (update)
```

**Flow:**
1. Get `userId` from `tg.initDataUnsafe.user.id`
2. Trigger haptic `"heavy"`
3. Show confirm dialog (`tg.showConfirm` or `window.confirm`)
<<<<<<< HEAD
4. POST `/payment/order` with `{ owner_id, product_id, packet_index, target_id, provider }`
5. Validate returned `payment_url` against `ALLOWED_PAYMENT_HOSTS`
6. Redirect: `location.href = paymentUrl`
=======
4. **Guard check**: `isProcessing.current` — returns immediately if a previous call is still in-flight (prevents double-tap double-purchases)
5. POST `/payment/order` with `{ owner_id, product_id, packet_index, target_id, provider }`
6. Validate returned `payment_url` against `ALLOWED_PAYMENT_HOSTS`
7. Redirect: `location.href = paymentUrl`; call `onSuccess` if provided
>>>>>>> 2ecb89d (update)

**Payment URL whitelist:**
```js
const ALLOWED_PAYMENT_HOSTS = new Set(["trakteer.id", "saweria.co"]);
// Must be https: + hostname in set — never navigate to untrusted URLs
```

<<<<<<< HEAD
=======
**Double-tap guard:** `isProcessing = useRef(false)` — set before the POST, cleared in `finally`. Uses `useRef` (not `useState`) to avoid triggering re-renders.

>>>>>>> 2ecb89d (update)
**Error handling:** All API errors handled by `useApi` interceptor — `handleBuy` catches silently (no duplicate toasts).

---

## Page Structure Pattern

```jsx
// frontend/src/pages/my-page.jsx
<<<<<<< HEAD
import { useApp } from "../contexts/app-context";
=======

// For pages that need wallet/auth state:
import { useSession } from "../contexts/session-context";

// For pages that need inventory:
import { useInventory } from "../contexts/inventory-context";

// For pages that only need tg (Telegram identity):
import { useApp } from "../contexts/app-context";

>>>>>>> 2ecb89d (update)
import { useToast } from "../contexts/toast-context";
import useApi from "../hooks/use-api";

const MyPage = () => {
<<<<<<< HEAD
  const { wallet, refreshData } = useApp();
=======
  const { wallet } = useSession();          // wallet data
  const { inventory } = useInventory();     // purchased items
  const { tg } = useApp();                 // Telegram WebApp
>>>>>>> 2ecb89d (update)
  const { addToast } = useToast();
  const { post } = useApi();

  const handleAction = async () => {
    try {
      await post("/endpoint", { ... });
      addToast("Done!", "success");
<<<<<<< HEAD
      await refreshData();   // refresh wallet/inventory after mutation
=======
      // To refresh session after mutation:
      // const { refreshSession } = useSession();
      // await refreshSession();
>>>>>>> 2ecb89d (update)
    } catch {
      // errors already toasted by useApi interceptor
    }
  };

  return <div>...</div>;
};
```

<<<<<<< HEAD
=======
**Context selection guide:**
- Need `tg` only → `useApp()`
- Need `wallet`, `isAuthenticated`, `loading` → `useSession()`
- Need `inventory`, `inventoryCursor`, `inventoryHasMore` → `useInventory()`
- Need products list → `useProducts()`

>>>>>>> 2ecb89d (update)
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

<<<<<<< HEAD
`createEventSource` uses `baseURL` + path with `withCredentials: true` — no separate auth needed.
=======
`createEventSource` appends `init_data` as a URL query param (EventSource cannot send custom headers). Cookies (`withCredentials`) still carry the session.
>>>>>>> 2ecb89d (update)
