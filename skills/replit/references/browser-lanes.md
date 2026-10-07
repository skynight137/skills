# Browser-automation lanes on this Replit box — measured

Four independent browser lanes exist here. All figures below are copied from
live runs on this box (headless, no `/dev/dri`, no GPU; `DISPLAY=:0` is set
but no X server is required for any lane). Where something could not be tested
it says so.

Related refs: `references/playwright-chromium.md` (lane 1 detail),
`references/camofox.md` (lane 4 detail), `references/platform.md` (Nix/`$HOME`
gotchas), `references/web-content-lanes.md` (coarse lane picker).

> Discrepancy found: `web-content-lanes.md` cites Camofox on `:8008`. The
> running server on this box answers on **`:9377`** (verified below).

---

## Lane 1 — Replit Playwright Chromium (version 1187)

- **Path (env var):** `$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE` =
  `/nix/store/71577rskzyhch3axhdqx7faygc2xyn4v-playwright-browsers-1.55.0-with-cjk/chromium-1187/chrome-linux/chrome`
- **What it actually is:** a 438-byte **bash wrapper** (mode `r-xr-xr-x`,
  immutable Nix store path). It exports `SSL_CERT_FILE` + `FONTCONFIG_FILE`
  and `exec`s the real 459 MB binary
  `/nix/store/d7y5039fgn5432kgkn0cv09hda4a7nxz-playwright-chromium-cjk-1.55.0-1187/chrome-linux/.chrome-wrapped`
  with `--disable-features=VizDisplayCompositor --font-render-hinting=none`.
- **`--version` (observed):** `Chromium 140.0.7339.16`
- **`--help` (observed):** `No manual entry for chrome` (Chromium has no
  `--help` text; it delegates to `man`). Real flags: `--headless=new`,
  `--no-sandbox`, `--disable-gpu`, `--dump-dom`, `--virtual-time-budget=NNNN`.
- **Engine:** Chromium (Blink), the CJK-font Playwright build.
- **Invoke:**
  ```bash
  "$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE" --headless=new --no-sandbox \
    --disable-gpu --dump-dom https://example.com 2>/dev/null \
    | grep -o "<title>[^<]*</title>"
  ```
  From Python: `p.chromium.launch(executable_path=os.environ["REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE"], ...)`.
- **Display/GPU:** none needed. Runs fully headless.
- **Anti-bot:** plain Chromium. UA in my `--dump-dom` run was
  `…HeadlessChrome/140.0.0.0…` and `navigator.webdriver` was `false` **only
  because that run was not CDP-driven**. Under Playwright/CDP automation
  `navigator.webdriver` becomes `true` and the `HeadlessChrome` token stays —
  **not stealthy**, expect 403s on Cloudflare/Akamai-tier sites.
- **VERIFIED load:** `--dump-dom https://example.com` →
  `<title>Example Domain</title>`, full multilingual body rendered, exit 0.
  (stderr carries harmless dbus/GLib noise.)

## Lane 2 — Hermes bundled Chromium (version 1208)

- **Path:** `/home/runner/workspace/.hermes/tools/chromium-1208/chrome-linux64/chrome`
  (269.7 MB, regular file, writable).
- **What it is:** "Google Chrome for Testing" build, pinned by Hermes'
  `facts.json` (`chromium` → `1208+145.0.7632.6`). Hermes exports it as
  `AGENT_BROWSER_EXECUTABLE_PATH` and points `PLAYWRIGHT_BROWSERS_PATH` at the
  tools store.
- **`--version` (observed):** `Google Chrome for Testing 145.0.7632.6`
  ⚠ **only with `LD_LIBRARY_PATH` set** — the raw binary fails with
  `libnspr4.so: cannot open shared object file`. It has no RPATH.
- **`--help` (observed):** `No manual entry for chrome`.
- **Engine:** Chromium/Chrome (Blink) 145.
- **Invoke** (resolve the closure on THIS machine — store hashes are NOT
  portable between hosts, so never copy a `/nix/store/...` path):
  ```bash
  # resolve soname -> nixpkgs attr -> store root, then export the closure
  bash skills/replit/scripts/setup/resolve-libs.sh /tmp/chromium-closure.txt chromium
  export LD_LIBRARY_PATH="$(cat /tmp/chromium-closure.txt)"
  /home/runner/workspace/.hermes/tools/chromium-1208/chrome-linux64/chrome \
    --headless=new --no-sandbox --disable-gpu --dump-dom https://example.com
  # or just use the generated shim (setup.sh --hermes-browser writes it):
  launch-hermes-chrome --version
  ```
  Missing libs (from `ldd`): `libnspr4.so libnss3.so libnssutil3.so
  libsmime3.so libxkbcommon.so.0 libgbm.so.1`. The resolver picks the **64-bit**
  store copy automatically — this box also has 32-bit copies and a hand-picked
  one gives `wrong ELF class: ELFCLASS32`. Hermes itself wires the full closure
  via `sandbox_host.py`, so `agent-browser`/`browser_exec` usually get this for
  free; `setup.sh --hermes-browser` makes a bare invocation work too.
- **Display/GPU:** none needed.
- **Anti-bot:** same as lane 1 — stock Chrome for Testing, `HeadlessChrome`
  token + `navigator.webdriver=true` under CDP. **Not stealthy.**
- **VERIFIED load:** `--dump-dom https://example.com` →
  `<title>Example Domain</title>`, exit 0.

## Lane 3 — Hermes `agent-browser` CLI (0.26.0)

- **Path:** `/home/runner/workspace/.hermes/tools/agent-browser-0.26.0-linux-x64/bin/agent-browser-linux-x64`
  (10.9 MB native binary; `agent-browser.js` next to it is only a cross-platform
  Node shim for npx/Windows. Install method recorded as `pnpm`.)
- **`--version` (observed):** `agent-browser 0.26.0`
- **`--help` (observed, first lines):**
  ```
  agent-browser - fast browser automation CLI for AI agents
  Usage: agent-browser <command> [args] [options]
  Start here (for AI agents):  agent-browser skills get core --full
  ```
  Core commands: `open click dblclick type fill press hover focus check
  uncheck select drag upload download scroll scrollintoview wait screenshot
  pdf snapshot eval connect close`, plus `back forward reload`, `skills
  [list|get|path]`, sessions/tabs.
- **Engine:** drives **Chrome/Chromium over CDP** (browser, not its own
  engine). On this box it uses lane 2's Chrome 145 via
  `AGENT_BROWSER_EXECUTABLE_PATH`, so its version is the Chrome behind it.
- **Invoke:**
  ```bash
  export AGENT_BROWSER_EXECUTABLE_PATH=/home/runner/workspace/.hermes/tools/chromium-1208/chrome-linux64/chrome
  AB=/home/runner/workspace/.hermes/tools/agent-browser-0.26.0-linux-x64/bin/agent-browser-linux-x64
  $AB open https://example.com      # -> ✓ Example Domain
  $AB snapshot -i                   # accessibility tree with @eN refs
  $AB eval "document.title"         # -> "Example Domain"
  $AB close --all
  ```
  Bundled skills: `core dogfood electron slack agentcore vercel-sandbox`
  (`agent-browser skills get core --full`).
- **Display/GPU:** none (`--headless`). Inherits Chrome 145's GPU story,
  i.e. WebGL via SwiftShader if the underlying Chrome is launched with
  `--enable-unsafe-swiftshader`.
- **⚠ LD_LIBRARY_PATH is dropped.** agent-browser spawns Chrome with a clean env, so pointing `AGENT_BROWSER_EXECUTABLE_PATH` at a bare Hermes chrome fails with `libnspr4.so: cannot open shared object file`. Use the generated `launch-hermes-chrome` shim (or any wrapper that exports the resolved closure then `exec`s chrome) as the executable path.
- **Anti-bot:** inherits the plain-Chrome fingerprint — **not stealthy**.
- **VERIFIED load:** `open https://example.com` → `✓ Example Domain`
  (https://example.com/); `eval "document.title"` → `"Example Domain"`.

## Lane 4 — Camofox server (:9377)

- **Server:** `camofox-browser` = npm global `@askjo/camofox-browser` **1.18.1**,
  invoked as `node /home/runner/workspace/.local/share/node/bin/camofox-browser`
  (symlink → `…/lib/node_modules/@askjo/camofox-browser/bin/camofox-browser.js`).
  Also `camofox-browser-mcp` (stdio MCP adapter, 11 `camofox_*` tools).
- **Engine binary:** `/home/runner/workspace/.cache/camoufox/camoufox-bin`,
  a **patched Firefox** (camoufox-js).
  `camoufox-bin --version` → `Camoufox Camoufox 152.0.4-beta.30`;
  `version.json` → `{"version":"152.0.4","release":"beta.30"}` (Gecko 152).
- **API (observed live):** `http://127.0.0.1:9377`
  - `GET /health` →
    `{"ok":true,"engine":"camoufox","browserConnected":true,"browserRunning":true,"activeTabs":N,"consecutiveFailures":0,"memory":{...}}`
  - `POST /tabs` with JSON `{"userId","sessionKey","url"}` →
    `{"tabId":"…","url":"https://example.com/","httpStatus":200,"navigationOk":true}`
  - `GET /tabs?userId=…&sessionKey=…` lists tabs (with `title`).
  - `POST /tabs/<tabId>/evaluate` `{"userId","expression"}` → `{ok,result}`.
- **Invoke:**
  ```bash
  # server is normally already running; if not, source the closure first:
  # (current layout: $XDG_CONFIG_HOME/camofox/env.sh; older installs used
  #  $XDG_DATA_HOME/camofox/env.sh — setup.sh --camofox migrates it)
  bash -c '. "${XDG_CONFIG_HOME:-$HOME/.config}/camofox/env.sh"; exec camofox-browser' &
  curl -s http://127.0.0.1:9377/health
  curl -s -m 90 -X POST http://127.0.0.1:9377/tabs \
    -H 'Content-Type: application/json' \
    -d '{"userId":"me","sessionKey":"s1","url":"https://example.com/"}'
  ```
  `env.sh` puts the pruned Nix closure on `LD_LIBRARY_PATH` (GTK etc.). A bare
  `camofox-browser` in a shell that never sourced it dies with
  `libgtk-3.so.0: cannot open shared object file`.
- **Display/GPU:** none — headless Firefox.
- **Anti-bot:** the **only stealth lane.** A live evaluate returned
  `ua="Mozilla/5.0 (X11; Linux x86_64; rv:152.0) Gecko/20100101 Firefox/152.0"`,
  `navigator.webdriver=false`, `platform="Linux x86_64"`, `lang="en-US"` —
  a coherent non-headless-looking Firefox fingerprint (no `HeadlessFirefox`
  token). Camoufox randomizes/spoofs the fingerprint; from a cold profile a
  Cloudflare site may 403 once, then succeed on retrying the **same
  sessionKey** (see `web-content-lanes.md`).
- **VERIFIED load:** `POST /tabs {…,"url":"https://example.com/"}` →
  `httpStatus 200, navigationOk true`; `GET /tabs` then reported
  `title:"Example Domain"`. Data flows through the API.

---

## Comparison

| | L1 Playwright Chromium | L2 Hermes Chrome | L3 agent-browser | L4 Camofox |
|---|---|---|---|---|
| Binary/entry | `$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE` (wrapper) | `.hermes/tools/chromium-1208/…/chrome` | `.hermes/tools/agent-browser-0.26.0-…/bin/agent-browser-linux-x64` | `:9377` server (`@askjo/camofox-browser` 1.18.1) |
| Version | Chromium 140.0.7339.16 | Chrome-for-Testing 145.0.7632.6 | agent-browser 0.26.0 (drives Chrome 145) | Firefox/Gecko 152.0.4 (Camoufox) |
| Engine | Blink | Blink | CDP over Chrome | Gecko |
| Works out of box | ✅ | ⚠ needs `LD_LIBRARY_PATH` | ✅ | ✅ (server pre-running) |
| Extra deps | none | nspr4/nss3/nssutil3/smime3/xkbcommon.0/gbm.1 (64-bit!) | lane 2's libs | `env.sh` closure |
| Headless/no-GPU | ✅ | ✅ | ✅ | ✅ |
| WebGL | ❌ NULL (even w/ swiftshader flags) | ✅ w/ `--enable-unsafe-swiftshader` | inherits Chrome → ✅ w/ flag | ❌ NULL |
| Stealth | ❌ plain | ❌ plain | ❌ plain | ✅ camoufox |
| Programmatic API | Python/Node Playwright | same | CLI (+skills) | REST + MCP |
| Verified title | Example Domain | Example Domain | Example Domain | Example Domain |

## Which lane when

- **L1 — default scripted Chromium.** Cheapest, zero setup, and the env var is
  already there. Use it for ordinary scraping, forms, and Playwright tests.
  Can't do WebGL.
- **L2 — when you specifically need Chrome 145 / a specific modern Chrome, or
  the fuller `agent-browser`/`browser_exec` stack under the hood.** Remember
  the `LD_LIBRARY_PATH` (pick the **64-bit** nix paths). Use it if you need
  WebGL/SwiftShader rendering.
- **L3 — agent-driven interaction.** Best for AI-agent workflows: `snapshot -i`
  gives a compact accessibility tree with `@eN` refs, bundled `core`/`electron`
  skills. Not a distinct engine — it's Chrome 145 via CDP.
- **L4 — anti-bot / bot-walled sites.** The only lane with a real stealth
  fingerprint (patched Firefox, `navigator.webdriver=false`, spoofed
  fingerprint). Slowest to cold-start; retry the same `sessionKey` if a
  Cloudflare front-door 403s.

### Could not test / caveats

- **L1 WebGL** is a hard negative: `WEBGL_NULL` with `--enable-unsafe-swiftshader`,
  `--use-gl=angle --use-angle=swiftshader`, and `--use-gl=swiftshader` all
  failed; `--in-process-gpu` produced no output at all. Something in the
  Playwright CJK build's GPU stack refuses a software GL context here.
- **L4 WebGL:** `WEBGL_NULL` in the running camoufox tab (Firefox, no GPU).
- **L1/L2 stealth** was only observed in non-CDP `--dump-dom` runs; the
  `navigator.webdriver=true`-under-Playwright claim is from standard CDP
  behavior, not a measured CDP run in this session.
- **L3 WebGL** not measured directly — inferred from it driving L2's Chrome.
- No lane was exercised against a real WAF site in this session; the
  Cloudflare-retry claim is quoted from `web-content-lanes.md`, not re-verified
  here.
- GPU: `/dev/dri` does not exist; every lane ran CPU-only. `DISPLAY=:0` was set
  but no X server was needed.