# Browser lane comparison — full run (2026-10-07)

Every lane exercised live on this box. Read-only probes: page loads + a
`navigator.webdriver` / headless-UA check. No destructive operations.

## Results

| Lane | Entry point | Version | example.com | `navigator.webdriver` | headless UA token | WebGL | Stealth |
|---|---|---|---|---|---|---|---|
| **L1** Replit Playwright Chromium | `$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE` (self-contained wrapper) | Chromium 140.0.7339.16 | ✅ Example Domain | n/m¹ | yes (`HeadlessChrome`) | ✗ null | ✗ |
| **L2** Hermes Chrome | `.hermes/tools/chromium-1208/…/chrome` + `resolve-libs.sh` | Chrome for Testing 145.0.7632.6 | ✅ Example Domain | **true**² | **true** | ✅ w/ `--enable-unsafe-swiftshader` | ✗ |
| **L3** agent-browser | `.hermes/tools/agent-browser-0.26.0-linux-x64/bin/agent-browser-linux-x64` (drives L2 over CDP) | 0.26.0 | ✅ Example Domain | **true**² | **true** | inherits L2 | ✗ |
| **L4** Camofox | `:9377` `@askjo/camofox-browser` → camoufox-bin | Firefox/Gecko 152.0.4 (camoufox) | ✅ httpStatus 200 | **false** | **no** (`Firefox/152.0`) | ✗ null | ✅ |

¹ L1 `--dump-dom` with a `data:` URL produced no title (the flag snapshots
before the script runs); its load of example.com returned the correct title.
Standard CDP behavior is `webdriver=true`, same as L2/L3.

² Measured through a real CDP session: agent-browser driving Chrome 145
reported `navigator.webdriver = true` and a `Headless` UA token. Plain
`--dump-dom` runs (not automation-driven) report exactly the flag passed.

## What this proves

- **Only L4 (Camofox) is not flagged as a bot**: `webdriver=false`, a real
  `Firefox/152.0` UA, no `Headless` token. L1–L3 are plain Chromium/Chrome and
  are detectable (Cloudflare/Akamai-class walls will 403 them).
- **WebGL is available only on L2/L3** (Chrome + `--enable-unsafe-swiftshader`);
  L1 and L4 are `null` on this GPU-less host (`/dev/dri` absent).

## Real integration findings (bugs found by running, not reading)

- **L3 drops `LD_LIBRARY_PATH`.** Pointing `AGENT_BROWSER_EXECUTABLE_PATH` at
  the bare Hermes chrome fails with `libnspr4.so: cannot open shared object
  file` — agent-browser spawns Chrome without the caller's env. A one-line
  wrapper that exports the closure then `exec`s chrome fixes it (this is why
  `setup.sh --hermes-browser` writes `launch-hermes-chrome`). Verified:
  `✓ Example Domain` and `document.title → "Example Domain"`.
- **L1 is self-contained.** The Replit Playwright Chromium is a wrapper that
  execs a bundled binary with its own cert/font env — it needs **no**
  `LD_LIBRARY_PATH`, so it is the zero-setup default.
- **L2 needs name-resolved libs.** The Hermes build has no RUNPATH; the closure
  must be resolved per machine (`resolve-libs.sh`), because the
  `/nix/store/<hash>` differs between hosts (and a 32-bit `nspr` copy gives
  `wrong ELF class: ELFCLASS32`).
- **Camofox `/health` + `/tabs` + `/tabs/<id>/evaluate` all work**, returning a
  coherent stealth fingerprint from a cold profile.

## Caveats

- The third-party anti-bot page `arh.antoinevastel.com/bots/areyouheadless`
  returned **502** through Camofox in this run (site flaky / blocking the
  datacenter IP) — not a lane failure; the `webdriver` probe above is the
  reliable signal. See `anti-bot-detection.md` for the full test-site list.
- L3's `webdriver=true` is inherited from L2's Chrome; agent-browser has no
  stealth layer of its own.
- No real WAF (Cloudflare challenge / PerimeterX) was driven end-to-end here.

## Which lane when

1. **L1** — default scripted Chromium, zero setup (no WebGL).
2. **L2/L3** — when you need Chrome 145, WebGL, or agent-driven interaction
   (`agent-browser snapshot -i`); must use the resolved closure / wrapper.
3. **L4 (Camofox)** — anything bot-walled or requiring a Firefox fingerprint.

*(CLIProxyAPI is not a browser lane — it bridges OAuth CLI subscriptions to an
OpenAI/Claude-compatible API on `:8317`; it was not part of this run.)*