#!/usr/bin/env python3
"""lp-tour.py — Lightpanda keepalive tour (fleet session keep-alive).

Sequential stops over LP_LINKS: for each project URL, spawn ONE fresh
`lightpanda serve`, open the page logged-in (cookie jar), hold it for
the dwell, close everything, move to the next stop. A round is
len(LINKS) x (DWELL + GAP); that open cadence — not any in-tab
refresh — is what holds a fleet of Replit workspaces inside their
idle tolerance. See references/lightpanda.md for the mechanics and
references/session-keepalive.md for the engine comparison.

Proven shape (jafibaw wing trial, 2026-11-06; generalized from the
trial program that ran it — mechanics unchanged):
  * one fresh server per stop, torn down after the stop: Lightpanda
    has zero idle cost, so there is no resident server to keep warm;
  * the server's stdout/stderr go to a per-stop log FILE, never a
    pipe — an undrained PIPE wedges the server silently;
  * cookies plant ONLY via the server's native --cookie loader, with
    the jar converted to a CDP cookie array. Playwright's
    Storage.setCookies FAILS against Lightpanda (BrowserContextNot-
    Loaded) — do not "fix" this by switching to CDP planting;
  * navigation always goes through a fresh ctx.new_page(): the
    default CDP page is a non-navigable startup session;
  * the jar is re-converted every round, so a re-imported jar is
    picked up without restarting the tour.

Verdicts per stop: SHELL / LOGGED-OUT-WALL (visible text contains
both "Log in" and "Sign up", confirmed by a second probe 5s later —
the camofox --fail-text discipline) / CF-STALL (poll budget spent on
the "Just a moment..." title; Cloudflare normally clears by itself
in ~7-18s) / ERROR / UNKNOWN. After a SHELL verdict the tab is held
for the full dwell and re-probed: still-shell is logged.
Circuit breaker: TOUR_MAX_EARLY_FAILURES CONSECUTIVE non-SHELL stops
abort the tour (`*** tour ABORTED`, exit 1); a SHELL stop resets the
count.

Config (fleet "big env" rule: a var already set in the system
environment WINS; the .env file only fills gaps; the source of every
var is logged at startup, name + source only):
  file      $LIGHTPANDA_HOME/.env  (LIGHTPANDA_ENV_FILE overrides)
  LP_LINKS            required: comma/whitespace-separated project URLs
  LP_COOKIES          cookie jar, browser-export or Playwright format
                      (default $LIGHTPANDA_HOME/cookies.json)
  TOUR_DWELL_S        seconds the tab is held per stop   (default 60)
  TOUR_GAP_S          sleep between stops, tab closed    (default 0)
  TOUR_MAX_EARLY_FAILURES  circuit breaker, 0 = never    (default 3)
  LP_POLL_S           budget for the shell marker        (default 150)
  LP_BASE_PORT        first CDP port; stop i uses +i     (default 19401)
  LP_MAX_ROUNDS       0 = tour forever                   (default 0)
  LP_ONLY             run only the stop with this last path segment
  LIGHTPANDA_HOME     install/state root (default $XDG_CONFIG_HOME/lightpanda)
  LIGHTPANDA_BIN      engine binary (default $LIGHTPANDA_HOME/lightpanda,
                      then `lightpanda` on PATH)

Run via lp-tour.sh (it assembles LD_LIBRARY_PATH + the venv python).
`lp-tour.py --check` resolves and prints the config, probes the
binary and jar, and exits without opening anything.
"""
import asyncio, json, os, shutil, signal, socket, subprocess, sys, time, urllib.request

# ── config ─────────────────────────────────────────────────────────────
# LIGHTPANDA_HOME itself resolves from the system env only: the .env
# file lives inside it, so the file cannot move its own home.
_HOME = os.environ.get("LIGHTPANDA_HOME") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "lightpanda")
ENV_FILE = os.environ.get("LIGHTPANDA_ENV_FILE") or os.path.join(_HOME, ".env")


def _load_env_file(path):
    """KEY=VALUE lines from the .env file (no expansion, quotes stripped)."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                out[k.strip()] = v
    except FileNotFoundError:
        pass
    return out


_FILE_ENV = _load_env_file(ENV_FILE)
CONFIG_SOURCES = []


def cfg(name, default=""):
    """System env wins; .env fills gaps; the default is last. The
    resolution is logged (name + source only, never the value of a
    secret-bearing var — none of these are secret, but the habit is
    the fleet rule)."""
    if os.environ.get(name):
        CONFIG_SOURCES.append(f"{name}: from system env (.env file skipped)")
        return os.environ[name]
    if _FILE_ENV.get(name):
        CONFIG_SOURCES.append(f"{name}: from .env file ({ENV_FILE})")
        return _FILE_ENV[name]
    CONFIG_SOURCES.append(f"{name}: from default")
    return default


def cfg_int(name, default):
    raw = cfg(name, str(default))
    try:
        return int(raw)
    except ValueError:
        print(f"config: {name}={raw!r} is not an integer — using {default}",
              flush=True)
        return default


HOME = cfg("LIGHTPANDA_HOME", _HOME)
BIN = cfg("LIGHTPANDA_BIN") or os.path.join(HOME, "lightpanda")
if not os.path.exists(BIN):
    BIN = shutil.which("lightpanda") or BIN
JAR = cfg("LP_COOKIES", os.path.join(HOME, "cookies.json"))
ARRAY = os.path.join(HOME, ".jar-array.json")
LOG_DIR = cfg("LP_LOG_DIR", os.path.join(HOME, "logs"))

DWELL = cfg_int("TOUR_DWELL_S", 60)
GAP = cfg_int("TOUR_GAP_S", 0)
BREAKER = cfg_int("TOUR_MAX_EARLY_FAILURES", 3)
POLL = cfg_int("LP_POLL_S", 150)
BASE_PORT = cfg_int("LP_BASE_PORT", 19401)
MAX_ROUNDS = cfg_int("LP_MAX_ROUNDS", 0)
ONLY = cfg("LP_ONLY", "")

LINKS = [u for u in cfg("LP_LINKS", "").replace(",", " ").split() if u]
if ONLY:
    LINKS = [u for u in LINKS if u.rsplit("/", 1)[-1] == ONLY]

# ── logs: severity-coloured, always on (house style). The message text
# stays plain inside the colour span so grep on the log keeps working.
C_INFO, C_OK, C_WARN, C_ERR, C_DIM, C_RST = (
    "\033[0;36m", "\033[0;32m", "\033[1;33m", "\033[1;31m", "\033[2m", "\033[0m")


def log(msg, color=C_INFO):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"{color}{ts} {msg}{C_RST}", flush=True)


CURRENT_SRV = None  # live lightpanda Popen, for signal cleanup


def convert_jar():
    """Cookie jar (browser-export or Playwright format) -> CDP cookie
    array file for the native --cookie loader. Returns the cookie
    count. Re-run every round so a re-imported jar is picked up
    without a tour restart."""
    raw = json.load(open(JAR))
    items = raw.get("cookies", raw) if isinstance(raw, dict) else raw
    out = []
    for c in items:
        if "name" not in c or "value" not in c:
            continue
        nc = {"name": c["name"], "value": c["value"],
              "domain": c.get("domain", ".replit.com"),
              "path": c.get("path", "/")}
        if c.get("expires"):
            try:
                nc["expires"] = float(c["expires"])
            except Exception:
                pass
        if c.get("secure") is not None:
            nc["secure"] = bool(c["secure"])
        if c.get("httpOnly") is not None:
            nc["httpOnly"] = bool(c["httpOnly"])
        out.append(nc)
    fd = os.open(ARRAY, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(out, f)
    return len(out)


def rss_mb(pid):
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            if line.startswith("Rss:"):
                return int(line.split()[1]) // 1024
    except Exception:
        pass
    return 0


def lightpanda_pids():
    r = subprocess.run(["pgrep", "-f", "lightpanda serve"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return []
    return [int(x) for x in r.stdout.split() if x.strip().isdigit()]


def kill_leftovers(context):
    for pid in lightpanda_pids():
        log(f"leftover lightpanda pid={pid} killed ({context})", C_WARN)
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass


def port_free(port):
    s = socket.socket()
    try:
        return s.connect_ex(("127.0.0.1", port)) != 0
    finally:
        s.close()


async def body_text(page):
    try:
        return await asyncio.wait_for(page.inner_text("body", timeout=3000), 10)
    except Exception:
        return ""


async def run_stop(idx, url):
    """One tour stop. Returns (verdict, time_to_shell_s, rss_peak_mb)."""
    global CURRENT_SRV
    name = url.rsplit("/", 1)[-1]
    port = BASE_PORT + idx
    t0 = time.time()
    rss_peak = 0
    verdict, shell_at = "UNKNOWN", None

    kill_leftovers(f"pre-stop {name}")
    for _ in range(20):
        if port_free(port):
            break
        await asyncio.sleep(0.5)

    os.makedirs(LOG_DIR, exist_ok=True)
    srvlog = open(os.path.join(LOG_DIR, f"lp-server-{name}.log"), "ab")
    srv = subprocess.Popen(
        [BIN, "serve", "--host", "127.0.0.1", "--port", str(port),
         "--cookie", ARRAY],
        stdout=srvlog, stderr=srvlog)
    CURRENT_SRV = srv
    log(f"stop {name}: server pid={srv.pid} port={port} url={url}")
    try:
        up = False
        for _ in range(30):
            try:
                with urllib.request.urlopen(
                        f"http://127.0.0.1:{port}/json/version", timeout=2) as r:
                    r.read()
                up = True
                break
            except Exception:
                await asyncio.sleep(0.5)
        if not up:
            log(f"stop {name}: server HTTP never came up", C_ERR)
            return "ERROR", None, rss_peak

        from playwright.async_api import async_playwright
        async with async_playwright() as p:
            browser = await asyncio.wait_for(
                p.chromium.connect_over_cdp(f"http://127.0.0.1:{port}"), 30)
            ctx = browser.contexts[0] if browser.contexts \
                else await browser.new_context()
            page = await ctx.new_page()  # default CDP page is non-navigable
            try:
                await asyncio.wait_for(
                    page.goto(url, wait_until="domcontentloaded"), 60)
            except Exception as e:
                log(f"stop {name}: goto exc {type(e).__name__} "
                    f"{str(e)[:120]} (continuing to poll)", C_WARN)

            markers = ["Files", "Invite", "Console", "Shell",
                       "Personal workspace", name]
            deadline = time.time() + POLL
            last_title = None
            while time.time() < deadline:
                try:
                    title = await asyncio.wait_for(page.title(), 10)
                except Exception:
                    title = "?"
                if title != last_title:
                    log(f"stop {name}: title -> {title!r}", C_DIM)
                    last_title = title
                rss_peak = max(rss_peak, rss_mb(srv.pid))
                text = await body_text(page)
                if "Log in" in text and "Sign up" in text:
                    # confirm once, 5s later (camofox --fail-text discipline)
                    await asyncio.sleep(5)
                    text2 = await body_text(page)
                    if "Log in" in text2 and "Sign up" in text2:
                        verdict = "LOGGED-OUT-WALL"
                        log(f"stop {name}: wall confirmed "
                            f"(text len={len(text2)})", C_WARN)
                        break
                    continue
                hit = next((m for m in markers
                            if m in text and len(text) > 200), None)
                if hit:
                    verdict, shell_at = "SHELL", time.time() - t0
                    log(f"stop {name}: SHELL marker={hit!r} "
                        f"textlen={len(text)} tts={shell_at:.1f}s", C_OK)
                    break
                await asyncio.sleep(5)
            else:
                if last_title and "Just a moment" in last_title:
                    verdict = "CF-STALL"
                log(f"stop {name}: poll deadline, verdict={verdict} "
                    f"last_title={last_title!r}", C_WARN)

            if verdict == "SHELL":
                log(f"stop {name}: holding dwell={DWELL}s", C_DIM)
                held = 0
                while held < DWELL:
                    step = min(20, DWELL - held)
                    await asyncio.sleep(step)
                    held += step
                    rss_peak = max(rss_peak, rss_mb(srv.pid))
                text = await body_text(page)
                still = any(m in text for m in markers) and not (
                    "Log in" in text and "Sign up" in text)
                log(f"stop {name}: post-hold still-shell={still} "
                    f"textlen={len(text)} rss_peak={rss_peak}MB",
                    C_OK if still else C_WARN)
            try:
                await asyncio.wait_for(browser.close(), 15)
            except Exception as e:
                log(f"stop {name}: browser.close exc "
                    f"{type(e).__name__} {str(e)[:120]}", C_WARN)
    except Exception as e:
        verdict = "ERROR"
        log(f"stop {name}: ERROR {type(e).__name__} {str(e)[:200]}", C_ERR)
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=5)
        except Exception:
            srv.kill()
        CURRENT_SRV = None
        srvlog.close()
        kill_leftovers(f"post-stop {name}")
    tts = round(shell_at, 1) if shell_at else None
    return verdict, tts, rss_peak


def print_config():
    for line in CONFIG_SOURCES:
        print(f"config: {line}", flush=True)
    print(f"config: resolved: home={HOME} bin={BIN} jar={JAR} "
          f"links={len(LINKS)} dwell={DWELL}s gap={GAP}s "
          f"breaker={BREAKER} poll={POLL}s base_port={BASE_PORT}",
          flush=True)


def check():
    """--check: config parse + binary/jar preflight, no server, no tour."""
    print_config()
    rc = 0
    if not LINKS:
        print("check: LP_LINKS is empty — set it in the system env or in "
              f"{ENV_FILE} (see .env.example next to it)", flush=True)
        rc = 1
    if os.path.isfile(BIN) and os.access(BIN, os.X_OK):
        ver = subprocess.run([BIN, "version"], capture_output=True,
                             text=True, timeout=10)
        print(f"check: binary ok: {BIN} (version "
              f"{ver.stdout.strip() or '?'})", flush=True)
    else:
        print(f"check: binary MISSING or not executable: {BIN} — "
              "run: bash setup.sh --lightpanda", flush=True)
        rc = 1
    if os.path.exists(JAR):
        try:
            n = convert_jar()
            print(f"check: jar ok: {JAR} ({n} cookies)", flush=True)
        except Exception as e:
            print(f"check: jar UNREADABLE: {JAR}: {e}", flush=True)
            rc = 1
    else:
        print(f"check: jar missing: {JAR} — a tour would FATAL on it; "
              "export a fresh jar from the account's browser session",
              flush=True)
        rc = 1
    print(f"check: {'OK' if rc == 0 else 'FAILED'}", flush=True)
    return rc


async def main():
    print_config()
    if not LINKS:
        log("FATAL: LP_LINKS is empty — nothing to tour", C_ERR)
        sys.exit(2)
    if not os.path.exists(JAR):
        log(f"FATAL: jar missing at {JAR}", C_ERR)
        sys.exit(2)
    if not (os.path.isfile(BIN) and os.access(BIN, os.X_OK)):
        log(f"FATAL: lightpanda binary missing at {BIN} — "
            "run: bash setup.sh --lightpanda", C_ERR)
        sys.exit(2)
    n = convert_jar()
    log(f"lp-tour start: {len(LINKS)} stops dwell={DWELL}s gap={GAP}s "
        f"poll={POLL}s breaker={BREAKER} cookies={n}")
    fail_streak = 0
    rnd = 0
    while True:
        rnd += 1
        r0 = time.time()
        log(f"=== round {rnd} start ===")
        try:
            n = convert_jar()
            log(f"round {rnd}: jar reconverted, cookies={n}", C_DIM)
        except Exception as e:
            log(f"round {rnd}: jar reconvert failed ({e}); "
                "reusing previous", C_WARN)
        for idx, url in enumerate(LINKS):
            name = url.rsplit("/", 1)[-1]
            verdict, tts, rss_peak = await run_stop(idx, url)
            ok = verdict == "SHELL"
            fail_streak = 0 if ok else fail_streak + 1
            log(f"stop={name} verdict={verdict} "
                f"time_to_shell={tts} dwell={DWELL}s rss_peak={rss_peak}MB "
                f"fail_streak={fail_streak}",
                C_OK if ok else C_WARN)
            if BREAKER and fail_streak >= BREAKER:
                log(f"*** tour ABORTED after {BREAKER} consecutive failed "
                    f"stops (last: {name} {verdict})", C_ERR)
                sys.exit(1)
            if GAP:
                await asyncio.sleep(GAP)
        log(f"=== round {rnd} complete in {time.time()-r0:.0f}s ===", C_OK)
        if MAX_ROUNDS and rnd >= MAX_ROUNDS:
            log(f"MAX_ROUNDS={MAX_ROUNDS} reached, exiting")
            return


def _cleanup(signum, frame):
    if CURRENT_SRV is not None:
        try:
            CURRENT_SRV.kill()
        except Exception:
            pass
    sys.exit(128 + signum)


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)
    asyncio.run(main())
