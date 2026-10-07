# shellcheck shell=bash
# Camofox browser (anti-detection Firefox server) — npm-global install.
# Sourced by setup.sh.
#
# Design: the npm package IS the interface. `setup.sh --camofox` installs
# `@askjo/camofox-browser` globally, so you call the real binaries directly —
# `camofox-browser` (server) and `camofox-browser-mcp` (MCP adapter). There is
# no wrapper script and no env file; a default loopback server needs no key.
#
# Replit-specific work this module does (all measured on-box):
#   1. lib closure — Camoufox-Firefox needs the transitive GTK/X11/ALSA closure
#      from /nix/store, which the Replit loader never searches. generate-closure.sh
#      writes it and EXCLUDES the network/TLS families (openssl/curl/…) so the
#      closure is safe on a GLOBAL LD_LIBRARY_PATH (an unpruned one shadows the
#      platform openssl and breaks curl). See rc.sh / the managed shell block for
#      the wiring; the pool dir is also prepended there.
#   2. WebGL spoof — camoufox-js seeds WebGL from a LIVE GPU sample. On a
#      GPU-less Replit (no /dev/dri) there is no GL context (WebGL is null) and
#      the spoof HANGS every Firefox content process, so pages never load. We
#      patch the installed camoufox-js to AUTO-SKIP (detect /dev/dri at launch),
#      so no env var and no wrapper is needed; a GL-capable host keeps the full
#      spoof. Override with CAMOFOX_SKIP_WEBGL_FP=0|1.
#   3. newPage timeout — camofox.config.json ships 10000ms, too tight for a cold
#      Nix repl; raised to a 60000ms floor.
#   4. engine dir — CAMOUFOX_INSTALL_DIR (with the U; that is camoufox-js's
#      spelling) is pinned to $XDG_CACHE_HOME/camoufox (persistent, not $HOME).

CAMOFOX_NPM_PKG="@askjo/camofox-browser"
camofox_pkg_dir() { printf '%s/lib/node_modules/@askjo/camofox-browser' "$NODE_DIR"; }

CAMOUFOX_INSTALL_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/camoufox"

# Server STATE dir (cookies/profiles/uploads/traces + the closure + env snippet) ──
# The npm package defaults every state var under $HOME/.camofox
# (lib/config.js:139-142) — and on Replit $HOME is WIPED on recreate, so a
# login silently evaporates. Anchor them under $XDG_CONFIG_HOME (persistent,
# under $REPL_HOME) and export them so the server picks them up.
#
# The server has NO single "state dir" variable: it reads four SEPARATE env
# vars, each with its own ~/.camofox default. CAMOFOX_STATE_DIR is a
# camofox.py-only convenience (its --state/listing fallback) and is NOT read
# by the server — setting it alone moves nothing.
#
# closure.txt and env.sh live in this SAME dir (not $XDG_DATA_HOME): one
# state root for the whole camofox install, so a wipe/move touches one path.
CAMOFOX_STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/camofox"
CAMOFOX_PROFILE_DIR="$CAMOFOX_STATE_DIR/profiles"
CAMOFOX_COOKIES_DIR="$CAMOFOX_STATE_DIR/cookies"
CAMOFOX_UPLOADS_DIR="$CAMOFOX_STATE_DIR/uploads"
CAMOFOX_TRACES_DIR="$CAMOFOX_STATE_DIR/traces"
CAMOFOX_CLOSURE_FILE="$CAMOFOX_STATE_DIR/closure.txt"
CAMOFOX_ENV_SNIPPET="$CAMOFOX_STATE_DIR/env.sh"

# One-time move of closure.txt/env.sh off the older $XDG_DATA_HOME/camofox
# layout so an existing install keeps working without a re-fetch. Copy, never
# move: the old path stays valid, and a second run is a no-op.
camofox_migrate_aux_files() {
  local old_dir="$XDG_DATA_HOME/camofox" f
  [[ -d "$old_dir" ]] || return 0
  mkdir -p "$CAMOFOX_STATE_DIR" 2>/dev/null || return 0
  for f in closure.txt env.sh; do
    [[ -s "$old_dir/$f" && ! -e "$CAMOFOX_STATE_DIR/$f" ]] || continue
    cp -a "$old_dir/$f" "$CAMOFOX_STATE_DIR/$f" 2>/dev/null \
      && warn "camofox: moved $f -> $CAMOFOX_STATE_DIR (copied; old file left in place)"
  done
}

# One-time migration off the volatile $HOME default. Copy, never move: the old
# dir stays valid, and a second run is a no-op because the target only takes
# files it does not already have.
camofox_migrate_state() {
  local old="$HOME/.camofox"
  [[ -d "$old" ]] || return 0
  mkdir -p "$CAMOFOX_PROFILE_DIR" 2>/dev/null || return 0
  if [[ -n "$(find "$CAMOFOX_PROFILE_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    return 0   # already populated — never clobber live state
  fi
  cp -a "$old"/. "$CAMOFOX_STATE_DIR"/ 2>/dev/null || true
  warn "camofox state: re-anchored \$HOME/.camofox -> $CAMOFOX_STATE_DIR (copied; old dir left in place)"
}

# --- camoufox-js patches (idempotent) ---------------------------------------
# (a) WebGL: auto-detect a GPU render node at launch instead of hanging on a
#     GPU-less host. Env CAMOFOX_SKIP_WEBGL_FP=0|1 still wins.
# (b) import existsSync for that check.
camofox_patch_webgl() {
  local pkg; pkg="$(camofox_pkg_dir)"
  local util="$pkg/node_modules/camoufox-js/dist/utils.js"
  [[ -f "$util" ]] || { warn "camoufox-js utils.js not found ($util) — WebGL patch skipped"; return 0; }
  if grep -q 'CAMOFOX_SKIP_WEBGL_FP' "$util"; then
    skip "camoufox-js WebGL auto-skip patch already applied"
    return 0
  fi
  if ! grep -q 'if (block_webgl || launch_options.allow_webgl === false) {' "$util"; then
    warn "camoufox-js WebGL branch shape changed — patch not applied (upstream may have fixed it; verify pages load)"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  awk '
    # import existsSync for the /dev/dri check (import line is stable).
    /^import \{ readFileSync \} from "node:fs";/ && !fs && !done {
      print "import { readFileSync, existsSync } from \"node:fs\";"; fs = 1; next
    }
    # auto-skip WebGL when no GPU render node exists (env override wins).
    /if \(block_webgl \|\| launch_options\.allow_webgl === false\) \{/ && !done {
      print "    // setup.sh patch: skip the WebGL spoof when there is no GPU."
      print "    // On a GPU-less host there is no GL context and the spoofed"
      print "    // renderer deadlocks the content process. Env override wins."
      print "    const _cfWebglEnv = process.env.CAMOFOX_SKIP_WEBGL_FP;"
      print "    const _cfNoGpu = !(existsSync(\"/dev/dri/renderD128\") || existsSync(\"/dev/dri/card0\"));"
      print "    if (_cfWebglEnv === \"1\" || (_cfWebglEnv !== \"0\" && _cfNoGpu)) { /* no WebGL spoof */ }"
      print "    else if (block_webgl || launch_options.allow_webgl === false) {"
      done = 1; next
    }
    { print }
  ' "$util" > "$tmp"
  if grep -q 'CAMOFOX_SKIP_WEBGL_FP' "$tmp" && grep -q 'readFileSync, existsSync' "$tmp"; then
    cat "$tmp" > "$util"; rm -f "$tmp"
    ok "patched camoufox-js: WebGL spoof auto-skipped on GPU-less hosts"
  else
    rm -f "$tmp"; warn "WebGL patch failed to apply — leaving camoufox-js untouched"
  fi
}

# Raise the newPage timeout floor in the package config (file-only setting).
camofox_raise_newpage_timeout() {
  local pkg; pkg="$(camofox_pkg_dir)"
  local cfg="$pkg/camofox.config.json"
  [[ -f "$cfg" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  NEW_PAGE_TIMEOUT_FLOOR="${NEW_PAGE_TIMEOUT_FLOOR:-60000}" node -e '
const fs=require("fs"),p=process.argv[1];
const floor=Number(process.env.NEW_PAGE_TIMEOUT_FLOOR)||60000;
let j; try{ j=JSON.parse(fs.readFileSync(p,"utf8")); }catch{ process.exit(0); }
const cur=Number(j.newPageTimeoutMs);
if(!Number.isFinite(cur)||cur<floor){ j.newPageTimeoutMs=floor; fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n"); console.log("  camofox.config.json newPageTimeoutMs "+cur+" -> "+floor); }
' "$cfg" || true
}

# Runtime env for camofox, applied by sourcing this file. Co-locates the GTK/X11
# closure with the two fixes a bare `camofox-browser` needs on this box:
#   * a stale ambient CAMOUFOX_INSTALL_DIR (an old [userenv.shared] value) would
#     point camoufox-js at the wrong engine dir and re-download there;
#   * an ambient CAMOFOX_ACCESS_KEY (from a workflow/agent) gates EVERY route,
#     breaking keyless loopback use.
# NOT sourced by the interactive shell rc — a 7 KB env var on every shell is
# wasteful and hung this box's rc writer.
#
# TWO consumers, and the second one is why the launcher below exists:
#   1. a shell CAN source it (`bash -c '. env.sh; exec camofox-browser'`);
#   2. the npm `camofox-browser` binary CANNOT — it is a JS entry point and the
#      GTK closure must be in LD_LIBRARY_PATH before the process starts. So a
#      workflow / Run-button / MCP / cron shell that just runs
#      `camofox-browser` launches Firefox with no GTK stack.
camofox_write_env_snippet() {
  local f="$CAMOFOX_ENV_SNIPPET"
  [[ -s "$CAMOFOX_CLOSURE_FILE" ]] || return 0
  mkdir -p "$(dirname "$f")"
  {
    echo "# camofox runtime env (setup.sh --camofox). Source before camofox-browser."
    echo "export LD_LIBRARY_PATH=\"\$(cat \"$CAMOFOX_CLOSURE_FILE\")\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
    echo "export CAMOUFOX_INSTALL_DIR=\"$CAMOUFOX_INSTALL_DIR\""
    # State dirs: without these the server defaults every one to $HOME/.camofox
    # (lib/config.js:139-142) — wiped on recreate, so a cookie jar/login dies
    # with it. The [userenv.shared] pins cover workflow shells; this covers any
    # consumer that only sources env.sh.
    echo "export CAMOFOX_STATE_DIR=\"$CAMOFOX_STATE_DIR\""
    echo "export CAMOFOX_PROFILE_DIR=\"$CAMOFOX_PROFILE_DIR\""
    echo "export CAMOFOX_COOKIES_DIR=\"$CAMOFOX_COOKIES_DIR\""
    echo "export CAMOFOX_UPLOADS_DIR=\"$CAMOFOX_UPLOADS_DIR\""
    echo "export CAMOFOX_TRACES_DIR=\"$CAMOFOX_TRACES_DIR\""
    echo 'if [[ "${CAMOFOX_BIND_HOST:-127.0.0.1}" = 127.0.0.1 ]]; then unset CAMOFOX_ACCESS_KEY; fi'
  } > "$f"
  ok "camofox env snippet: $f"
}

# Shell shim for consumers that cannot source env.sh.
#
# WHY THIS EXISTS (measured 2026-10-06): the `.replit` "camofox browser"
# workflow ran a bare `camofox-browser`. A workflow task is a NON-interactive
# shell: it never sources the user rc, so the exported `$XDG_DATA_HOME/camofox/
# env.sh` was never applied and the server inherited only the pinned
# `[userenv.shared] LD_LIBRARY_PATH=/home/runner/workspace/.local/lib`. Camoufox
# then died on every launch with
#   XPCOMGlueLoad error for .../libmozgtk.so: libgtk-3.so.0: cannot open shared
#   object file: No such file or directory
# and, because `camofox.py` imports cookies FIRST, the client only ever showed
#   import failed: {'_http_error': 500, '_body': '{"error":"browserType.launch:
#   Failed to launch the browser process..."}'}
# — i.e. the "refresh page" workflow failed while the browser was dead. 6 logged
# rp runs hit exactly this; it is not an intermittent bug.
#
# Fix: a shim that sources env.sh then execs the npm binary. The NAME IS
# DELIBERATELY DIFFERENT from `camofox-browser`, so it never shadows the npm bin
# on PATH and cannot recurse. Regenerated by `--fix`, so `--doctor` can verify it.
#
# ORDERING: run this AFTER the package + engine are in place (install_camofox
# step 5; --fix derives from the installed payloads). It is best-effort by
# design — it must never fail an install — but it is NOT a substitute for
# installing: each prerequisite is asserted at RUNTIME below, so a half-run
# ("launched the shim, forgot setup.sh --camofox") prints the exact missing
# piece and the one command that fixes it, instead of the loader's
# `libgtk-3.so.0: cannot open shared object file`.
camofox_write_launcher() {
  local f="$XDG_BIN_HOME/launch-camofox-browser"
  mkdir -p "$XDG_BIN_HOME" || { warn "cannot create $XDG_BIN_HOME — camofox launcher not written"; return 0; }
  # Quoted heredoc: every $ stays literal in the emitted script.
  cat > "$f" <<'EOF'
#!/usr/bin/env bash
# Generated by setup.sh (--camofox / --fix) — do not hand-edit; re-run --fix.
#
# Use this from any shell that has NOT sourced env.sh: .replit workflows, the
# Run button, cron/MCP children. A bare `camofox-browser` there launches
# Firefox with no GTK closure and dies with
# `libmozgtk.so: libgtk-3.so.0: cannot open shared object file` — which reaches
# the user as a bare "Internal server error" on the first tab/cookie call.
#
# This is a convenience wrapper, NOT the install. Run `setup.sh --camofox`
# first; the checks below tell you precisely what is missing if you didn't.
set -uo pipefail

X="${XDG_CONFIG_HOME:-${REPL_HOME:-$HOME}/.config}"
ENVSH="$X/camofox/env.sh"
CLOSURE="$X/camofox/closure.txt"
ENGINE="${CAMOUFOX_INSTALL_DIR:-${XDG_CACHE_HOME:-${REPL_HOME:-$HOME}/.cache}/camoufox}"
NOW="bash /home/runner/workspace/skynight137-skills/skills/replit/scripts/setup.sh"

missing=0
if ! command -v camofox-browser >/dev/null 2>&1; then
  echo "launch-camofox-browser: camofox-browser is not installed." >&2
  echo "  Camofox was never installed (or a \$HOME wipe removed its PATH dir)." >&2
  echo "  Fix: $NOW --camofox" >&2
  missing=1
fi
if [[ ! -s "$CLOSURE" ]]; then
  echo "launch-camofox-browser: the GTK/X11 lib closure is missing ($CLOSURE)." >&2
  echo "  Camofox's Firefox cannot start without it (libgtk-3.so.0)." >&2
  echo "  Fix: $NOW --camofox" >&2
  missing=1
fi
if [[ ! -s "$ENVSH" ]]; then
  echo "launch-camofox-browser: runtime env snippet missing ($ENVSH)." >&2
  echo "  Fix: $NOW --fix" >&2
  missing=1
fi
if [[ ! -f "$ENGINE/version.json" ]]; then
  echo "launch-camofox-browser: Camoufox engine missing ($ENGINE)." >&2
  echo "  Fix: $NOW --camofox   (~1.3 GB fetch)" >&2
  missing=1
fi
(( missing )) && { echo "launch-camofox-browser: refusing to start — see the fixes above." >&2; exit 1; }

# Prerequisites OK. env.sh APPENDS the closure, so an inherited LD_LIBRARY_PATH
# (the [userenv.shared] pool with libatomic) is preserved, not clobbered.
. "$ENVSH"
exec camofox-browser "$@"
EOF
  chmod +x "$f"
  ok "camofox launcher shim: $f"
}

install_camofox() {
  step "Camofox browser (npm-global @askjo/camofox-browser)"
  need_cmd npm
  need_cmd node
  mkdir -p "$XDG_BIN_HOME" "$CAMOFOX_STATE_DIR" "$CAMOUFOX_INSTALL_DIR"
  # Re-anchor closure.txt/env.sh from the older $XDG_DATA_HOME/camofox layout.
  camofox_migrate_aux_files

  # 1) package (idempotent; global install resolves fast on re-run)
  echo "  npm install -g $CAMOFOX_NPM_PKG"
  npm install -g --registry=https://registry.npmjs.org/ "$CAMOFOX_NPM_PKG" \
    || die "npm install -g $CAMOFOX_NPM_PKG failed"
  [[ -x "$XDG_BIN_HOME/camofox-browser" || -x "$NODE_DIR/bin/camofox-browser" ]] \
    || command -v camofox-browser >/dev/null 2>&1 \
    || die "camofox-browser not on PATH after install"

  # 2) Replit compatibility patches
  camofox_patch_webgl
  camofox_raise_newpage_timeout

  # 3) lib closure (globally-safe: generate-closure.sh prunes openssl/curl/…).
  #     The engine dir is forced onto the child fetch so it lands under the cache.
  if [[ ! -s "$CAMOFOX_CLOSURE_FILE" ]] \
     || [[ "$(tr ':' '\n' < "$CAMOFOX_CLOSURE_FILE" | while IFS= read -r d; do [[ -d "$d" ]] || echo gone; done)" != "" ]]; then
    echo "  generating GTK/X11 lib closure -> $CAMOFOX_CLOSURE_FILE"
    bash "$SCRIPT_DIR/setup/generate-closure.sh" "$CAMOFOX_CLOSURE_FILE" \
      || warn "closure generation failed — camofox will not start until the nix store has gtk3/alsa-lib/xorg.libXdamage"
  fi

  # 4) engine (package-pinned Camoufox; skipped when already present+valid)
  local engine_bin="$CAMOUFOX_INSTALL_DIR/camoufox-bin"
  if [[ -x "$engine_bin" && -f "$CAMOUFOX_INSTALL_DIR/version.json" ]]; then
    skip "Camoufox engine present: $CAMOUFOX_INSTALL_DIR ($(cat "$CAMOUFOX_INSTALL_DIR/version.json" 2>/dev/null))"
  else
    echo "  fetching Camoufox engine into $CAMOUFOX_INSTALL_DIR (~1.3 GB)"
    ( cd "$(camofox_pkg_dir)" && CAMOUFOX_INSTALL_DIR="$CAMOUFOX_INSTALL_DIR" node lib/camoufox-download.js ) \
      || die "Camoufox engine fetch failed"
  fi

  # 5) closure env snippet + launcher shim (the latter for non-interactive
  #    consumers: .replit workflows, Run button — they never source env.sh)
  camofox_write_env_snippet
  camofox_write_launcher

  # 6) state dir: re-anchor off the volatile $HOME/.camofox + persist the vars
  #    server-wide. ensure_libatomic is not the only durable-state concern —
  #    a cookie jar under $HOME is wiped on recreate.
  mkdir -p "$CAMOFOX_PROFILE_DIR" "$CAMOFOX_COOKIES_DIR" "$CAMOFOX_UPLOADS_DIR" "$CAMOFOX_TRACES_DIR" 2>/dev/null || true
  camofox_migrate_state
  record_tool_env_vars CAMOFOX_STATE_DIR CAMOFOX_PROFILE_DIR CAMOFOX_COOKIES_DIR \
                       CAMOFOX_UPLOADS_DIR CAMOFOX_TRACES_DIR

  ok "camofox installed — run: camofox-browser   (API on http://127.0.0.1:9377)"

  record_tool_env_vars CAMOUFOX_INSTALL_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool camofox CAMOUFOX_INSTALL_DIR -- "$XDG_BIN_HOME"
}

clean_camofox() {
  local pkg; pkg="$(camofox_pkg_dir)"
  if ! _present "$pkg" "$CAMOUFOX_INSTALL_DIR" "$XDG_BIN_HOME/camofox-browser"; then
    nothing_removed "Camofox"; return 0
  fi
  step "Removing Camofox browser"
  if command -v npm >/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g "$CAMOFOX_NPM_PKG" \
      || warn "npm uninstall -g $CAMOFOX_NPM_PKG failed — remove $pkg by hand"
  fi
  rm -f "$XDG_BIN_HOME/camofox-browser" "$XDG_BIN_HOME/camofox-browser-mcp" \
        "$XDG_BIN_HOME/launch-camofox-browser"
  # Engine (re-fetchable) + closure/env snippet (aux files under the state dir).
  rm -rf "$CAMOUFOX_INSTALL_DIR"
  rm -f "$CAMOFOX_CLOSURE_FILE" "$CAMOFOX_ENV_SNIPPET"
  rm -rf "$XDG_DATA_HOME/camofox"   # older layout, if still present
  # Server state (cookies/profiles) is user data — kept; delete $CAMOFOX_STATE_DIR to wipe.
  ok "Camofox removed (engine + closure + package; server state kept in $CAMOFOX_STATE_DIR)"
}