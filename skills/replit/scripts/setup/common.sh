# shellcheck shell=bash
# Environment, paths, mode detection and shared registries. Sourced by setup.sh.
JAVA_HOME="$XDG_DATA_HOME/java"
SDK="$XDG_DATA_HOME/android-sdk"
NODE_DIR="$XDG_DATA_HOME/node"
# npm's ONLY global prefix (where `-g` installs actually land — Replit pins
# this via the inherited env). Captured BEFORE the node-toolchain override
# below so clean_* can uninstall globally-installed packages from the real
# location, not the (possibly empty) $NODE_DIR.
NPM_GLOBAL_PREFIX="${npm_config_prefix:-}"
npm_config_prefix="$NODE_DIR"
JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTS_VALUE"

# uv runs its own managed Python: download whatever version a project pins
# (UV_PYTHON_DOWNLOADS=auto) instead of erroring on a missing system one
# (UV_PYTHON_PREFERENCE=managed). PYTHONPATH is emptied so an inherited
# Nix/agent PYTHONPATH (pointing at the read-only store Python) can't poison
# uv's managed interpreter. Defined HERE (not in install_uv) so
# rescue_userenv_keys can carry them forward on runs that skip the installer.
UV_PYTHON_DOWNLOADS="auto"
UV_PYTHON_PREFERENCE="managed"
PYTHONPATH=""

# TLS / CA bundle — the PLATFORM location, /etc/ssl/certs, always. NOT the Nix
# cacert bundle ($SYSTEM_CERTIFICATE_PATH / pkgs.cacert): that bundle carries
# none of the Replit roots (0 Replit-named subjects vs 2 in the system bundle,
# "Replit internal proxy Root CA" and "Replit Localhost Development CA"), so
# wiring it in REPLACES a trust store that knows the proxy with one that does
# not — the public registry still answers 200 while proxied hosts
# (*.replit.dev, connectors) fail, which is painful to attribute. It is also a
# pinned /nix/store path: after a rebuild or GC the variable points at a
# missing file, and a missing SSL_CERT_FILE breaks every TLS client outright.
# curl/node/python all reach the registry with these unset; they are exported
# because tools that ignore the platform default (Node keeps its OWN bundled
# roots) need the Replit roots added — hence NODE_EXTRA_CA_CERTS.
# The guard is the bundle itself, so nothing is ever exported as a dead path.
_TLS_ENV_VARS=()
if [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  SSL_CERT_DIR=/etc/ssl/certs
  NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"
  REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
  export SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE
  _TLS_ENV_VARS=(SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE)
fi

ORI_CONFIG_DIR="$XDG_CONFIG_HOME/ori"

# Replit platform sets XDG_CONFIG_HOME=$REPL_HOME/.config, so this
# resolves to REPL_HOME/.config/claude — persistent, survives $HOME wipes.
CLAUDE_CONFIG_DIR="$XDG_CONFIG_HOME/claude"

OPENCODE_CONFIG_DIR="$XDG_CONFIG_HOME/opencode"

HERMES_HOME="${REPL_HOME:-$HOME}/.hermes"
# Hermes' two env vars and the dir that holds the real launcher. All three are
# ordinary wire-registered tool vars/PATH dirs now (the pre-merge layout kept
# them in a separate rc block outside the managed one, which every rewrite then
# had to re-append to keep PATH precedence stable). The launcher dir is the
# ONLY provider of `hermes` / `hermes-acp` on this box: $XDG_BIN_HOME holds just
# the chrome shim, no forwarder, so PATH order cannot pick a different binary.
HERMES_LAUNCHER_DIR="$HERMES_HOME/hermes-agent/.hermes/bin"
# Managed-scope dir: Hermes defaults to /etc/hermes, which on Replit is a
# read-only mount that cannot be created without root, so it is pinned under
# HERMES_HOME. Exported with HERMES_HOME so interactive, gateway and workflow
# shells all resolve the same scope.
HERMES_MANAGED_DIR="$HERMES_HOME/managed"

# zsh interactive shell (oh-my-zsh + powerlevel10k). Binaries come from a
# durable nix profile, the framework and dotfiles from $XDG_DATA_HOME and
# $XDG_CONFIG_HOME/zsh. ZDOTDIR is what lets a bare `zsh` find them: there
# is no $HOME/.zshrc, and $HOME is wiped on recreate.
NIX_PROFILE_DIR="${REPL_HOME:-$HOME}/.local/nix-profiles"
ZSH_PROFILE="$NIX_PROFILE_DIR/zsh"
ZSH_DIR="$XDG_DATA_HOME/oh-my-zsh"
ZSH_DOTDIR="$XDG_CONFIG_HOME/zsh"
export ZDOTDIR="$ZSH_DOTDIR"

# CLIProxyAPI — persistent app dir. Follows the XDG rule every other tool
# uses ($XDG_CONFIG_HOME/<tool>), so it does NOT scatter a dir in the
# workspace root next to the user's repos. A pre-existing legacy manual
# install at $REPL_HOME/cli-proxy is still honored (see install_cliproxy),
# so nobody's config/ OAuth logins get orphaned by the move.
CLIPROXY_LEGACY_HOME="${REPL_HOME:-$HOME}/cli-proxy"
if [[ -f "$CLIPROXY_LEGACY_HOME/config.yaml" ]]; then
  CLIPROXY_HOME="$CLIPROXY_LEGACY_HOME"
else
  CLIPROXY_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/cli-proxy"
fi

OLLAMA_INSTALL_DIR="$XDG_DATA_HOME/ollama"
OLLAMA_MODELS="$OLLAMA_INSTALL_DIR/models"

# tailscale user data (node key + login) — preserved by `--clean tailscale`.
# The binaries themselves live in $XDG_BIN_HOME, like the other direct-download
# tools (see setup/expose.sh).
TAILSCALE_DATA_DIR="$XDG_DATA_HOME/tailscale"

# Tool dirs exported ONCE for child processes — the rest of the script
# uses the values directly (no re-exporting inline in install functions).
ANDROID_HOME="$SDK"
export JAVA_HOME ANDROID_HOME NODE_DIR \
       OPENCODE_CONFIG_DIR \
       CLAUDE_CONFIG_DIR ORI_CONFIG_DIR \
       HERMES_HOME HERMES_MANAGED_DIR OLLAMA_INSTALL_DIR OLLAMA_MODELS

# Make binaries discoverable for the rest of this script run.
# Snapshot the INCOMING PATH first: doctor's "XDG_BIN_HOME on PATH" check
# must test the user's shell wiring, not the PATH this script just built
# (otherwise the export below makes the check self-fulfilling).
_ENTRY_PATH="$PATH"
export PATH="$XDG_BIN_HOME:$JAVA_HOME/bin:$SDK/cmdline-tools/bin:$SDK/platform-tools:$NODE_DIR/bin:$PATH"

# Per-tool registration ─────────────────────────────────────────────────────
# Each install function registers (a) the env vars the tool needs and (b) the
# PATH dirs its binaries live in. [userenv.shared] writers emit ONLY what was
# registered this run — a --node-only install must not resurrect JAVA_HOME or
# JAVA's PATH dirs (the rc lines are inert for missing dirs, but userenv keys
# are not: they shadow whatever the platform env had).
_TOOL_ENV_VARS=()
_TOOL_PATH_DIRS=()
# Installers run inside run_install_step's SUBSHELL, so an array append there
# dies with the subshell. Mirror every registration into a spill file (which a
# subshell CAN write) and fold it back after the install loop — this is what
# keeps an installer's declared wiring from being silently dropped.
_TOOL_WIRING_SPILL="${_TOOL_WIRING_SPILL:-$(mktemp)}"
export _TOOL_WIRING_SPILL
_load_wiring_add() {  # $1=E|P  $2=name  (no spill write; used by the load pass)
  case "$1" in
    E) [[ " ${_TOOL_ENV_VARS[*]-} " == *" $2 "* ]] || _TOOL_ENV_VARS+=("$2") ;;
    P) [[ " ${_TOOL_PATH_DIRS[*]-} " == *" $2 "* ]] || _TOOL_PATH_DIRS+=("$2") ;;
  esac
}
record_tool_env_vars() {
  # Idempotent: the same var can register twice (installer AND fix_derive_wiring,
  # or two installers sharing one), which would emit the export twice.
  local v
  for v in "$@"; do
    _load_wiring_add E "$v"
    [[ -n "${_TOOL_WIRING_SPILL:-}" ]] && printf 'E %s\n' "$v" >> "$_TOOL_WIRING_SPILL"
  done
}
record_tool_path_dirs() {
  local d
  for d in "$@"; do
    _load_wiring_add P "$d"
    [[ -n "${_TOOL_WIRING_SPILL:-}" ]] && printf 'P %s\n' "$d" >> "$_TOOL_WIRING_SPILL"
  done
}
load_wiring_spill() {  # fold in registrations made in installer subshells
  [[ -s "${_TOOL_WIRING_SPILL:-}" ]] || return 0
  local kind val
  while IFS=' ' read -r kind val; do
    [[ -n "$val" ]] && _load_wiring_add "$kind" "$val"
  done < "$_TOOL_WIRING_SPILL"
  : > "$_TOOL_WIRING_SPILL"   # consumed; later appends start clean
}

# Per-tool OWNERSHIP wiring: each install function declares which env
# vars and PATH dirs belong to it, so per-tool `--clean <tool>` can drop
# exactly that tool's lines from the managed block (rc + .replit) instead
# of stripping everything.
declare -A -A _WIRE_OWNER=()
wire_tool() {
  local tool="$1"; shift
  local item
  for item in "$@"; do
    if [[ "$item" == "--" ]]; then in_dirs=true; continue; fi
    [[ -n "${_WIRE_OWNER[$item]:-}" ]] && _WIRE_OWNER["$item"]+="," || true
    _WIRE_OWNER["$item"]+="$tool"
  done
}
env_var_owner()  { printf '%s' "${_WIRE_OWNER[$1]:-}"; }
path_dir_owner() { printf '%s' "${_WIRE_OWNER[$1]:-}"; }
owned_only_by(){
  # True when EVERY owner in comma-joined $1 appears in space-joined $2.
  # Empty owner list -> false (unregistered lines are always kept).
  local owners cleaned it
  owners="${1//,/ }"
  [[ -n "${owners// /}" ]] || return 1
  cleaned=" $2 "
  for it in $owners; do
    [[ "$cleaned" == *" $it "* ]] || return 1
  done
  return 0
}

seed_tool_wiring(){
  # Static ownership registrations (mirrors the wire_tool calls in the
  # install functions) so --clean can resolve line owners without
  # running an installer. wire_tool is an idempotent map assignment.
  wire_tool uv UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH -- "$XDG_BIN_HOME"
  wire_tool android JAVA_HOME ANDROID_HOME JAVA_TOOL_OPTIONS -- "$JAVA_HOME/bin" "$SDK/cmdline-tools/bin" "$SDK/platform-tools" "$XDG_BIN_HOME"
  wire_tool node NODE_DIR npm_config_prefix "${_TLS_ENV_VARS[@]}" -- "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
  wire_tool opencode OPENCODE_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool ollama OLLAMA_INSTALL_DIR OLLAMA_MODELS -- "$XDG_BIN_HOME"
  wire_tool claude CLAUDE_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool hermes HERMES_HOME HERMES_MANAGED_DIR -- "$HERMES_LAUNCHER_DIR"
  wire_tool ori ORI_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool rclone -- "$XDG_BIN_HOME"
  wire_tool qbt -- "$XDG_BIN_HOME"
  wire_tool aria2 -- "$XDG_BIN_HOME"
  wire_tool ffmpeg -- "$XDG_BIN_HOME"
  wire_tool cloudflared -- "$XDG_BIN_HOME"
  wire_tool tailscale -- "$XDG_BIN_HOME"
  wire_tool sshx -- "$XDG_BIN_HOME"
  wire_tool cliproxy CLIPROXY_HOME -- "$XDG_BIN_HOME" "$CLIPROXY_HOME"
  wire_tool camofox CAMOUFOX_INSTALL_DIR CAMOFOX_STATE_DIR CAMOFOX_PROFILE_DIR \
    CAMOFOX_COOKIES_DIR CAMOFOX_UPLOADS_DIR CAMOFOX_TRACES_DIR -- "$XDG_BIN_HOME"
  wire_tool hermes-chromium HERMES_CHROME_STATE -- "$XDG_BIN_HOME"
  # Kept in sync with install_hermes_chromium: a --fix run with no staged chrome
  # never calls the installer, so the export has to be re-derived here or the rc
  # block loses it and Hermes' browser starts a chrome without the lib closure.
  if [[ -x "$XDG_BIN_HOME/launch-hermes-chrome" ]]; then
    export AGENT_BROWSER_EXECUTABLE_PATH="$XDG_BIN_HOME/launch-hermes-chrome"
    record_tool_env_vars AGENT_BROWSER_EXECUTABLE_PATH
  fi
}

# State flags ───────────────────────────────────────────────────────────────
INSTALL_ANDROID=false
INSTALL_NODE=false
INSTALL_OPENCODE=false
INSTALL_OLLAMA=false
INSTALL_CLAUDE=false
INSTALL_HERMES=false
INSTALL_ORI=false
INSTALL_UV=false
INSTALL_RCLONE=false
INSTALL_QBT=false
INSTALL_ARIA2=false
INSTALL_FFMPEG=false
INSTALL_CLOUDFLARED=false
INSTALL_TAILSCALE=false
INSTALL_SSHX=false
INSTALL_CLIPROXY=false
INSTALL_CAMOFOX=false
INSTALL_HERMES_CHROMIUM=false
INSTALL_LLM_WIKI=false
INSTALL_ZSH=false
INSTALL_ALL=false
DOCTOR=false
FIX=false
CLEAN=false
LIST_STATE=false
YES=false
# Install failures accumulated by run_install_step (`--all` / multi-tool runs).
# One broken tool must not abort the rest of the run — see run_install_step.
_INSTALL_FAILURES=()
# User-data backups taken by back_up_tool before a destructive clean (--clean).
_BACKUPS_TAKEN=()
# Tools whose removal was refused because their backup failed.
_CLEAN_SKIPPED=()
# Empty means BARE --clean (no target): main() opens the clean menu on a
# terminal and defaults to 'all' when non-interactive. Set to a tool
# name (or 'all') when the user gave an explicit target — skips the menu.
CLEAN_TARGET=""
# Tools ticked in the clean menu (same menu, same "tick to select" behavior as
# install — every item starts UNCHECKED; you tick what to remove). An empty
# selection removes nothing; only explicit `--clean all` strips env wiring.
CLEAN_TOOLS=()
# Which menu the script opens: install (pick tools to install) or clean
# (pick tools to remove). The same menu serves both.
MENU_MODE="install"
# Exit trap accumulator — multiple functions register cleanup actions
# without overwriting each other's traps.
_EXIT_ACTIONS=()
add_exit_action() { _EXIT_ACTIONS+=("$1"); }
_run_exit_actions() {
  local rc=$?
  local action
  for action in "${_EXIT_ACTIONS[@]}"; do
    eval "$action" || true
  done
  exit $rc
}
trap '_run_exit_actions' EXIT

# Per-tool isolation ─────────────────────────────────────────────────────────
# installers call `die` on failure, and `die` exits the whole script. Under
# `--all` / multi-tool runs one broken tool (bad download, missing upstream
# asset, …) must NOT abort the rest: run_install_step runs each installer in
# its own errexit subshell, catches the failure and records it, then the run
# carries on to the next tool. The summary + exit code reflect what failed.
#
# A subshell inherits the parent EXIT trap; the trap is cleared inside so a
# failing installer's `exit 1` cannot run the parent's exit actions early.
run_install_step() {
  local label="$1"; shift
  local rc=0
  set +e
  ( trap - EXIT; set -e; "$@" )
  rc=$?
  set -e
  if (( rc != 0 )); then
    warn "$label failed (exit $rc) — continuing with the remaining tools"
    _INSTALL_FAILURES+=("$label")
    return 0
  fi
  return 0
}

# Summary + exit status for a multi-tool install run. Reuses the same
# wording doctor uses (missing tools are an install-scope fact, not a wiring
# bug) and returns 1 when anything failed so scripts can gate on it.
install_fail_summary() {
  ((${#_INSTALL_FAILURES[@]})) || return 0
  echo ""
  warn "Some tools did NOT install: ${_INSTALL_FAILURES[*]}"
  warn "Re-run just those, e.g.  bash setup.sh --${_INSTALL_FAILURES[0]}"
  return 1
}
