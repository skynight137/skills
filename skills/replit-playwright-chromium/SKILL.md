---
name: replit-playwright-chromium
description: "Playwright (Chromium) on Replit without any browser download: Replit ships a Playwright-managed Chromium in the Nix store at $REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE. Use when playwright install fails/hangs, or when you need headless Chromium via executable_path or a CDP daemon."
version: 2.1.0
license: MIT
platforms: [linux]
compatibility: "Replit sandbox with $REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE set; Python 3 + pip (or venv)."
metadata:
  hermes:
    tags: [Playwright, Chromium, Replit, executable_path, CDP, headless]
    related_skills: [replit-nix, replit-knowledge, camofox-on-replit]
---

# Playwright (Chromium) on Replit — no download

Replit ships a **Playwright-managed Chromium** in the Nix store, exposed as
`$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE`. `playwright install` (which only
downloads a browser) is both unnecessary and broken here — point Playwright
at the store browser with `executable_path` and be done.

If you need Firefox-level anti-detection instead of Chromium, use the
**`camofox-on-replit`** skill. Replit platform gotchas ($HOME wipes,
XDG persistence, registry firewall) live in the **`replit-knowledge`**
skill; Nix/closure mechanics live in **`replit-nix`**.

## The 4 steps

```bash
# 1. The browser is already there — verify it runs:
export CHROME="$REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE"
"$CHROME" --headless=new --no-sandbox --disable-gpu \
  --dump-dom https://example.com 2>/dev/null | grep -o "<title>.*</title>"
# -> <title>Example Domain</title>   (dbus/gcm/GLib stderr noise is harmless)

# 2. Install ONLY the Python package (never `playwright install`):
pip install playwright          # pip missing? python3 -m venv .venv && .venv/bin/pip install playwright

# 3. Launch it (standalone script):
python - <<'EOF'
import asyncio, os
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(
            executable_path=os.environ["REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE"],
            headless=True,
            args=["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
        )
        page = await b.new_page()
        await page.goto("https://example.com")
        print("title:", await page.title())
        await b.close()

asyncio.run(main())
EOF

# 4. (agent/CDP use) daemon it on :9222 for any CDP client:
"$CHROME" --headless=new --no-sandbox --disable-gpu \
  --remote-debugging-port=9222 \
  --user-data-dir="${XDG_DATA_HOME:-$HOME/.local/share}/chromium/default" about:blank &
curl -s http://127.0.0.1:9222/json/version   # -> "Browser":"Chrome/..." + ws URL
```

`--no-sandbox` is **required** (no usable setuid sandbox in the container).
`executable_path` must be the **expanded absolute path** (env var, not `$VAR`
string). The store `chrome` is a ~438-byte launcher script, not an ELF —
normal, run it as-is.

## CDP daemon: on-demand, not always-on

Run the :9222 daemon only while you need it; kill it when the task is done.
Do NOT schedule it on cron — the container dies and nothing restarts it.
`scripts/ensure_browser.sh` is the idempotent launcher (no-op if the port is
already live); it drives the store browser **only** — there is deliberately
no fallback to any other browser on PATH.

**Where Chromium keeps data.** The store launcher does not set a profile
dir, so an unmanaged launch uses Chromium's default:
`$XDG_CONFIG_HOME/chromium` — on Replit that's pre-set to
`$REPL_HOME/.config/chromium`, i.e. **workspace** (persists; `$HOME` is wiped
on recreate). `ensure_browser.sh` passes an explicit `--user-data-dir`
instead: `$CHROME_DATA_DIR` (default `$XDG_DATA_HOME/chromium/default`).

**Multiple agents sharing one sandbox.** Chromium locks `--user-data-dir`
(`SingletonLock`) — two instances can NEVER share one profile dir; the
second either fails or refuses the lock. Never share; run one daemon per
agent with its own port and data dir:

```bash
CHROME_PORT=9223 CHROME_DATA_DIR="$XDG_DATA_HOME/chromium/agent-b" \
    bash scripts/ensure_browser.sh
```

## Pitfalls

- **Never `playwright install`** on Replit — it only downloads (and fails
  under the registry firewall). The browser is in the Nix store.
- **Registry firewall:** plain `pip install` uses the pinned PyPI index; if
  a mirror 404s, `export PIP_INDEX_URL=https://pypi.org/simple/`. (npm
  equivalent: see `replit-knowledge`.)
- **`LD_LIBRARY_PATH`:** usually unnecessary — the Nix `chrome` wrapper
  points at its own store. Only touch it if you see `cannot open shared
  object file`, and then use the closure method from `replit-nix` §3, never
  a hand-picked partial list.
- Playwright scripts and CDP are independent lanes to the same browser;
  neither needs `agent-browser` or any other npm driver.

## Verification

- Step 1 prints the Example Domain title (store browser launches).
- Step 3 prints a real `page.title()` (Playwright→store-browser wiring).
- Step 4: `/json/version` returns a ws URL and any CDP client loads a page.

## Files in this skill

- `scripts/ensure_browser.sh` — idempotent, on-demand CDP daemon launcher
  (source of truth for the :9222 launch line; per-agent `CHROME_PORT` /
  `CHROME_DATA_DIR` overrides).
- `scripts/monitor.sh`, `scripts/browser_monitor.py` — the opt-in :5000
  screenshot relay (`monitor.sh on` → `https://$REPLIT_DOMAINS:5000`,
  off by default).
