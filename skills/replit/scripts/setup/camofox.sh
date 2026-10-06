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
CAMOFOX_CLOSURE_FILE="$XDG_DATA_HOME/camofox/closure.txt"

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
# wasteful and hung this box's rc writer; invoke the server as
#   bash -c '. ${XDG_DATA_HOME}/camofox/env.sh; exec camofox-browser'
camofox_write_env_snippet() {
  local f="$XDG_DATA_HOME/camofox/env.sh"
  [[ -s "$CAMOFOX_CLOSURE_FILE" ]] || return 0
  mkdir -p "$(dirname "$f")"
  {
    echo "# camofox runtime env (setup.sh --camofox). Source before camofox-browser."
    echo "export LD_LIBRARY_PATH=\"\$(cat \"$CAMOFOX_CLOSURE_FILE\")\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
    echo "export CAMOUFOX_INSTALL_DIR=\"$CAMOUFOX_INSTALL_DIR\""
    echo 'if [[ "${CAMOFOX_BIND_HOST:-127.0.0.1}" = 127.0.0.1 ]]; then unset CAMOFOX_ACCESS_KEY; fi'
  } > "$f"
  ok "camofox env snippet: $f"
}

install_camofox() {
  step "Camofox browser (npm-global @askjo/camofox-browser)"
  need_cmd npm
  need_cmd node
  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME/camofox" "$CAMOUFOX_INSTALL_DIR"

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

  # 5) closure env snippet (sourced by the managed rc → camofox-browser direct)
  camofox_write_env_snippet

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
  rm -f "$XDG_BIN_HOME/camofox-browser" "$XDG_BIN_HOME/camofox-browser-mcp"
  # Engine (re-fetchable) + closure.
  rm -rf "$CAMOUFOX_INSTALL_DIR" "$XDG_DATA_HOME/camofox"
  # Server state (cookies/profiles) is user data — kept; delete ~/.camofox to wipe.
  ok "Camofox removed (engine + closure + package; server state kept in ~/.camofox)"
}