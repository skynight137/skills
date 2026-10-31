#!/bin/bash
# camofox MCP adapter for Hermes — LOCAL process, DIRECT https to a remote repl.
#
# Why a wrapper: the adapter is stdio-only and a thin proxy to CAMOFOX_BASE_URL,
# but (a) node needs the toolchain lib pool on LD_LIBRARY_PATH (libatomic), and
# (b) Hermes does NOT expand ${VAR} inside mcp_servers.*.env, so the access keys
# must be loaded here from the profile .env instead of living in config.yaml.
#
# Register (per profile — `hermes chat` reads the profile config while a bare
# `hermes mcp add` writes the default one, so do both):
#   hermes mcp add camofox --command <this-file> \
#     --env CAMOFOX_BASE_URL=https://<repl>.replit.dev \
#           CAMOFOX_USER_ID=hermes-default CAMOFOX_SESSION_KEY=default \
#           CAMOFOX_COOKIES_DIR=<repl-home>/.config/camofox/cookies
#   hermes -p <profile> mcp add camofox --command <this-file> --env ... (same)
#
# Env it honours: REPL_HOME (default /home/runner/workspace), HERMES_PROFILE
# (default syad), CAMOFOX_ENV_FILE (override the profile .env path).
# The server side must be running (workflow `launch-camofox-browser` on :80).
set -u
REPL_HOME="${REPL_HOME:-/home/runner/workspace}"
PROFILE="${HERMES_PROFILE:-syad}"
CAMOFOX_ENV_FILE="${CAMOFOX_ENV_FILE:-$REPL_HOME/.hermes/profiles/$PROFILE/.env}"
NODE_HOME="${NODE_HOME:-$REPL_HOME/.local/share/node}"
ADAPTER="$NODE_HOME/lib/node_modules/@askjo/camofox-browser-mcp/server.mjs"

if [ -z "${CAMOFOX_ACCESS_KEY:-}" ] && [ -r "$CAMOFOX_ENV_FILE" ]; then
  CAMOFOX_ACCESS_KEY=$(grep -m1 '^CAMOFOX_ACCESS_KEY=' "$CAMOFOX_ENV_FILE" | cut -d= -f2-)
  CAMOFOX_API_KEY=$(grep -m1 '^CAMOFOX_API_KEY=' "$CAMOFOX_ENV_FILE" | cut -d= -f2-)
fi
export CAMOFOX_ACCESS_KEY="${CAMOFOX_ACCESS_KEY:-}" CAMOFOX_API_KEY="${CAMOFOX_API_KEY:-}"
[ -n "$CAMOFOX_ACCESS_KEY" ] || echo "camofox-mcp: no CAMOFOX_ACCESS_KEY in $CAMOFOX_ENV_FILE (expect 401)" >&2

export LD_LIBRARY_PATH="$REPL_HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$NODE_HOME/bin:$PATH"

[ -f "$ADAPTER" ] || { echo "camofox-mcp: adapter missing ($ADAPTER) — run: setup.sh --camofox" >&2; exit 1; }
exec node "$ADAPTER"