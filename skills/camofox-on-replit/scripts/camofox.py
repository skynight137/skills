#!/usr/bin/env python3
"""Unified Camofox CLI — import cookies, list users/sessions, run tools.

One entry point replaces import-cookies.py / refresh-loop.py / list-sessions.py.

Modes (sentinel values):
    camofox.py                          # list users + live sessions (summary)
    camofox.py --user list              # list existing users (cookie jars)
    camofox.py --session list           # list live sessions (open tabs)
    camofox.py --user rl --cookies X    # import cookies into user rl
    camofox.py --tools refresh-page --url URL [--user u] [--session s] \
               [--cookies X] [--interval 180]   # open + keep-alive loop

--cookies <json>: if present, (re)import into --user BEFORE any tool runs.
Cookies otherwise persist per --user on disk and auto-reload — omit to reuse.

Auth/config: the env file is loaded into the environment at import, BEFORE any
setting is read, so EVERY Camofox variable can live in it — CAMOFOX_URL,
CAMOFOX_ROOT, CAMOFOX_STATE_DIR, CAMOFOX_API_KEY, … not just the key. No agent
framework required: only $CAMOFOX_ENV_FILE and $CAMOFOX_ROOT/.env are consulted
(see default_env).
"""
import argparse, glob, json, os, sys, time, urllib.error, urllib.request
from typing import cast


# --- config, resolved at import in dependency order ---------------------------
# Order matters: the env file path can only be found from the AMBIENT env, so
# that happens first; then the file is applied to os.environ; only then is the
# server URL read. Otherwise a CAMOFOX_URL / CAMOFOX_ROOT set in the env file
# would be ignored (the module constant would already hold the fallback).
def _read_env_file(path):
    """Parse KEY=VALUE lines. Blank lines, comments, `export ` prefixes, and
    surrounding quotes are tolerated. Later duplicates win, matching shell."""
    out = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].lstrip()
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("'\"")
    return out


def default_env():
    """First EXISTING candidate wins, else None. The env file is OPTIONAL and
    no agent framework is consulted: point $CAMOFOX_ENV_FILE at one, or drop it
    at $CAMOFOX_ROOT/.env. With neither, plain environment variables are used,
    and no key at all just means unauthenticated mode.

    Reads CAMOFOX_ROOT / XDG_DATA_HOME from the AMBIENT env only — it runs
    before the env file is applied, and the file cannot point at itself.
    """
    root = os.environ.get("CAMOFOX_ROOT") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "camofox")
    for p in (os.environ.get("CAMOFOX_ENV_FILE"), os.path.join(root, ".env")):
        if p and os.path.exists(p):
            return p
    return None


ENV_FILE = default_env()
# setdefault semantics: the real environment WINS, the file only fills gaps.
# This mirrors start-camofox.sh, which sources the file with `set -a` but after
# exporting its own defaults, so an explicit shell export still overrides.
if ENV_FILE:
    for _k, _v in _read_env_file(ENV_FILE).items():
        os.environ.setdefault(_k, _v)
    del _k, _v

CAMOFOX = os.environ.get("CAMOFOX_URL", "http://127.0.0.1:9377").rstrip("/")
SAMESITE = {"no_restriction": "None", "lax": "Lax", "strict": "Strict",
            "unspecified": "Lax", "none": "None"}


# --- path discovery (mirror start-camofox.sh) --------------------------------
def default_root():
    if os.environ.get("CAMOFOX_ROOT"):
        return os.environ["CAMOFOX_ROOT"]
    xdg = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(xdg, "camofox")


def default_state():
    if os.environ.get("CAMOFOX_STATE_DIR"):
        return os.environ["CAMOFOX_STATE_DIR"]
    return os.path.join(default_root(), "state")


# --- HTTP --------------------------------------------------------------------
def load_key(env_path):
    """Prefer the explicit/--env file, then the (already merged) environment."""
    if env_path and os.path.exists(env_path):
        v = _read_env_file(env_path).get("CAMOFOX_API_KEY")
        if v:
            return v
    return os.environ.get("CAMOFOX_API_KEY") or None


def req(key, method, path, body=None, timeout=300):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(
        CAMOFOX + path, data=data,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {key or ''}"}, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {"_http_error": e.code, "_body": e.read().decode()[:400]}
    except Exception as e:
        return {"_error": str(e)}


def req_bytes(key, path, timeout=120):
    """Fetch a binary response (e.g. screenshot PNG). Returns (bytes, err)."""
    r = urllib.request.Request(
        CAMOFOX + path,
        headers={"Authorization": f"Bearer {key or ''}"})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.read(), None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read().decode()[:200]}"
    except Exception as e:
        return None, str(e)


# --- cookie conversion -------------------------------------------------------
def convert(c):
    out = {"name": c["name"], "value": c["value"],
           "domain": c.get("domain", "").lstrip(".")}
    if c.get("path"):
        out["path"] = c["path"]
    if c.get("expirationDate"):
        out["expires"] = int(float(c["expirationDate"]))
    if c.get("httpOnly"):
        out["httpOnly"] = True
    if c.get("secure"):
        out["secure"] = True
    ss = c.get("sameSite")
    if ss:
        out["sameSite"] = SAMESITE.get(str(ss), "Lax")
    return out


def import_cookies(key, user, cookie_path):
    cookies = json.load(open(cookie_path))
    r = req(key, "POST", f"/sessions/{user}/cookies",
            {"cookies": [convert(c) for c in cookies]})
    if "_http_error" in r or "_error" in r:
        print(f"import failed: {r}", file=sys.stderr)
        sys.exit(1)
    print(f"imported {r.get('count')} cookies -> user {user}")


# --- listing -----------------------------------------------------------------
def known_users(state):
    prof = os.path.join(state, "profiles")
    out = []
    for m in sorted(glob.glob(os.path.join(prof, "*/meta.json"))):
        try:
            meta = json.load(open(m))
            out.append(meta)
        except Exception:
            continue
    return out


def profile_summary(meta):
    ss = meta.get("storageStatePath")
    doms, nc = {}, 0
    if ss and os.path.exists(ss):
        try:
            for c in json.load(open(ss)).get("cookies", []):
                d = (c.get("domain") or "?").lstrip(".")
                doms[d] = doms.get(d, 0) + 1
                nc += 1
        except Exception:
            pass
    return nc, doms


def list_users(state, key):
    metas = known_users(state)
    if not metas:
        print(f"no profiles under {os.path.join(state, 'profiles')}")
        return
    print(f"{'USER':<12}{'LAST UPDATED':<22}{'COOKIES':>8}{'LIVE':>6}   DOMAINS")
    print("-" * 96)
    for meta in metas:
        user = meta.get("userId", "?")
        upd = meta.get("updatedAt", "")[:19].replace("T", " ") + "Z"
        nc, doms = profile_summary(meta)
        tabs = req(key, "GET", f"/tabs?userId={user}").get("tabs", [])
        dom_str = ", ".join(f"{d}({doms[d]})" for d in sorted(doms)[:8])
        print(f"{user:<12}{upd:<22}{nc:>8}{len(tabs):>6}   {dom_str}")


def list_sessions(state, key):
    metas = known_users(state)
    rows = []
    for meta in metas:
        user = meta.get("userId", "?")
        tabs = req(key, "GET", f"/tabs?userId={user}").get("tabs", [])
        for t in tabs:
            rows.append((user, t.get("listItemId", "?"), t.get("url", "?"),
                         (t.get("title") or "")[:40]))
    if not rows:
        print("no live sessions")
        return
    print(f"{'USER':<12}{'SESSION':<20}{'URL':<48}TITLE")
    print("-" * 100)
    for user, sess, url, title in rows:
        print(f"{user:<12}{sess:<20}{url:<48}{title}")


# --- tools -------------------------------------------------------------------
def tool_screenshot(key, user, session, out_dir, full_page=True):
    """Screenshot live tab(s) for user (optionally a specific session/group).
    Saves PNGs to out_dir as <user>__<session>[_<n>].png. Returns list of paths."""
    os.makedirs(out_dir, exist_ok=True)
    tabs = cast(list, req(key, "GET", f"/tabs?userId={user}").get("tabs", []))
    if session:
        tabs = cast(list, [t for t in tabs if t.get("listItemId") == session])
    if not tabs:
        print(f"no live tab for user={user} session={session or '*'}", file=sys.stderr)
        return []
    saved = []
    for i, tab in enumerate(tabs):
        tab_id = tab["tabId"]
        saved_id = tab_id[:8]
        sess_label = session or tab.get("listItemId") or saved_id
        q = f"userId={user}&fullPage={str(full_page).lower()}"
        data, err = req_bytes(key, f"/tabs/{tab_id}/screenshot?{q}")
        if err:
            print(f"  screenshot {sess_label} failed: {err}", file=sys.stderr)
            continue
        path = os.path.join(out_dir, f"{user}__{sess_label}" +
                            (f"_{i}" if len(tabs) > 1 else "") + ".png")
        with open(path, "wb") as f:
            f.write(data)
        saved.append(path)
        print(f"saved {path} ({len(data)} bytes)")
    return saved


def tool_refresh_page(key, user, session, url, interval, shot_dir=None):
    r = req(key, "POST", "/tabs",
            {"userId": user, "sessionKey": session, "url": url})
    if "_http_error" in r or "_error" in r:
        print(f"open failed: {r}", file=sys.stderr)
        sys.exit(1)
    tab = r.get("tabId", "")
    print(f"refresh-page: user={user} session={session} tab={tab[:8]} "
          f"interval={interval}s url={url}"
          + (f" screenshots={shot_dir}" if shot_dir else ""))
    if shot_dir:
        tool_screenshot(key, user, session, shot_dir, full_page=True)
    while True:
        time.sleep(interval)
        if shot_dir:
            # capture the currently fully-loaded page BEFORE refreshing it
            tool_screenshot(key, user, session, shot_dir, full_page=True)
        rr = req(key, "POST", f"/tabs/{tab}/refresh", {"userId": user})
        if "_http_error" in rr or "_error" in rr:
            print("refresh error:", rr)
            r = req(key, "POST", "/tabs",
                    {"userId": user, "sessionKey": session, "url": url})
            if "_http_error" not in r and "_error" not in r:
                tab = r.get("tabId", "")
                print("reopened tab", tab[:8])
        else:
            print(f"refresh ok @ {time.strftime('%H:%M:%S')}")


TOOLS = {"refresh-page": tool_refresh_page}


# --- main --------------------------------------------------------------------
def wait_for_server(key, timeout, interval=2.0):
    """Block until Camofox /health responds or `timeout` seconds elapse.

    start-camofox.sh can take minutes (npm install + fetch engine + browser
    boot) and Replit `waitForPort` only gates the *provision* workflow, not
    parallel consumers. Callers that hit Errno 111 (refused) must wait here."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = req(key, "GET", "/health", timeout=5)
        if "_error" not in r and "_http_error" not in r:
            return True
        time.sleep(interval)
    print(f"camofox not ready after {timeout}s (is start-camofox.sh running?)",
          file=sys.stderr)
    return False


def main():
    ap = argparse.ArgumentParser(description="Unified Camofox CLI")
    ap.add_argument("--cookies", help="cookie JSON to (re)import into --user")
    ap.add_argument("--user", default="rl")
    ap.add_argument("--session", default="camofox")
    ap.add_argument("--tools", choices=sorted(TOOLS))
    ap.add_argument("--url")
    ap.add_argument("--interval", type=int, default=180)
    ap.add_argument("--screenshot", metavar="DIR",
                    help="screenshot live tab(s) into DIR and exit (PNGs)")
    ap.add_argument("--full-page", action=argparse.BooleanOptionalAction,
                    default=True, help="full-page screenshot (default: on)")
    ap.add_argument("--env", default=default_env())
    ap.add_argument("--state", default=default_state())
    ap.add_argument("--wait", type=int, default=180,
                    help="max seconds to wait for :9377 to come up (default 180)")
    a = ap.parse_args()

    key = load_key(a.env)

    # listing sentinels: probe briefly so live-tab counts work if server is
    # up, but don't block list output on a slow/hung server.
    if a.user == "list":
        wait_for_server(key, min(a.wait, 5))
        list_users(a.state, key)
        return
    if a.session == "list":
        wait_for_server(key, min(a.wait, 5))
        list_sessions(a.state, key)
        return

    # action path: no key is allowed (unauthenticated mode) unless the server
    # requires one, in which case the request itself returns 403.
    if not key:
        where = a.env or "no env file found ($CAMOFOX_ENV_FILE / $CAMOFOX_ROOT/.env)"
        print(f"[camofox] no CAMOFOX_API_KEY ({where}) — "
              f"continuing unauthenticated; 403 means the server needs a key",
              file=sys.stderr)

    # block until server is actually up (fixes Errno 111 Connection refused
    # when this runs before start-camofox.sh finishes, e.g. parallel .replit)
    if not wait_for_server(key, a.wait):
        sys.exit(1)

    decode_session = None if a.session == "camofox" else a.session

    # one-shot screenshot (no loop) when --screenshot but no --tools
    if a.screenshot and not a.tools:
        if a.cookies:
            import_cookies(key, a.user, a.cookies)
        saved = tool_screenshot(key, a.user, decode_session, a.screenshot,
                                a.full_page)
        sys.exit(0 if saved else 1)

    if a.cookies:
        import_cookies(key, a.user, a.cookies)
    elif a.tools:
        print(f"reusing persisted cookies for user {a.user}")

    if a.tools:
        if not a.url:
            print(f"--tools {a.tools} requires --url", file=sys.stderr)
            sys.exit(1)
        if a.tools == "refresh-page":
            tool_refresh_page(key, a.user, a.session, a.url, a.interval,
                              shot_dir=a.screenshot)
        else:
            TOOLS[a.tools](key, a.user, a.session, a.url, a.interval)
    elif a.cookies is None and not a.tools:
        # bare invocation -> show summary
        list_users(a.state, key)
        print()
        list_sessions(a.state, key)


if __name__ == "__main__":
    main()