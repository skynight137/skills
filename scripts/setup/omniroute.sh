# shellcheck shell=bash
# OmniRoute — OpenAI-compatible AI router server (npm-global install).
# Sourced by setup.sh.
#
# Design: the npm package IS the interface. `setup.sh --omniroute`
# installs `omniroute` globally (pinned $OMNIROUTE_VERSION), so you run
# the real binaries directly — `omniroute` (the server) and
# `omniroute-reset-password`. There is no wrapper script.
#
# Layout: operator config AND the server's data both live under
# $XDG_CONFIG_HOME/omniroute (persistent, under $REPL_HOME) —
#   .env           operator config (provider keys, port) — NEVER
#                  created or overwritten by setup
#   .env.example   fill-in template, refreshed on every install
#   DATA_DIR       the template points it at this same dir, so the
#                  server's data sits OUTSIDE the npm install path and
#                  survives an uninstall; `setup.sh --clean omniroute`
#                  removes only the npm package + bins and preserves
#                  this dir (config + data are user data).
#
# Managed Node.js requirement (the camofox shape): the install runs
# under the managed tarball node ($NODE_MAJOR, the --node install),
# NEVER the platform nix node — npm-global installs land in the prefix
# of the node that runs them ($NODE_DIR), so an install under the
# platform node would land where no managed shell looks, while setup
# reported success. A bare `setup.sh --omniroute` installs the managed
# node FIRST and dies if node/npm do not resolve to it afterwards —
# never a silent fallback.

OMNIROUTE_HOME="${OMNIROUTE_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/omniroute}"
omniroute_pkg_dir() { printf '%s/lib/node_modules/omniroute' "$NODE_DIR"; }

# --- managed Node.js requirement (mirrors camofox_ensure_node) --------------
omniroute_ensure_node() {
  local bin="$NODE_DIR/bin/node" ver major
  if [[ -x "$bin" ]]; then
    ver="$("$bin" --version 2>/dev/null || true)"
    major="${ver#v}"; major="${major%%.*}"
    if [[ "$major" == "$NODE_MAJOR" ]]; then
      skip "omniroute: managed Node.js $ver present ($NODE_DIR)"
    else
      echo "  omniroute: managed node at $NODE_DIR is ${ver:-unreadable} — omniroute requires v$NODE_MAJOR.x, reinstalling"
      install_node
    fi
  else
    echo "  omniroute requires the managed Node.js v$NODE_MAJOR.x (setup.sh --node) — installing it first"
    install_node
  fi
  # Present is not enough: THIS run must resolve node/npm to the managed
  # install even when PATH prefers the platform node (the usual case).
  export PATH="$NODE_DIR/bin:$PATH"
  # Hard-verify what the run will actually use — fail loudly, never fall
  # back to whatever node PATH would otherwise have found.
  local resolved; resolved="$(command -v node 2>/dev/null || true)"
  [[ -n "$resolved" && "$(readlink -f "$resolved")" == "$(readlink -f "$bin")" ]] \
    || die "omniroute: node resolves to '${resolved:-nothing}' after ensuring the managed node — expected $bin. Fix PATH and re-run."
  ver="$(node --version 2>/dev/null || true)"
  major="${ver#v}"; major="${major%%.*}"
  [[ "$major" == "$NODE_MAJOR" ]] \
    || die "omniroute: node is ${ver:-unknown} — omniroute requires the managed v$NODE_MAJOR.x (the platform nix node would land the npm-global install in the wrong prefix). Re-run: bash $SETUP_ENTRY --machine repl --node"
  command -v npm >/dev/null 2>&1 \
    || die "omniroute: npm not on PATH after ensuring the managed node ($NODE_DIR/bin)"
  ok "omniroute: using managed Node.js $ver ($bin)"
}

omniroute_write_env_example() {
  # A fill-in TEMPLATE for the server config, dropped by setup next to
  # the real .env in $OMNIROUTE_HOME — refreshed on every --omniroute
  # run (it is a template, not user config; the real .env next to it is
  # never created or overwritten by setup). DATA_DIR is written with
  # the RESOLVED home path: dotenv does not expand $XDG_CONFIG_HOME,
  # so a copied .env must carry the literal dir.
  local f="$OMNIROUTE_HOME/.env.example"
  mkdir -p "$(dirname "$f")" || return 0
  cat > "$f" <<EOF
# OmniRoute config — copy this file to ".env" in this same directory
# and fill in the values. Only the vars you set are used.
#
# Precedence ("big env" rule): a var already set in the system
# environment WINS; this file only fills gaps — so a var that is also
# set as a Replit Secret / [userenv.shared] value shadows the value
# here for that var.
#
# DATA_DIR points at THIS directory on purpose: the server's data
# lives outside the npm install path, so it survives an uninstall,
# and \`setup.sh --clean omniroute\` preserves it (it removes only
# the npm package + bins).
#
# Template written by setup.sh --omniroute; safe to regenerate, never
# read by the server itself. The real ".env" next to it is never
# created or overwritten by setup.

# Port + bind host of the OpenAI-compatible gateway.
PORT=9000
OMNIROUTE_SERVER_HOST=0.0.0.0

# Server data (provider accounts, keys, usage) — outside the package.
DATA_DIR=$OMNIROUTE_HOME

NODE_ENV=production
EOF
  ok "omniroute config template: $f (copy to .env and fill in)"
}

install_omniroute() {
  step "OmniRoute AI router (npm-global omniroute@$OMNIROUTE_VERSION)"
  # FIRST: the managed Node.js $NODE_MAJOR — the npm-global prefix is a
  # function of the node that runs the install (see the header).
  omniroute_ensure_node
  mkdir -p "$XDG_BIN_HOME" "$OMNIROUTE_HOME"

  # Package (idempotent; global install resolves fast on re-run).
  # NODE_ENV is unset for the install itself: an ambient
  # NODE_ENV=production (the value the server runs with, per the
  # template) makes npm skip devDependencies while resolving the
  # package tree, which is not the install the published package
  # expects.
  echo "  npm install -g omniroute@$OMNIROUTE_VERSION"
  env -u NODE_ENV npm install -g "omniroute@$OMNIROUTE_VERSION" --registry=https://registry.npmjs.org/ \
    || die "npm install -g omniroute@$OMNIROUTE_VERSION failed"
  [[ -x "$NODE_DIR/bin/omniroute" ]] \
    || die "omniroute binary not at $NODE_DIR/bin/omniroute after install"

  local ver; ver="$(node -p "require('$(omniroute_pkg_dir)/package.json').version" 2>/dev/null || true)"
  [[ -n "$ver" ]] \
    || warn "omniroute: could not read the installed version from $(omniroute_pkg_dir)/package.json"

  omniroute_write_env_example

  record_tool_env_vars OMNIROUTE_HOME
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool omniroute OMNIROUTE_HOME -- "$XDG_BIN_HOME"

  ok "omniroute ${ver:-$OMNIROUTE_VERSION} installed — put the real config in $OMNIROUTE_HOME/.env (see .env.example there), then run: omniroute"
}

clean_omniroute() {
  local pkg; pkg="$(omniroute_pkg_dir)"
  if ! _present "$pkg" "$NODE_DIR/bin/omniroute" "$XDG_BIN_HOME/omniroute"; then
    nothing_removed "OmniRoute"; return 0
  fi
  step "Removing OmniRoute AI router"
  if command -v npm >/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g omniroute \
      || warn "npm uninstall -g omniroute failed — remove $pkg by hand"
  fi
  rm -f "$NODE_DIR/bin/omniroute" "$NODE_DIR/bin/omniroute-reset-password" \
        "$XDG_BIN_HOME/omniroute" "$XDG_BIN_HOME/omniroute-reset-password"
  rm -rf "$pkg"
  # Operator config + server data ($OMNIROUTE_HOME — the .env AND the
  # DATA_DIR content) is user data — kept; delete $OMNIROUTE_HOME by
  # hand to wipe it.
  ok "OmniRoute removed (npm package + bins; config + data kept in $OMNIROUTE_HOME)"
}
