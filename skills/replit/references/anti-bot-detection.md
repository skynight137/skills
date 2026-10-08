# Anti-bot detection — how to test whether a browser is detectable

How to tell whether an automation lane on this box is **detectable as a bot**,
which test sites to use, how to read them, and how Camofox's WebGL spoof is
handled on this GPU-less Replit host.

Scope: this file is about **detection**. The lane-selection playbook (which
tool to reach for, cheapest first) lives in `web-content-lanes.md`; the
Camofox install/server detail is in `camofox.md`. Read those for *how to run*
a lane; read this for *how to tell whether it's being caught*.

> Every URL below was fetched and confirmed live at time of writing. Anything
> that could not be reached, or that returns a 404, is called out explicitly —
> do not cite it.

## 1. Test sites (all verified live)

Two kinds of site: **self-report tests** (the page runs JS in your browser and
prints a verdict — good for a headless/session check you can run yourself) and
**signature checkers** (they show the raw values a detection vendor would use —
read the values, not a score).

| Site | URL | What it measures |
|---|---|---|
| Sannysoft bot test | `https://bot.sannysoft.com/` | Classic Intoli-derived table: `navigator.webdriver` (plain + advanced), Chrome object presence, plugin array, languages, WebGL vendor/renderer, broken-image dimensions. |
| CreepJS | `https://abrahamjuliot.github.io/creepjs/` | Deep fingerprinting + detection: **lies/contradictions** score, headless heuristics, prototype tampering (stealth-plugin tells), timezone/UA consistency, canvas/webgl/audio entropy, worker-vs-main-thread mismatch. The single best "is my stealth leaking" page. |
| BrowserScan | `https://www.browserscan.net/` | Fingerprint summary + bot probability, IP/proxy, DNS leak, WebRTC; UA parse and TLS-ish signals. |
| BrowserScan bot-detection page | `https://www.browserscan.net/bot-detection` | Focused WebDriver / automation-indicator verdict; explains which properties flag a controlled browser. |
| BrowserLeaks — Canvas | `https://browserleaks.com/canvas` | Canvas 2D hash (per-browser-render unique), support detection, toDataURL behaviour. |
| BrowserLeaks — WebGL | `https://browserleaks.com/webgl` | WebGL vendor/renderer string, unmasked vendor/renderer, extensions, parameters — the raw GPU fingerprint a vendor reads. |
| BrowserLeaks — Fonts | `https://browserleaks.com/fonts` | Font list/metrics fingerprint; fonts are a strong OS/brand tell and a stealth-plugin giveaway. |
| BrowserLeaks — WebRTC | `https://browserleaks.com/webrtc` | WebRTC leak: local + public IP via ICE, RTCPeerConnection support, media-device enumeration. |
| BrowserLeaks — JavaScript | `https://browserleaks.com/javascript` | DOM/JS environment tab: screen, window, navigator fields, headless-adjacent properties. |
| BrowserLeaks (hub) | `https://browserleaks.com/` | Index of the whole fingerprint suite (IP, DNS, TLS, canvas, webgl, fonts, webrtc, javascript, …). |
| Antoine Vastel — areyouheadless | `https://arh.antoinevastel.com/bots/areyouheadless` | Minimal, explicit headless check ("You are/are not Chrome headless"); research-grade, from a bot-detection researcher. |
| Antoine Vastel — bot research home | `https://antoinevastel.com/bots/` | Researcher hub; links the tests and the newer fingerprint-scan work. |
| deviceandbrowserinfo — are you a bot | `https://deviceandbrowserinfo.com/are_you_a_bot` | Fingerprint-signal bot verdict with **raw detection details** — shows the exact signals behind the decision. |
| deviceandbrowserinfo — hub | `https://deviceandbrowserinfo.com/` | Anti-fraud/bot-detection test collection (device, browser, fingerprinting). |
| fingerprint-scan.com | `https://fingerprint-scan.com/` | Live fingerprint + bot-risk score: WebRTC leak, headers, GPU, DRM, automation indicators; prints a hash and a score. |
| FingerprintJS demo | `https://demo.fingerprint.com/` | Commercial FingerprintJS visitor-ID / smart-signal demo — how a paid vendor sees the session. |
| Rebrowser bot-detector | `https://bot-detector.rebrowser.net/` | Modern Chromium-specific automation tests (the leak tells that survive naive stealth patches). **Chromium-only** — it states that itself; a Firefox/Camofox lane will not exercise it meaningfully. |
| AmIUnique | `https://amiunique.org/` | Academic fingerprint-uniqueness study: how identifiable your fingerprint is vs the crowd. |
| NopeCHA — Cloudflare | `https://nopecha.com/demo/cloudflare` | Live Cloudflare challenge demo (interactive). |
| NopeCHA — hCaptcha | `https://nopecha.com/demo/hcaptcha` | Live hCaptcha (incl. Enterprise) demo (interactive). |
| NopeCHA — Turnstile | `https://nopecha.com/demo/turnstile` | Live Cloudflare Turnstile widget demo (interactive). |
| NopeCHA — demo index | `https://nopecha.com/demo` | Index of challenge demos (Turnstile, hCaptcha, reCAPTCHA, AWS WAF, Arkose, …). |
| Cloudflare Turnstile (product) | `https://www.cloudflare.com/products/turnstile/` | Official description of the Turnstile widget — what it is and how it's deployed. |
| HUMAN Security (PerimeterX) | `https://www.humansecurity.com/` | PerimeterX's current brand/home; the vendor whose challenge you hit on PX-protected sites. |
| PerimeterX legacy URL | `https://www.perimeterx.com/` | Redirects to `humansecurity.com` (verified) — use the HUMAN URL. |

### Could not be used / does not exist — do not cite

- `https://abrahamjuliot.github.io/creepjs/tests.html` — **404** (verified:
  "File not found · GitHub Pages"). The CreepJS tests live inside the single
  root page, not at a `/tests.html` path. Cite the root `creepjs/` URL only.

There is **no public, self-hosted PerimeterX or Datadome "test page"** that is
stable enough to cite here — those are deployed per-customer. To exercise them,
open a real PX/Datadome-protected site (e.g. a retail login) and watch for the
challenge instead. Vendor home pages above document the products but do not run
a test against *your* browser.

## 2. How to read the results

**Read the raw signals, not the marketing score.** A "bot probability: 30%"
number is opaque; the fields behind it are actionable.

### What leaks, and the tell

| Vector | What a detector reads | Bot tell |
|---|---|---|
| `navigator.webdriver` | Boolean | `true` = puppeteer/Playwright default. Must be `undefined`/`false`. |
| WebGL vendor/renderer | `UNMASKED_VENDOR_WEBGL`, `UNMASKED_RENDERER_WEBGL` | `null`, `"Google SwiftShader"`, `"Mesa/"` on a box with no GPU, or a string that contradicts the claimed OS/device. |
| Canvas hash | 2D render output hash | Identical across supposedly-different machines, or a hash that appears in known-automation datasets. |
| Fonts | Font list / metrics | A server/minimal font set, or the same set the stealth plugin injects everywhere → "the plugin is lying about fonts" is a CreepJS finding. |
| Timezone | `Intl` / `Date` offset vs IP geolocation | UA says US, clock/IP says UTC or a datacenter region → mismatch. |
| User-Agent vs UA-CH | `navigator.userAgent` and `Sec-CH-UA*` client hints | Old UA string with no/contradictory Client Hints, or UA brand that doesn't match what the engine actually is. Firefox sends no UA-CH; a Firefox UA with Chrome hints (or vice-versa) is a direct contradiction. |
| Permissions / plugins | `navigator.plugins.length`, `query()` for Notification | Headless often reports `0` plugins or inconsistent permission state. |
| Prototype integrity | CreepJS "lies" tab | Patched `Function.prototype.toString`, non-native getters → the stealth layer itself is the tell. |
| WebRTC | ICE local/public IP | Local IP leaking the datacenter subnet, or public IP differing from the HTTP IP. |
| Screen / window | `screen.*`, `outerWidth/Height` | `0` dimensions, or a window size inconsistent with the claimed device. |

### Interpreting common verdicts

- **Sannysoft** — each row is `pass` / `failed` / blank. Blank means "not
  applicable / could not run" (e.g. the Chrome-object row on Firefox). A
  Firefox/Camoufox lane legitimately *fails* the "Chrome (New)" row — that is
  not a leak, it means you are not Chrome. The rows that matter for a Firefox
  lane are **WebDriver**, **WebGL Vendor/Renderer**, and **languages**.
- **CreepJS** — wait for "FP ID: Computing…" to finish. Watch the **lies**
  count: any non-zero lie is a *contradiction the detector can see*. On a
  patched/stealth browser a *higher* lie count is worse, not better.
- **areyouheadless** — a single sentence. "You are not Chrome headless" is the
  pass. It is Chrome-specific; on Firefox/Camofox it will trivially "pass"
  because it is testing for a Chrome headless artifact — do not over-trust it
  as proof of Firefox privacy.
- **browserleaks.com/webgl** — compare **Vendor** and **Renderer**: if both are
  blank/`null` (the GPU-less case), that itself is a signal to a detector;
  see §3.
- **Interactive widget pages (NopeCHA)** — there is no "score". The result is
  **whether the widget resolves to a pass token without you solving anything**
  (managed/auto mode) or throws an interactive challenge. A page firing an
  endless challenge loop = detected.
- **Vendor behavior** — Cloudflare fronts a challenge when fingerprint + IP +
  request rhythm look automated; Turnstile in managed mode may pass silently.
  hCaptcha escalates to an image challenge. PerimeterX/HUMAN runs a JS
  sensor that scores behaviour and may silently soft-block (200 page with no
  content) rather than challenge. Treat "HTTP 200 but empty body / placeholder
  title" as a block (see `web-content-lanes.md` §"Block detection").

## 3. Camofox WebGL spoof on this box (GPU-less, no `/dev/dri`)

**The situation.** On this Replit host there is **no `/dev/dri`** (verified:
the path does not exist) — i.e. no GPU/render node. Camofox is patched
Firefox driven through `camoufox-js`. Upstream `camoufox-js` seeds the WebGL
fingerprint from a **live GPU sample** (`sampleWebGL`). With no GL context,
WebGL is `null`, and running the spoofer anyway **hangs the Firefox content
process** — every tab times out (`new page timed out`). Even the
`block_webgl: true` path hangs on this host.

**The fix (applied by `setup.sh --camofox`).** The installer **patches the
installed `camoufox-js`** (`dist/utils.js`) to *auto-detect* the missing GPU
and skip only the WebGL key seeding:

- Verified patch, camoufox-js **0.11.5**, in
  `…/node_modules/@askjo/camofox-browser/node_modules/camoufox-js/dist/utils.js`:
  ```js
  const _cfWebglEnv = process.env.CAMOFOX_SKIP_WEBGL_FP;
  const _cfNoGpu = !(existsSync("/dev/dri/renderD128") || existsSync("/dev/dri/card0"));
  if (_cfWebglEnv === "1" || (_cfWebglEnv !== "0" && _cfNoGpu)) { /* no WebGL spoof */ }
  else if (block_webgl || launch_options.allow_webgl === false) {
      firefox_user_prefs["webgl.disabled"] = true;
      LeakWarning.warn("block_webgl", i_know_what_im_doing);
  }
  else { /* full WebGL spoof seeded from the live GPU sample */ }
  ```
- A GL-capable host (a `/dev/dri/renderD128` or `/dev/dri/card0` node present)
  keeps the **full** spoof — no env var, no wrapper needed.

**Override.** Set `CAMOFOX_SKIP_WEBGL_FP` to force the choice:

- `CAMOFOX_SKIP_WEBGL_FP=1` → always skip the WebGL spoof (even on a GPU host).
- `CAMOFOX_SKIP_WEBGL_FP=0` → always attempt the spoof (only safe on a GL host;
  on this GPU-less box it will hang the content process).

**Why this trade is acceptable.** It touches the **WebGL vector only**, and
only where WebGL cannot actually render. Every other fingerprint vector — UA,
fonts, canvas seeds, screen, navigator fields, WebRTC — is untouched. The
practical detection cost: on this host `UNMASKED_VENDOR_WEBGL` /
`UNMASKED_RENDERER_WEBGL` are absent/`null`, which is itself a mild GPU-less
tell; a site that *requires* a WebGL renderer string will notice. That is the
price of a box with no `/dev/dri`, and it is far cheaper than a lane that never
loads a page.

## 4. "How do I know MY browser is anti-bot?" — walkthrough

Run these in order. The first three are read-only and need no login; the last
is the real-world confirmation.

1. **WebDriver + basic table.** Open `https://bot.sannysoft.com/` in the lane
   under test. Expect **no `failed` on WebDriver** rows. On a Firefox/Camofox
   lane, ignore the Chrome-object rows.
   - *Camofox:* `POST /tabs` to the URL, then read the page via
     `GET /tabs/<id>/snapshot?userId=<u>` or
     `POST /tabs/<id>/evaluate` (see `web-content-lanes.md` §"Reading content").
2. **Contradictions.** Open `https://abrahamjuliot.github.io/creepjs/`, wait
   for "FP ID: Computing…" to finish, and check the **lies** tab. **Zero
   lies** is the goal. Any lie is a visible inconsistency.
3. **Raw GPU/font/timezone.** Open `https://browserleaks.com/webgl`,
   `…/fonts`, `…/canvas`. Confirm:
   - WebGL renderer is either a plausible GPU string **or** an explained
     `null` (on this box, `null` is expected — §3).
   - The timezone matches the IP's region (cross-check on
     `https://browserleaks.com/javascript`).
   - UA and UA-CH do not contradict (Firefox should send no UA-CH).
4. **Headless artifact.** Open `https://arh.antoinevastel.com/bots/areyouheadless`.
   Read the one-line verdict. (Chrome-specific; a pass is necessary, not
   sufficient, for Firefox.)
5. **Aggregate bot verdict.** Open `https://deviceandbrowserinfo.com/are_you_a_bot`
   and expand **Raw detection details** — confirm the flagged signals are only
   the ones you have consciously accepted (e.g. the GPU-less WebGL null).
6. **Fingerprint stability.** Open `https://fingerprint-scan.com/` and note
   the fingerprint hash; reload. A **stable hash across reloads** means the
   lane presents a consistent identity (good). A hash that changes every load
   on a supposedly-persistent profile is its own tell.
7. **Real-world gate (Cloudflare + hCaptcha).** Open the NopeCHA demos:
   `https://nopecha.com/demo/turnstile` and `…/demo/hcaptcha`. A pass is the
   widget resolving **without an interactive challenge**. Then hit a real
   Cloudflare-fronted site and look for `httpStatus: 200, navigationOk: true`;
   a `403` with a `__cf_chl_rt_tk` token is a challenge (retry the same
   `sessionKey` so the clearance cookie is reused — `web-content-lanes.md`).
8. **Vendor-grade check.** Open `https://demo.fingerprint.com/` — this is how
   a paid vendor (FingerprintJS) sees the session. Useful as the "expensive"
   end of the spectrum.

**Reading the overall result.** There is no single green light. A lane is
"anti-bot enough" when: WebDriver is absent, CreepJS lies = 0, the only
accepted loss is the documented GPU-less WebGL null (§3), the fingerprint hash
is stable, and the Cloudflare/Turnstile widget passes without an interactive
challenge. Anything short of that is a leak you can see before a vendor does.