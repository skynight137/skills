# shellcheck shell=bash
# Camofox browser (anti-detection Firefox server) — npm-global install.
# Sourced by setup.sh.
#
# Why npm-global (not a git clone):
#   - `npm i -g @askjo/camofox-browser` puts the server + MCP adapter on PATH
#     (`camofox-browser`, `camofox-browser-mcp`) and keeps the package in the
#     npm prefix — no bespoke CAMOFOX_ROOT tree to manage or clean.
#   - The Camoufox engine is provisioned by the package's OWN pinned fetcher
#     into the standard cache dir, so `npm update -g` keeps engine + client in
#     step (newer releases fix fingerprint drift).
#
# Replit-specific bits this module handles (all measured on-box):
#   1. Lib closure.  Camoufox-Firefox needs the transitive GTK/X11/ALSA
#      closure from /nix/store, which the Replit loader never searches. The
#      closure is generated to a file and applied ONLY to the camofox process
#      by the launcher — never globally, because LD_LIBRARY_PATH with the
#      closure shadows platform libs (it broke `curl` on this box).
#   2. WebGL spoof.  camoufox-js seeds WebGL from a LIVE GPU sample. On a
#      GPU-less Replit there is no GL context (WebGL is null) and the spoof
#      HANGS every Firefox content process, so pages never load ("new page
#      timed out"). We patch the installed camoufox-js so CAMOFOX_SKIP_WEBGL_FP=1
#      skips WebGL fingerprinting; the launcher sets it ONLY when no GPU render
#      node exists (full spoof preserved on GL-capable boxes). Verified: with
#      the skip, open/refresh/evaluate/cookie-import all work; without it, they
#      hang on this box.
#   3. newPage timeout.  camofox.config.json ships 10000ms, too tight for a
#      cold Nix repl; the launcher's config is raised to a 60000ms floor.

# Global npm prefix (setup.sh sets npm_config_prefix=$NODE_DIR), so `-g`
# binaries land in $NODE_DIR/bin (already on PATH) and the package in
# $NODE_DIR/lib/node_modules.
CAMOFOX_NPM_PKG="@askjo/camofox-browser"
camofox_pkg_dir() { printf '%s/lib/node_modules/@askjo/camofox-browser' "$NODE_DIR"; }

# Engine cache dir: the persistent XDG cache. Replit always sets XDG_CACHE_HOME
# (=$WORKSPACE/.cache, survives recreates) — prefer it, with a plain fallback
# off-Replit. camoufox-js resolves its default from os.homedir(), so we pin
# CAMOUFOX_INSTALL_DIR explicitly; the launcher re-derives it the same way.
CAMOFOX_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
# Always derive from XDG_CACHE_HOME — NEVER honor an ambient CAMOUFOX_INSTALL_DIR
# (an old [userenv.shared] value would send the engine to the wrong place).
# NOTE the spelling: camoufox-js reads CAMOUFOX_INSTALL_DIR (with the U).
CAMOUFOX_INSTALL_DIR="$CAMOFOX_CACHE_HOME/camoufox"
CAMOFOX_CLOSURE_FILE="$XDG_DATA_HOME/camofox/closure.txt"

# --- WebGL-fingerprint skip patch (idempotent) ------------------------------
# Edits the installed camoufox-js so a CAMOFOX_SKIP_WEBGL_FP=1 env skips the
# WebGL spoof. Marker-guarded; a re-run (or a version that already carries it)
# is a no-op. Upstream default behaviour is untouched when the var is unset.
camofox_patch_webgl() {
  local pkg; pkg="$(camofox_pkg_dir)"
  local util="$pkg/node_modules/camoufox-js/dist/utils.js"
  [[ -f "$util" ]] || { warn "camoufox-js utils.js not found ($util) — WebGL skip not patched"; return 0; }
  if grep -q 'CAMOFOX_SKIP_WEBGL_FP' "$util"; then
    skip "camoufox-js WebGL-skip patch already applied"
    return 0
  fi
  # Anchor on the unique upstream line; insert the env gate before it.
  if ! grep -q 'if (block_webgl || launch_options.allow_webgl === false) {' "$util"; then
    warn "camoufox-js WebGL branch shape changed — patch not applied (upstream may have fixed it; verify pages load)"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  awk '
    /if \(block_webgl \|\| launch_options\.allow_webgl === false\) \{/ && !done {
      print "    // setup.sh patch: skip WebGL fingerprint spoofing when CAMOFOX_SKIP_WEBGL_FP=1"
      print "    // (GPU-less hosts: the spoofed renderer deadlocks the content process)."
      print "    if (process.env.CAMOFOX_SKIP_WEBGL_FP === \"1\") { /* no WebGL spoof */ }"
      print "    else if (block_webgl || launch_options.allow_webgl === false) {"
      done = 1; next
    }
    { print }
  ' "$util" > "$tmp"
  if bash -n /dev/null 2>/dev/null && grep -q 'CAMOFOX_SKIP_WEBGL_FP' "$tmp"; then
    cat "$tmp" > "$util"; rm -f "$tmp"
    ok "patched camoufox-js: CAMOFOX_SKIP_WEBGL_FP=1 disables WebGL spoofing"
  else
    rm -f "$tmp"; warn "WebGL-skip patch failed to apply — leaving camoufox-js untouched"
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

# --- launcher ---------------------------------------------------------------
# A per-process wrapper: sets the lib closure + camofox env, then execs the
# npm-global server. Keeping the closure OUT of the interactive rc means other
# tools (curl/openssl) are never shadowed. Paths are baked at install time.
camofox_write_launcher() {
  mkdir -p "$XDG_BIN_HOME"
  cat > "$XDG_BIN_HOME/camofox" <<EOF
#!/usr/bin/env bash
# camofox — launch the anti-detection Firefox server (setup.sh --camofox).
# Wraps the npm-global \`camofox-browser\`; sets the GTK/X11 lib closure and the
# Replit-tuned env. Args are forwarded (e.g. --help).
set -euo pipefail
if [[ "\${1:-}" == -h || "\${1:-}" == --help ]]; then
  echo "usage: camofox            # start camofox-browser on :\${CAMOFOX_PORT:-9377}"
  echo "env: CAMOFOX_PORT CAMOFOX_BIND_HOST CAMOFOX_API_KEY (client token)"
  echo "     CAMOFOX_ACCESS_KEY (optional superkey — only for exposing beyond loopback)"
  exit 0
fi
CLOSURE_FILE="$CAMOFOX_CLOSURE_FILE"
POOL="${REPL_HOME:-$HOME}/.local/lib"
_CL=""
[[ -f "\$CLOSURE_FILE" ]] && _CL="\$(cat "\$CLOSURE_FILE")"
if [[ -d "\$POOL" ]]; then
  export LD_LIBRARY_PATH="\$POOL\${_CL:+:\$_CL}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
elif [[ -n "\$_CL" ]]; then
  export LD_LIBRARY_PATH="\$_CL\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
fi
unset _CL
# FORCE the engine dir from XDG_CACHE_HOME (Replit always provides it; it points
# at the persistent $WORKSPACE/.cache). A stale CAMOUFOX_INSTALL_DIR in the
# inherited env (e.g. an old [userenv.shared]) would otherwise make camoufox-js
# look for version.json in the wrong place and re-download the engine there.
export CAMOUFOX_INSTALL_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/camoufox"
# WebGL spoof: camoufox-js seeds it by LIVE GPU sampling (sampleWebGL). On a
# GPU-less host there is no GL context (WebGL is null) and the spoof hangs the
# Firefox content process, so pages never load. Auto-detect: skip the spoof
# ONLY when no GPU render node exists; keep the FULL spoof on GL-capable boxes.
# Force your own choice with CAMOFOX_SKIP_WEBGL_FP=0|1.
if [[ -z "\${CAMOFOX_SKIP_WEBGL_FP:-}" ]]; then
  if compgen -G "/dev/dri/render*" >/dev/null 2>&1 || compgen -G "/dev/dri/card*" >/dev/null 2>&1; then
    CAMOFOX_SKIP_WEBGL_FP=0
  else
    CAMOFOX_SKIP_WEBGL_FP=1
  fi
fi
export CAMOFOX_SKIP_WEBGL_FP
export CAMOFOX_BIND_HOST="\${CAMOFOX_BIND_HOST:-127.0.0.1}"
export CAMOFOX_PORT="\${CAMOFOX_PORT:-9377}"
# ACCESS superkey gates EVERY route — only needed to expose beyond loopback.
# On the default loopback bind, DROP an inherited one so the server uses the
# client token (CAMOFOX_API_KEY) alone. Keep it only when you opt into a
# non-loopback bind (set CAMOFOX_BIND_HOST + CAMOFOX_ACCESS_KEY together).
if [[ "\$CAMOFOX_BIND_HOST" == "127.0.0.1" ]]; then unset CAMOFOX_ACCESS_KEY; fi
# Client token. CAMOFOX_API_KEY is the one the CLI (camofox.py) and cookie
# import use. Generated once into \$CAMOFOX_ROOT/.env (chmod 600, NOT in git)
# so later CLI runs reuse the same token.
CAMOFOX_ROOT="\${CAMOFOX_ROOT:-\${REPL_HOME:-\$HOME}/camofox}"
if [[ -z "\${CAMOFOX_API_KEY:-}" && -f "\$CAMOFOX_ROOT/.env" ]]; then
  CAMOFOX_API_KEY="\$(sed -n 's/^CAMOFOX_API_KEY=//p' "\$CAMOFOX_ROOT/.env" | head -1)"
fi
if [[ -z "\${CAMOFOX_API_KEY:-}" ]]; then
  CAMOFOX_API_KEY="\$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \\n')"
  mkdir -p "\$CAMOFOX_ROOT" && umask 077 && printf 'CAMOFOX_API_KEY=%s\\n' "\$CAMOFOX_API_KEY" > "\$CAMOFOX_ROOT/.env"
fi
export CAMOFOX_API_KEY
export TAB_INACTIVITY_MS="\${TAB_INACTIVITY_MS:-900000}"
export SESSION_TIMEOUT_MS="\${SESSION_TIMEOUT_MS:-1800000}"
export BROWSER_IDLE_TIMEOUT_MS="\${BROWSER_IDLE_TIMEOUT_MS:-0}"
export MAX_SESSIONS="\${MAX_SESSIONS:-4}"
export MAX_TABS_PER_SESSION="\${MAX_TABS_PER_SESSION:-3}"
export MAX_TABS_GLOBAL="\${MAX_TABS_GLOBAL:-8}"
exec camofox-browser "\$@"
EOF
  chmod +x "$XDG_BIN_HOME/camofox"
  ok "launcher written: $XDG_BIN_HOME/camofox"
}

install_camofox() {
  step "Camofox browser (npm-global @askjo/camofox-browser)"
  need_cmd npm
  need_cmd node
  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME/camofox" "$CAMOUFOX_INSTALL_DIR"

  # 1) package (idempotent; lockfile-free global install resolves fast on re-run)
  echo "  npm install -g $CAMOFOX_NPM_PKG"
  npm install -g --registry=https://registry.npmjs.org/ "$CAMOFOX_NPM_PKG" \
    || die "npm install -g $CAMOFOX_NPM_PKG failed"
  [[ -x "$XDG_BIN_HOME/camofox-browser" || -x "$NODE_DIR/bin/camofox-browser" ]] \
    || command -v camofox-browser >/dev/null 2>&1 \
    || die "camofox-browser not on PATH after install"

  # 2) Replit compatibility fixes
  camofox_patch_webgl
  camofox_raise_newpage_timeout

  # 3) lib closure (persisted to file; applied per-process by the launcher)
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

  # 5) launcher
  camofox_write_launcher
  ok "camofox installed — start with: camofox   (API on http://127.0.0.1:9377)"

  record_tool_env_vars CAMOUFOX_INSTALL_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool camofox CAMOUFOX_INSTALL_DIR -- "$XDG_BIN_HOME"
}

clean_camofox() {
  local pkg; pkg="$(camofox_pkg_dir)"
  local launcher="$XDG_BIN_HOME/camofox"
  if ! _present "$launcher" "$pkg" "$CAMOUFOX_INSTALL_DIR" "$XDG_BIN_HOME/camofox-browser"; then
    nothing_removed "Camofox"; return 0
  fi
  step "Removing Camofox browser"
  # Package + both PATH binaries (global install lives in the npm prefix).
  if command -v npm >/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g "$CAMOFOX_NPM_PKG" \
      || warn "npm uninstall -g $CAMOFOX_NPM_PKG failed — remove $pkg by hand"
  fi
  rm -f "$XDG_BIN_HOME/camofox" "$XDG_BIN_HOME/camofox-browser" "$XDG_BIN_HOME/camofox-browser-mcp"
  # Engine (re-fetchable) + closure.
  rm -rf "$CAMOUFOX_INSTALL_DIR" "$XDG_DATA_HOME/camofox"
  # Server state (cookies/profiles) — user data; remove only on request.
  ok "Camofox removed (engine + closure + package; server state kept in ~/.camofox)"
}