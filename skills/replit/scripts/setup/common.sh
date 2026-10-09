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

# Node 26 niceties (owned by the `node` tool — see seed_tool_wiring).
# npm refuses lifecycle scripts by default now; the env form is read exactly
# like the config file (verified) and, unlike `npm config set ... -g` writing
# $HOME/.npmrc, it survives $HOME being wiped.
npm_config_dangerously_allow_all_scripts="${npm_config_dangerously_allow_all_scripts:-true}"

# TLS / CA bundle derived from the Nix cacert package. `pkgs.cacert` (declared
# in .replit [nix] packages) exports SYSTEM_CERTIFICATE_PATH; these four are
# the variables curl/npm/node consult. Empty on a box without that package, in
# which case nothing is pinned and the platform defaults apply.
_TLS_ENV_VARS=()
if [[ -n "${SYSTEM_CERTIFICATE_PATH:-}" ]]; then
  # The Nix bundle lacks the Replit proxy root, so Node, Python (urllib/httpx) and
  # requests fail on *.replit.dev. The system bundle trusts it. Use it when it
  # exists; fall back to the Nix bundle otherwise. Verification stays on.
  _SYS_CA=/etc/ssl/certs/ca-certificates.crt
  _CA="$SYSTEM_CERTIFICATE_PATH"
  [[ -r "$_SYS_CA" ]] && _CA="$_SYS_CA"
  SSL_CERT_FILE="$_CA"
  SSL_CERT_DIR="$(dirname "$SYSTEM_CERTIFICATE_PATH")"
  NIX_SSL_CERT_FILE="$SYSTEM_CERTIFICATE_PATH"
  NODE_EXTRA_CA_CERTS="$_CA"
  REQUESTS_CA_BUNDLE="$_CA"
  export SSL_CERT_FILE SSL_CERT_DIR NIX_SSL_CERT_FILE NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE
  _TLS_ENV_VARS=(SSL_CERT_FILE SSL_CERT_DIR NIX_SSL_CERT_FILE NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE)
fi

ORI_CONFIG_DIR="$XDG_CONFIG_HOME/ori"

# Replit platform sets XDG_CONFIG_HOME=$REPL_HOME/.config, so this
# resolves to REPL_HOME/.config/claude — persistent, survives $HOME wipes.
CLAUDE_CONFIG_DIR="$XDG_CONFIG_HOME/claude"

OPENCODE_CONFIG_DIR="$XDG_CONFIG_HOME/opencode"

HERMES_HOME="${REPL_HOME:-$HOME}/.hermes"

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

# Tool dirs exported ONCE for child processes — the rest of the script
# uses the values directly (no re-exporting inline in install functions).
ANDROID_HOME="$SDK"
export JAVA_HOME ANDROID_HOME NODE_DIR \
       OPENCODE_CONFIG_DIR \
       CLAUDE_CONFIG_DIR ORI_CONFIG_DIR \
       HERMES_HOME OLLAMA_INSTALL_DIR OLLAMA_MODELS

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
  wire_tool node NODE_DIR npm_config_prefix npm_config_dangerously_allow_all_scripts "${_TLS_ENV_VARS[@]}" -- "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
  wire_tool opencode OPENCODE_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool ollama OLLAMA_INSTALL_DIR OLLAMA_MODELS -- "$XDG_BIN_HOME"
  wire_tool claude CLAUDE_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool hermes HERMES_HOME -- "${REPL_HOME:-$HOME}"
  wire_tool ori ORI_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool rclone -- "$XDG_BIN_HOME"
  wire_tool qbt -- "$XDG_BIN_HOME"
  wire_tool aria2 -- "$XDG_BIN_HOME"
  wire_tool ffmpeg -- "$XDG_BIN_HOME"
  wire_tool cliproxy CLIPROXY_HOME -- "$XDG_BIN_HOME" "$CLIPROXY_HOME"
  wire_tool camofox CAMOUFOX_INSTALL_DIR CAMOFOX_STATE_DIR CAMOFOX_PROFILE_DIR \
    CAMOFOX_COOKIES_DIR CAMOFOX_UPLOADS_DIR CAMOFOX_TRACES_DIR -- "$XDG_BIN_HOME"
  wire_tool hermes-chromium HERMES_CHROME_STATE -- "$XDG_BIN_HOME"
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
INSTALL_CLIPROXY=false
INSTALL_CAMOFOX=false
INSTALL_HERMES_CHROMIUM=false
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
