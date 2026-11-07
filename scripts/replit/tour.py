#!/usr/bin/env python3
"""tour.py — the unified session keep-alive tour (fleet session keep-alive).

ONE tour program, engine chosen by flag: `--browser lightpanda|camofox`
(env TOUR_BROWSER fallback, default lightpanda). It supersedes lp-tour.py
(the Lightpanda-only tour) — the Lightpanda engine below is that proven
program ported unchanged in mechanics; the camofox engine drives the
camofox server API through camofox.py's own client machinery and reaches
the same diagnosis grade. See references/lightpanda.md and
references/session-keepalive.md for the engine comparison and mechanics.

The job, engine-independent: sequential stops over TOUR_LINKS — for each
project URL, open the page logged-in (cookie jar), hold it for the dwell,
close everything, move to the next stop. A round is len(LINKS) x
(DWELL + GAP); that open cadence — not any in-tab refresh — is what holds
a fleet of Replit workspaces inside their idle tolerance.

Verdicts per stop (BOTH engines): SHELL / LOGGED-OUT-WALL (visible text
contains both "Log in" and "Sign up", confirmed by a second probe 5s
later — the camofox --fail-text discipline) / CF-STALL (poll budget spent
on the "Just a moment..." title; Cloudflare normally clears by itself in
~7-18s) / ERROR (transport/server failure) / UNKNOWN, with time-to-shell
per stop and title tracking. After a SHELL verdict the tab is held for
the full dwell and re-probed: still-shell is logged. Circuit breaker:
TOUR_MAX_EARLY_FAILURES CONSECUTIVE non-SHELL stops abort the tour
(`*** tour ABORTED`, exit 1); a SHELL stop resets the count. ALL page
reads in the poll loop are bounded — asyncio.wait_for on the Lightpanda
side, an explicit request timeout on every camofox call — because a
stuck challenge page once wedged an unbounded read for ~100s.

Lightpanda engine (proven shape, fleet trial 2026-11-06):
  * one fresh server per stop, torn down after the stop: Lightpanda has
    zero idle cost, so there is no resident server to keep warm;
  * the server's stdout/stderr go to a per-stop log FILE, never a pipe —
    an undrained PIPE wedges the server silently;
  * cookies plant ONLY via the server's native --cookie loader, with the
    jar converted to a CDP cookie array. Playwright's Storage.setCookies
    FAILS against Lightpanda (BrowserContextNotLoaded) — do not "fix"
    this by switching to CDP planting;
  * navigation always goes through a fresh ctx.new_page(): the default
    CDP page is a non-navigable startup session;
  * the jar is re-converted every round, so a re-imported jar is picked
    up without restarting the tour;
  * TOUR_JAR_WRITEBACK: after each SHELL stop the live session's cookies
    are merged back into the jar (freshest per name/domain/path, atomic
    tmp+replace, mode 600, fail-open), so the session keeps what it
    earns — notably a cf_clearance — across stops and rounds instead of
    re-facing the challenge from a static jar.

Camofox engine (the fallback engine):
  * drives the camofox SERVER's HTTP API via camofox.py's client
    (req/convert/dismiss_dialogs/diagnose) — reuse, not reinvention;
  * the server is a resident service the CALLER runs (its own workflow);
    the tour NEVER spawns it — an unreachable server is an ERROR verdict
    (and a --check failure), surfaced, not papered over;
  * cookies go in through the server's import path
    (POST /sessions/<user>/cookies) once at tour start, when a jar file
    exists; with no jar the server's persisted per-user cookies are used;
  * one session per stop, closed at teardown (DELETE /tabs/group/<s>),
    so tabs never outlive the stop that opened them.

Log standard: every line is `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
(LEVEL = INFO/OK/SKIP/WARN/ERROR), PLAIN by default so file logs grep
clean; colour is opt-in via --colour or TOUR_LOG_COLOUR=1 and wraps ONLY
the [LEVEL] token.

Config (fleet "big env" rule: a var already set in the system
environment WINS; the engine home's .env file only fills gaps; the
source of every var is logged at startup, name + source only):
  file      lightpanda: $LIGHTPANDA_HOME/.env (LIGHTPANDA_ENV_FILE wins)
            camofox:    $XDG_CONFIG_HOME/camofox/.env (CAMOFOX_ENV_FILE
                        wins, then legacy $CAMOFOX_ROOT/.env — the same
                        discovery camofox.py itself uses)
  TOUR_LINKS          required: comma/whitespace-separated project URLs
                      (fallback: LP_LINKS — the lp-tour-era name, kept
                      for one release so captain .env files work as-is)
  TOUR_BROWSER        lightpanda|camofox (fallback for --browser)
  TOUR_COOKIES        cookie jar, browser-export or Playwright format
                      (fallback LP_COOKIES; default lightpanda:
                      $LIGHTPANDA_HOME/cookies.json, camofox:
                      $XDG_CONFIG_HOME/camofox/cookies.json)
  TOUR_DWELL_S        seconds the tab is held per stop   (default 60)
  TOUR_GAP_S          sleep between stops, tab closed    (default 0)
  TOUR_POLL_S         budget for the shell marker        (default 150;
                      fallback LP_POLL_S)
  TOUR_MAX_EARLY_FAILURES  circuit breaker, 0 = never    (default 3)
  TOUR_MAX_ROUNDS     0 = tour forever                   (default 0;
                      fallback LP_MAX_ROUNDS)
  TOUR_ONLY           run only the stop with this last path segment
                      (fallback LP_ONLY)
  TOUR_JAR_WRITEBACK  lightpanda only: 1 = merge live cookies back into
                      the jar after each SHELL stop (default off;
                      fallback LP_JAR_WRITEBACK; merge-only, fail-open)
  TOUR_LOG_COLOUR     1 = colour the [LEVEL] token       (default off)
  TOUR_BASE_PORT      lightpanda: first CDP port; stop i uses +i
                      (default 19401; fallback LP_BASE_PORT)
  TOUR_LOG_DIR        lightpanda: per-stop server logs   (fallback
                      LP_LOG_DIR; default $LIGHTPANDA_HOME/logs)
  TOUR_CAMOFOX_USER   camofox: server user id holding the session
                      (default "tour")
  TOUR_CAMOFOX_SESSION  camofox: session-key prefix; stop i uses
                      "<prefix>-<i>"                     (default "tour")
  CAMOFOX_BASE_URL    camofox: server URL (default http://127.0.0.1:9377)
  LIGHTPANDA_HOME     install/state root (default $XDG_CONFIG_HOME/lightpanda)
  LIGHTPANDA_BIN      engine binary (default $LIGHTPANDA_HOME/lightpanda,
                      then `lightpanda` on PATH)

Run via tour.sh (it assembles LD_LIBRARY_PATH + the venv python).
`tour.py --check` resolves and prints the config, probes the engine
(binary + jar for lightpanda, server health + jar for camofox), and
exits without opening anything.
"""
import asyncio, json, os, shutil, signal, socket, subprocess, sys, time, urllib.request

# ── engine selection ───────────────────────────────────────────────────
# Resolved BEFORE the rest of config: the .env fallback file lives in
# the chosen engine's home, so the engine must be known first. CLI
# --browser wins, then TOUR_BROWSER from the SYSTEM env (the .env file
# cannot move its own home, so it is not consulted for this one var),
# then the lightpanda default.


def _cli_browser(argv):
    for i, a in enumerate(argv):
        if a == "--browser" and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith("--browser="):
            return a.split("=", 1)[1]
    return None


BROWSER = (_cli_browser(sys.argv[1:])
           or os.environ.get("TOUR_BROWSER") or "lightpanda").strip().lower()
_COLOUR_FLAG = "--colour" in sys.argv or "--color" in sys.argv

_XDG = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
_LP_HOME_AMBIENT = os.environ.get("LIGHTPANDA_HOME") or os.path.join(
    _XDG, "lightpanda")
_CF_CONFIG_HOME = os.path.join(_XDG, "camofox")


def _env_file_for(browser):
    """The .env fallback for the chosen engine — the same discovery the
    engine's own tooling uses (lp-tour.py / camofox.default_env)."""
    if browser == "camofox":
        root = os.environ.get("CAMOFOX_ROOT") or os.path.join(
            os.environ.get("REPL_HOME") or os.path.expanduser("~"), "camofox")
        for p in (os.environ.get("CAMOFOX_ENV_FILE"),
                  os.path.join(_CF_CONFIG_HOME, ".env"),
                  os.path.join(root, ".env")):
            if p and os.path.exists(p):
                return p
        return os.path.join(_CF_CONFIG_HOME, ".env")
    return (os.environ.get("LIGHTPANDA_ENV_FILE")
            or os.path.join(_LP_HOME_AMBIENT, ".env"))


ENV_FILE = _env_file_for(BROWSER)


# ── config ─────────────────────────────────────────────────────────────
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


def cfg_chain(names, default=""):
    """First name that resolves wins: system env > .env file > default.
    TOUR_* names are listed before their lp-tour-era fallbacks, so an
    old .env keeps working and a new one takes precedence. The
    resolution is logged (name + source only, never a value)."""
    for name in names:
        if os.environ.get(name):
            CONFIG_SOURCES.append(
                f"{name}: from system env (.env file skipped)")
            return os.environ[name]
        if _FILE_ENV.get(name):
            CONFIG_SOURCES.append(f"{name}: from .env file ({ENV_FILE})")
            return _FILE_ENV[name]
    CONFIG_SOURCES.append(f"{'/'.join(names)}: from default")
    return default


def cfg(name, default=""):
    return cfg_chain([name], default)


def cfg_int_chain(names, default):
    raw = cfg_chain(names, str(default))
    try:
        return int(raw)
    except ValueError:
        print(f"config: {'/'.join(names)}={raw!r} is not an integer — "
              f"using {default}", flush=True)
        return default


def cfg_int(name, default):
    return cfg_int_chain([name], default)


HOME = cfg("LIGHTPANDA_HOME", _LP_HOME_AMBIENT)
BIN = cfg("LIGHTPANDA_BIN") or os.path.join(HOME, "lightpanda")
if not os.path.exists(BIN):
    BIN = shutil.which("lightpanda") or BIN
_JAR_DEFAULT = (os.path.join(HOME, "cookies.json") if BROWSER != "camofox"
                else os.path.join(_CF_CONFIG_HOME, "cookies.json"))
JAR = cfg_chain(["TOUR_COOKIES", "LP_COOKIES"], _JAR_DEFAULT)
ARRAY = os.path.join(HOME, ".jar-array.json")
LOG_DIR = cfg_chain(["TOUR_LOG_DIR", "LP_LOG_DIR"],
                    os.path.join(HOME, "logs"))

DWELL = cfg_int("TOUR_DWELL_S", 60)
GAP = cfg_int("TOUR_GAP_S", 0)
BREAKER = cfg_int("TOUR_MAX_EARLY_FAILURES", 3)
POLL = cfg_int_chain(["TOUR_POLL_S", "LP_POLL_S"], 150)
BASE_PORT = cfg_int_chain(["TOUR_BASE_PORT", "LP_BASE_PORT"], 19401)
MAX_ROUNDS = cfg_int_chain(["TOUR_MAX_ROUNDS", "LP_MAX_ROUNDS"], 0)
WRITEBACK = cfg_chain(["TOUR_JAR_WRITEBACK", "LP_JAR_WRITEBACK"], "") \
    in ("1", "true", "yes")
ONLY = cfg_chain(["TOUR_ONLY", "LP_ONLY"], "")
COLOUR = _COLOUR_FLAG or cfg("TOUR_LOG_COLOUR", "") in ("1", "true", "yes")

CF_USER = cfg("TOUR_CAMOFOX_USER", "tour")
CF_SESSION = cfg("TOUR_CAMOFOX_SESSION", "tour")
CF_URL = cfg("CAMOFOX_BASE_URL", "http://127.0.0.1:9377").rstrip("/")

LINKS = [u for u in cfg_chain(["TOUR_LINKS", "LP_LINKS"], "")
         .replace(",", " ").split() if u]
if ONLY:
    LINKS = [u for u in LINKS if u.rsplit("/", 1)[-1] == ONLY]

# ── logs: the fleet log standard — [YYYY-MM-DD HH:MM:SS] [LEVEL] msg,
# plain by default; colour opt-in (--colour / TOUR_LOG_COLOUR=1) wraps
# ONLY the [LEVEL] token, message text stays plain so grep keeps working.
_LVL_COLOUR = {"INFO": "\033[0;36m", "OK": "\033[0;32m",
               "SKIP": "\033[2m", "WARN": "\033[1;33m",
               "ERROR": "\033[1;31m"}
_LVL_RST = "\033[0m"


def log(msg, level="INFO"):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    tok = f"[{level}]"
    if COLOUR:
        tok = f"{_LVL_COLOUR[level]}{tok}{_LVL_RST}"
    print(f"[{ts}] {tok} {msg}", flush=True)


# ── shared verdict rules (both engines) ────────────────────────────────
def shell_markers(name):
    return ["Files", "Invite", "Console", "Shell",
            "Personal workspace", name]


def is_wall(text):
    """Logged-out wall: BOTH needles present (a single common word
    inside a project's own code must not trip it alone)."""
    return "Log in" in text and "Sign up" in text


def marker_hit(markers, text):
    if len(text) <= 200:
        return None
    return next((m for m in markers if m in text), None)


# ══ Lightpanda engine ═════════════════════════════════════════════════
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


_WB_DISABLED = False  # set when the engine refuses cookie read-back


def writeback_jar(cookies, name):
    """Merge cookies read back from a live session into the on-disk jar:
    freshest per (name, domain, path) wins, nothing is ever deleted, the
    write is atomic (tmp + replace, mode 600), and any error leaves the
    jar untouched. Paired with convert_jar() re-running every round,
    this turns the static jar into an evolving one — the session keeps
    what it earns (notably a cf_clearance) across stops, rounds and
    restarts, like a living browser profile does."""
    if not cookies:
        return
    try:
        raw = json.load(open(JAR))
        container = raw.get("cookies", raw) if isinstance(raw, dict) \
            else raw
        by_key = {}
        for c in container:
            if "name" in c:
                by_key[(c["name"], c.get("domain", ""),
                        c.get("path", "/"))] = c
        changed = 0
        for c in cookies:
            if "name" not in c or "value" not in c:
                continue
            key = (c["name"], c.get("domain", ""), c.get("path", "/"))
            new = {"name": c["name"], "value": c["value"],
                   "domain": c.get("domain", ".replit.com"),
                   "path": c.get("path", "/")}
            if c.get("expires") and float(c["expires"]) > 0:
                new["expires"] = float(c["expires"])
            for f in ("secure", "httpOnly", "sameSite"):
                if c.get(f) is not None:
                    new[f] = c[f]
            if by_key.get(key, {}).get("value") != new["value"]:
                changed += 1
            by_key[key] = new
        merged = list(by_key.values())
        out = dict(raw, cookies=merged) if isinstance(raw, dict) \
            and "cookies" in raw else merged
        tmp = JAR + ".wb-tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(out, f)
        os.replace(tmp, JAR)
        log(f"stop {name}: jar write-back: {len(merged)} cookies "
            f"({changed} changed)", "SKIP")
    except Exception as e:
        log(f"stop {name}: jar write-back failed ({type(e).__name__}: "
            f"{str(e)[:100]}); jar untouched", "WARN")


async def writeback_ctx(ctx, name):
    """Read the live context's cookies and merge them into the jar.
    If the engine refuses the read (Lightpanda's CDP surface is
    partial — Storage.setCookies already fails), disable write-back
    for this process and carry on: it must never break a tour."""
    global _WB_DISABLED
    if _WB_DISABLED:
        return
    try:
        cookies = await asyncio.wait_for(ctx.cookies(), 15)
    except Exception as e:
        _WB_DISABLED = True
        log(f"stop {name}: cookie read-back unsupported "
            f"({type(e).__name__}: {str(e)[:100]}); write-back "
            "disabled for this process", "WARN")
        return
    writeback_jar(cookies, name)


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
        log(f"leftover lightpanda pid={pid} killed ({context})", "WARN")
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
    """Bounded page read: inner_text has its own 3s timeout AND the
    wait_for cap — a stuck challenge page must never wedge the poll
    loop (the ~100s hang this guard exists for)."""
    try:
        return await asyncio.wait_for(
            page.inner_text("body", timeout=3000), 10)
    except Exception:
        return ""


async def run_stop_lightpanda(idx, url):
    """One Lightpanda tour stop.
    Returns (verdict, time_to_shell_s, rss_peak_mb)."""
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
                        f"http://127.0.0.1:{port}/json/version",
                        timeout=2) as r:
                    r.read()
                up = True
                break
            except Exception:
                await asyncio.sleep(0.5)
        if not up:
            log(f"stop {name}: server HTTP never came up", "ERROR")
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
                    f"{str(e)[:120]} (continuing to poll)", "WARN")

            markers = shell_markers(name)
            deadline = time.time() + POLL
            last_title = None
            while time.time() < deadline:
                try:
                    title = await asyncio.wait_for(page.title(), 10)
                except Exception:
                    title = "?"
                if title != last_title:
                    log(f"stop {name}: title -> {title!r}", "SKIP")
                    last_title = title
                rss_peak = max(rss_peak, rss_mb(srv.pid))
                text = await body_text(page)
                if is_wall(text):
                    # confirm once, 5s later (camofox --fail-text discipline)
                    await asyncio.sleep(5)
                    text2 = await body_text(page)
                    if is_wall(text2):
                        verdict = "LOGGED-OUT-WALL"
                        log(f"stop {name}: wall confirmed "
                            f"(text len={len(text2)})", "WARN")
                        break
                    continue
                hit = marker_hit(markers, text)
                if hit:
                    verdict, shell_at = "SHELL", time.time() - t0
                    log(f"stop {name}: SHELL marker={hit!r} "
                        f"textlen={len(text)} tts={shell_at:.1f}s", "OK")
                    break
                await asyncio.sleep(5)
            else:
                if last_title and "Just a moment" in last_title:
                    verdict = "CF-STALL"
                log(f"stop {name}: poll deadline, verdict={verdict} "
                    f"last_title={last_title!r}", "WARN")

            if verdict == "SHELL":
                log(f"stop {name}: holding dwell={DWELL}s", "SKIP")
                held = 0
                while held < DWELL:
                    step = min(20, DWELL - held)
                    await asyncio.sleep(step)
                    held += step
                    rss_peak = max(rss_peak, rss_mb(srv.pid))
                text = await body_text(page)
                still = any(m in text for m in markers) \
                    and not is_wall(text)
                log(f"stop {name}: post-hold still-shell={still} "
                    f"textlen={len(text)} rss_peak={rss_peak}MB",
                    "OK" if still else "WARN")
                if WRITEBACK:
                    await writeback_ctx(ctx, name)
            try:
                await asyncio.wait_for(browser.close(), 15)
            except Exception as e:
                log(f"stop {name}: browser.close exc "
                    f"{type(e).__name__} {str(e)[:120]}", "WARN")
    except Exception as e:
        verdict = "ERROR"
        log(f"stop {name}: ERROR {type(e).__name__} {str(e)[:200]}",
            "ERROR")
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


# ══ Camofox engine ════════════════════════════════════════════════════
# Drives the camofox server's HTTP API through camofox.py's own client
# machinery (req / convert / dismiss_dialogs / diagnose_timeout),
# imported lazily from this same payload directory — camofox.py is
# import-safe (its import only resolves its env-file config, the
# documented big-env merge). The server is a resident service owned by
# the caller: the tour checks its health and reports ERROR, it NEVER
# spawns it. Every request carries an explicit timeout — the sync
# equivalent of the Lightpanda side's asyncio.wait_for discipline.
_CF = None        # the imported camofox module
CURRENT_CF = None  # (key, session) of the live stop, for signal cleanup


def _camofox():
    global _CF
    if _CF is None:
        here = os.path.dirname(os.path.abspath(__file__))
        if here not in sys.path:
            sys.path.insert(0, here)
        import camofox
        _CF = camofox
    return _CF


def cf_key():
    return _camofox().load_key(None)


def cf_health(key, timeout=5):
    """The /health dict when the server answers cleanly, else None."""
    h = _camofox().req(key, "GET", "/health", timeout=timeout)
    if isinstance(h, dict) and "_error" not in h and "_http_error" not in h:
        return h
    return None


def cf_import_cookies(key):
    """Import the jar into the tour's camofox user via the server's
    import path. Same endpoint + payload as camofox.import_cookies
    (POST /sessions/<user>/cookies, API key — that route checks
    CAMOFOX_API_KEY only), but returns (ok, detail) instead of exiting:
    whether a failed import is fatal is the tour's call, not the
    client's. Returns (True, count) or (False, reason)."""
    cf = _camofox()
    try:
        raw = json.load(open(JAR))
    except Exception as e:
        return False, f"jar unreadable: {e}"
    items = raw.get("cookies", raw) if isinstance(raw, dict) else raw
    norm = []
    for c in items:
        if "name" not in c or "value" not in c:
            continue
        c = dict(c)
        # camofox.convert reads the browser-export `expirationDate`;
        # a Playwright-format jar carries the same instant as `expires`.
        if not c.get("expirationDate") and c.get("expires"):
            c["expirationDate"] = c["expires"]
        norm.append(c)
    api_key = os.environ.get("CAMOFOX_API_KEY") or key
    r = cf.req(api_key, "POST", f"/sessions/{CF_USER}/cookies",
               {"cookies": [cf.convert(c) for c in norm]}, timeout=60)
    if isinstance(r, dict) and "_http_error" not in r and "_error" not in r:
        return True, r.get("count", len(norm))
    if isinstance(r, dict) and r.get("_error") == "timed out":
        return False, ("import timed out — "
                       + cf.diagnose_timeout())
    return False, f"import failed: {r}"


_TEXT_JS = "(() => (document.body && document.body.innerText || ''))()"
_TITLE_JS = "(() => document.title)()"


def cf_eval(key, tab, expr, timeout=30):
    """One bounded page read via the server's evaluate route; the
    result value, or None when the request itself failed."""
    r = _camofox().req(key, "POST", f"/tabs/{tab}/evaluate",
                       {"userId": CF_USER, "expression": expr},
                       timeout=timeout)
    if isinstance(r, dict) and "_error" not in r and "_http_error" not in r:
        return r.get("result")
    return None


def cf_page_text(key, tab):
    t = cf_eval(key, tab, _TEXT_JS)
    return t if isinstance(t, str) else ""


def run_stop_camofox(idx, url):
    """One camofox tour stop (sync; run in a thread by run_stop).
    Returns (verdict, time_to_shell_s, None) — no per-stop RSS on this
    engine: the server is a resident service, not a per-stop process."""
    global CURRENT_CF
    cf = _camofox()
    name = url.rsplit("/", 1)[-1]
    key = cf_key()
    session = f"{CF_SESSION}-{idx}"
    t0 = time.time()
    verdict, shell_at = "UNKNOWN", None

    if cf_health(key) is None:
        log(f"stop {name}: camofox server unreachable at {cf.CAMOFOX_URL} "
            "— the tour never spawns it; start the camofox service",
            "ERROR")
        return "ERROR", None, None
    r = cf.req(key, "POST", "/tabs",
               {"userId": CF_USER, "sessionKey": session, "url": url},
               timeout=60)
    if not isinstance(r, dict) or "_error" in r or "_http_error" in r \
            or not r.get("tabId"):
        log(f"stop {name}: open failed: {r}", "ERROR")
        return "ERROR", None, None
    tab = r["tabId"]
    CURRENT_CF = (key, session)
    log(f"stop {name}: tab={tab[:8]} session={session} url={url}")
    try:
        # The Replit upsell modal, when present — camofox.py's generic
        # dismissal (needle is caller data, mechanism is site-agnostic).
        cf.dismiss_dialogs(key, CF_USER, tab, ["Keep using Replit?"])
        markers = shell_markers(name)
        deadline = time.time() + POLL
        last_title = None
        while time.time() < deadline:
            title = cf_eval(key, tab, _TITLE_JS)
            if isinstance(title, str) and title != last_title:
                log(f"stop {name}: title -> {title!r}", "SKIP")
                last_title = title
            text = cf_page_text(key, tab)
            if is_wall(text):
                # confirm once, 5s later (the --fail-text discipline)
                time.sleep(5)
                text2 = cf_page_text(key, tab)
                if is_wall(text2):
                    verdict = "LOGGED-OUT-WALL"
                    log(f"stop {name}: wall confirmed "
                        f"(text len={len(text2)})", "WARN")
                    break
                continue
            hit = marker_hit(markers, text)
            if hit:
                verdict, shell_at = "SHELL", time.time() - t0
                log(f"stop {name}: SHELL marker={hit!r} "
                    f"textlen={len(text)} tts={shell_at:.1f}s", "OK")
                break
            time.sleep(5)
        else:
            if last_title and "Just a moment" in last_title:
                verdict = "CF-STALL"
            log(f"stop {name}: poll deadline, verdict={verdict} "
                f"last_title={last_title!r}", "WARN")

        if verdict == "SHELL":
            log(f"stop {name}: holding dwell={DWELL}s", "SKIP")
            time.sleep(DWELL)
            text = cf_page_text(key, tab)
            still = any(m in text for m in markers) and not is_wall(text)
            log(f"stop {name}: post-hold still-shell={still} "
                f"textlen={len(text)}", "OK" if still else "WARN")
    except Exception as e:
        verdict = "ERROR"
        log(f"stop {name}: ERROR {type(e).__name__} {str(e)[:200]}",
            "ERROR")
    finally:
        # Session per stop, closed at teardown — tabs outlive their
        # client process on this server, so NOT closing leaks RAM.
        r = cf.req(key, "DELETE",
                   f"/tabs/group/{session}?userId={CF_USER}", timeout=30)
        if isinstance(r, dict) and ("_error" in r or "_http_error" in r):
            log(f"stop {name}: session close failed: {r}", "WARN")
        CURRENT_CF = None
    tts = round(shell_at, 1) if shell_at else None
    return verdict, tts, None


async def run_stop(idx, url):
    if BROWSER == "camofox":
        return await asyncio.to_thread(run_stop_camofox, idx, url)
    return await run_stop_lightpanda(idx, url)


# ── preflight + main loop (shared) ─────────────────────────────────────
def print_config():
    for line in CONFIG_SOURCES:
        print(f"config: {line}", flush=True)
    print(f"config: resolved: browser={BROWSER} links={len(LINKS)} "
          f"dwell={DWELL}s gap={GAP}s breaker={BREAKER} poll={POLL}s "
          f"colour={COLOUR}", flush=True)
    if BROWSER == "camofox":
        print(f"config: resolved: camofox url={CF_URL} user={CF_USER} "
              f"session={CF_SESSION}-<i> jar={JAR}", flush=True)
    else:
        print(f"config: resolved: home={HOME} bin={BIN} jar={JAR} "
              f"base_port={BASE_PORT} writeback={WRITEBACK}",
              flush=True)


def check():
    """--check: config parse + engine preflight, no server spawn (the
    camofox server is only PROBED — it is never started from here),
    no tour. Exit code says whether a tour could run."""
    print_config()
    rc = 0
    if BROWSER not in ("lightpanda", "camofox"):
        print(f"check: unknown browser {BROWSER!r} — "
              "use --browser lightpanda|camofox", flush=True)
        return 2
    if not LINKS:
        print("check: TOUR_LINKS (fallback LP_LINKS) is empty — set it "
              f"in the system env or in {ENV_FILE} (see .env.example "
              "next to it)", flush=True)
        rc = 1
    if BROWSER == "camofox":
        key = cf_key()
        h = cf_health(key)
        if h is not None:
            print(f"check: camofox server ok: {CF_URL} "
                  f"(browserRunning={h.get('browserRunning')}, "
                  f"activeSessions={h.get('activeSessions')})",
                  flush=True)
        else:
            print(f"check: camofox server UNREACHABLE at {CF_URL} — "
                  "the tour never spawns it; start the camofox service "
                  "(camofox launcher / its workflow) first",
                  flush=True)
            print(_camofox().diagnose_timeout(), flush=True)
            rc = 1
        if os.path.exists(JAR):
            try:
                raw = json.load(open(JAR))
                items = raw.get("cookies", raw) \
                    if isinstance(raw, dict) else raw
                print(f"check: jar ok: {JAR} ({len(items)} cookies, "
                      f"imported for user {CF_USER} at tour start)",
                      flush=True)
            except Exception as e:
                print(f"check: jar UNREADABLE: {JAR}: {e}", flush=True)
                rc = 1
        else:
            print(f"check: jar missing: {JAR} — not fatal for camofox: "
                  f"the server's persisted cookies for user {CF_USER} "
                  "will be used; import a jar to refresh them",
                  flush=True)
    else:
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
            print(f"check: jar missing: {JAR} — a tour would FATAL on "
                  "it; export a fresh jar from the account's browser "
                  "session", flush=True)
            rc = 1
    print(f"check: {'OK' if rc == 0 else 'FAILED'}", flush=True)
    return rc


async def main():
    print_config()
    if BROWSER not in ("lightpanda", "camofox"):
        log(f"FATAL: unknown browser {BROWSER!r} — "
            "use --browser lightpanda|camofox", "ERROR")
        sys.exit(2)
    if not LINKS:
        log("FATAL: TOUR_LINKS (fallback LP_LINKS) is empty — "
            "nothing to tour", "ERROR")
        sys.exit(2)
    cookies_note = ""
    if BROWSER == "camofox":
        key = cf_key()
        if cf_health(key) is None:
            log(f"FATAL: camofox server unreachable at {CF_URL} — "
                "the tour never spawns it; start the camofox service "
                "first", "ERROR")
            sys.exit(2)
        if os.path.exists(JAR):
            ok, detail = cf_import_cookies(key)
            if not ok:
                log(f"FATAL: cookie import failed: {detail}", "ERROR")
                sys.exit(2)
            cookies_note = f" cookies={detail} (imported, user={CF_USER})"
            log(f"camofox: imported {detail} cookies for user {CF_USER}")
        else:
            log(f"camofox: no jar at {JAR} — using the server's "
                f"persisted cookies for user {CF_USER}", "WARN")
            cookies_note = f" cookies=persisted (user={CF_USER})"
    else:
        if not os.path.exists(JAR):
            log(f"FATAL: jar missing at {JAR}", "ERROR")
            sys.exit(2)
        if not (os.path.isfile(BIN) and os.access(BIN, os.X_OK)):
            log(f"FATAL: lightpanda binary missing at {BIN} — "
                "run: bash setup.sh --lightpanda", "ERROR")
            sys.exit(2)
        n = convert_jar()
        cookies_note = f" cookies={n}"
    log(f"tour start: browser={BROWSER} {len(LINKS)} stops "
        f"dwell={DWELL}s gap={GAP}s poll={POLL}s breaker={BREAKER}"
        f"{cookies_note}")
    fail_streak = 0
    rnd = 0
    while True:
        rnd += 1
        r0 = time.time()
        log(f"=== round {rnd} start ===")
        if BROWSER != "camofox":
            try:
                n = convert_jar()
                log(f"round {rnd}: jar reconverted, cookies={n}", "SKIP")
            except Exception as e:
                log(f"round {rnd}: jar reconvert failed ({e}); "
                    "reusing previous", "WARN")
        for idx, url in enumerate(LINKS):
            name = url.rsplit("/", 1)[-1]
            verdict, tts, rss_peak = await run_stop(idx, url)
            ok = verdict == "SHELL"
            fail_streak = 0 if ok else fail_streak + 1
            rss = f"{rss_peak}MB" if rss_peak is not None else "n/a"
            log(f"stop={name} verdict={verdict} "
                f"time_to_shell={tts} dwell={DWELL}s rss_peak={rss} "
                f"fail_streak={fail_streak}",
                "OK" if ok else "WARN")
            if BREAKER and fail_streak >= BREAKER:
                log(f"*** tour ABORTED after {BREAKER} consecutive "
                    f"failed stops (last: {name} {verdict})", "ERROR")
                sys.exit(1)
            if GAP:
                await asyncio.sleep(GAP)
        log(f"=== round {rnd} complete in {time.time()-r0:.0f}s ===",
            "OK")
        if MAX_ROUNDS and rnd >= MAX_ROUNDS:
            log(f"MAX_ROUNDS={MAX_ROUNDS} reached, exiting")
            return


def _cleanup(signum, frame):
    if CURRENT_SRV is not None:
        try:
            CURRENT_SRV.kill()
        except Exception:
            pass
    if CURRENT_CF is not None:
        try:
            key, session = CURRENT_CF
            _camofox().req(key, "DELETE",
                           f"/tabs/group/{session}?userId={CF_USER}",
                           timeout=5)
        except Exception:
            pass
    sys.exit(128 + signum)


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)
    asyncio.run(main())
