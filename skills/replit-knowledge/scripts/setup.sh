#!/usr/bin/env bash
# scripts/setup.sh

set -euo pipefail

# Absolute path of this script's directory — the tomlkit .replit writer
# (replit_userenv.py) lives next to setup.sh.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Mode (auto-detected from the environment — no flag) ─────────────────────────
# Set BEFORE the XDG defaults below because the path roots depend on mode:
#   replit:  everything under $REPL_HOME (persistent; $HOME is wiped)
#   default: $HOME (foklow/official layout: ~/.local, ~/.config, ~/.bashrc)
# "Are we on Replit?" is asked of the environment, not arguments: the
# Replit agent sets REPL_HOME to the workspace. If $REPL_HOME is a real
# directory we install the persistent Replit layout; otherwise the $HOME layout.
if [[ -n "${REPL_HOME:-}" && -d "${REPL_HOME:-}" ]]; then
  REPLIT_MODE=true
else
  REPLIT_MODE=false
fi

# Version / URL config ──────────────────────────────────────────────────────
JAVA_MAJOR="24"
NODE_MAJOR="26"
ANDROID_PLATFORM="android-37.0"
ANDROID_BUILD_TOOLS="37.0.0"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
JAVA_TOOL_OPTS_VALUE="-XX:-UsePerfData --enable-native-access=ALL-UNNAMED"

# AI coding (direct binary downloads — no curl|bash installers)
OPENCODE_REPO="anomalyco/opencode"
CLAUDE_RELEASE_BASE="https://downloads.claude.ai/claude-code-releases"
ORI_RELEASE_BASE="https://github.com/OpenRouterLabs/ori-releases/releases/latest/download"

# Download / media tools (direct binaries — no curl|bash, no installers)
# rclone: official current-release channel (versionless symlink on
# downloads.rclone.org — the canonical mirror of github.com/rclone/rclone/releases).
RCLONE_DOWNLOAD_BASE="https://downloads.rclone.org"
# qbittorrent-nox: static single binary, arch-prefixed asset name.
QBT_RELEASE_BASE="https://github.com/userdocs/qbittorrent-nox-static/releases/latest/download"
# aria2c: github.com/aria2/aria2 releases ship SOURCE ONLY (no Linux binary);
# abcfy2/aria2-static-build repackages those releases as static musl binaries.
ARIA2_RELEASE_BASE="https://github.com/abcfy2/aria2-static-build/releases/latest/download"
# ffmpeg: BtbN static GPL builds (newer than the Replit Nix-built ffmpeg 6.1.2).
FFMPEG_RELEASE_BASE="https://github.com/BtbN/FFmpeg-Builds/releases/latest/download"

# AI agent
HERMES_INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"

# Paths ──────────────────────────────────────────────────────────────────────
# replit mode (auto): $REPL_HOME is the only persistent dir ($HOME wiped on
# restart), so the workspace and every XDG dir must live under it.
# default (foklow/official layout): workspace is the current dir, XDG dirs
# under $HOME.
if [[ "$REPLIT_MODE" == true ]]; then
  WORKSPACE="$REPL_HOME"
else
  WORKSPACE="$(pwd)"
fi
cd "$WORKSPACE"

# XDG roots per mode (the design decision env auto-detection drives) ──────────
# Both branches must end with the FIVE vars below set, each honoring a
# pre-set XDG_* value (the platform/operator may have chosen one):
#   XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_BIN_HOME
# replit:  pre-set wins, else fall back UNDER $WORKSPACE (persistent).
#          $HOME is forbidden — wiped on restart.
# default: pre-set wins, else canonical $HOME paths (~/.config, ...).
# NOTE (soft assumption — tweak if needed): the rc target in replit mode is
# replit rc target: $WORKSPACE/.config/bashrc - the Replit bootstrap auto-sources it (see _bashrc_candidate).
# fallback file if that is ever not writable. XDG_BIN_HOME is the single PATH
# entry every tool binary lands in. Var names below are load-bearing: the
# rest of the script, the emitted shell rc, and [userenv.shared] all read them.
if [[ "$REPLIT_MODE" == true ]]; then
  XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$WORKSPACE/.config}"
  XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORKSPACE/.cache}"
  XDG_DATA_HOME="${XDG_DATA_HOME:-$WORKSPACE/.local/share}"
  XDG_STATE_HOME="${XDG_STATE_HOME:-$WORKSPACE/.local/state}"
  XDG_BIN_HOME="${XDG_BIN_HOME:-$WORKSPACE/.local/bin}"
else
  XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
  XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
  XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
  XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
  XDG_BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
fi
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_BIN_HOME WORKSPACE

# Binaries live in XDG_BIN_HOME (single PATH entry). Use directly —
# no redundant alias.

# Shell target.
# replit mode: managed rc lives at $WORKSPACE/.config/bashrc — the
# platform-native persistent slot Replit's bootstrap (/home/runner/.bashrc)
# sets BASHRC="${REPL_HOME}/.config/bashrc" and sources it as ${BASHRC}
# (guarded by a -f check + REPLIT_MODE unset — i.e. interactive consoles
# only). Lives under the persistent workspace, so it survives container
# recreate (unlike $HOME, which is wiped). One file; no bare root rc.
#
# CONSOLES vs WORKFLOWS — two different hooks, both needed:
#   - interactive consoles read $BASHRC (above), so they need no pin;
#   - workflow tasks run bash NON-interactively, never read $BASHRC, and
#     instead bootstrap through $REPLIT_BASHRC (which the platform presets
#     to the read-only Nix-store bashrc). We therefore DO pin
#     REPLIT_BASHRC in [userenv.shared] — see write_replit_bashrc — pointing
#     it at $XDG_CONFIG_HOME/replit_bashrc, a thin `source ~/.bashrc` shim.
#     This SUPERSEDES the older note that the pin was a no-op: that
#     observation was about the console path, where the platform's own
#     value (and $BASHRC) legitimately win. For workflows the pin is the
#     only thing that reaches them. The platform overriding the key in
#     consoles is harmless — $BASHRC still wins there.
# default (non-replit): $HOME/.bashrc.
_bashrc_candidate(){
  if [[ "$REPLIT_MODE" != true ]]; then
    echo "$HOME/.bashrc"
    return
  fi
  echo "$WORKSPACE/.config/bashrc"
}
BASHRC="${BASHRC:-$(_bashrc_candidate)}"

# Workflow bashrc shim (replit mode) ─────────────────────────────────────────
# Replit workflows run their tasks in a NON-INTERACTIVE shell. That shell
# never sources the interactive rc above, so a workflow process (shell.exec
# tasks in .replit, the Run button, deploys) inherited none of the toolchain
# env — managed binaries in XDG_BIN_HOME were "command not found" even though
# the same command worked in the user's terminal.
#
# Non-interactive bash instead sources the file named by $BASH_ENV, and the
# platform points that at the file named by $REPLIT_BASHRC. Pinning
# REPLIT_BASHRC to this shim is what closes the gap: the shim is a thin
# `source ~/.bashrc` so workflows get exactly the user terminal's env.
#
# Deliberately a DIFFERENT file from $BASHRC: $BASHRC is the user rc
# (setup-managed, writable, may be edited by the operator); this shim is
# fixed wiring that must not drift, so it is regenerated on every run.
REPLIT_BASHRC_FILE="${REPLIT_BASHRC_FILE:-}"
if [[ "$REPLIT_MODE" == true ]]; then
  REPLIT_BASHRC_FILE="${REPLIT_BASHRC_FILE:-$XDG_CONFIG_HOME/replit_bashrc}"
fi

# Snapshot the environment (name → value) BEFORE the script assigns or
# exports anything — input to write_replit_env's no-shadowing rule. Values
# matter, not names: our own previous managed block comes back through the
# inherited env on re-runs (userenv feeds every repl) and must be re-emitted,
# not mistaken for operator choices.
declare -A -A _PRESET_ENV=()
# compgen prints BARE variable names (one per line, no value) — read each
# name and capture its VALUE via ${!name}. (The old "read line, split on ="
# form broke on '=' in input, storing name→name so no-shadowing never
# actually compared values.) Names are valid identifiers, safe to index.
while IFS= read -r _env_name; do
  [[ "$_env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && _PRESET_ENV["$_env_name"]="${!_env_name}"
done < <(compgen -e)

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

ORI_CONFIG_DIR="$XDG_CONFIG_HOME/ori"

# Replit platform sets XDG_CONFIG_HOME=$REPL_HOME/.config, so this
# resolves to REPL_HOME/.config/claude — persistent, survives $HOME wipes.
CLAUDE_CONFIG_DIR="$XDG_CONFIG_HOME/claude"

OPENCODE_CONFIG_DIR="$XDG_CONFIG_HOME/opencode"

HERMES_HOME="${REPL_HOME:-$HOME}/.hermes"

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
export PATH="$XDG_BIN_HOME:$JAVA_HOME/bin:$SDK/cmdline-tools/bin:$SDK/platform-tools:$NODE_DIR/bin:$PATH"

# Per-tool registration ─────────────────────────────────────────────────────
# Each install function registers (a) the env vars the tool needs and (b) the
# PATH dirs its binaries live in. [userenv.shared] writers emit ONLY what was
# registered this run — a --node-only install must not resurrect JAVA_HOME or
# JAVA's PATH dirs (the rc lines are inert for missing dirs, but userenv keys
# are not: they shadow whatever the platform env had).
_TOOL_ENV_VARS=()
_TOOL_PATH_DIRS=()
record_tool_env_vars() { _TOOL_ENV_VARS+=("$@"); }
record_tool_path_dirs() { _TOOL_PATH_DIRS+=("$@"); }

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
  wire_tool node NODE_DIR npm_config_prefix -- "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
  wire_tool opencode OPENCODE_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool ollama OLLAMA_INSTALL_DIR OLLAMA_MODELS -- "$XDG_BIN_HOME"
  wire_tool claude CLAUDE_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool hermes HERMES_HOME -- "${REPL_HOME:-$HOME}"
  wire_tool ori ORI_CONFIG_DIR -- "$XDG_BIN_HOME"
  wire_tool rclone -- "$XDG_BIN_HOME"
  wire_tool qbt -- "$XDG_BIN_HOME"
  wire_tool aria2 -- "$XDG_BIN_HOME"
  wire_tool ffmpeg -- "$XDG_BIN_HOME"
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
INSTALL_ALL=false
DOCTOR=false
CLEAN=false
LIST_STATE=false
YES=false
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

# Helpers ───────────────────────────────────────────────────────────────────
COL_GREEN=$'\033[0;32m'
COL_YELLOW=$'\033[1;33m'
COL_RED=$'\033[0;31m'
COL_CYAN=$'\033[0;36m'
COL_DIM=$'\033[2m'
COL_RESET=$'\033[0m'
COL_BOLD=$'\033[1m'

step() { echo -e "\n${COL_BOLD}$*${COL_RESET}"; }
ok()   { echo "${COL_GREEN}✓${COL_RESET} $*"; }
skip() { echo "${COL_YELLOW}→ skip:${COL_RESET} $*"; }
warn() { echo "${COL_YELLOW}⚠${COL_RESET} $*"; }
die()  { echo -e "\n${COL_RED}✗ ERROR:${COL_RESET} $*\n"; exit 1; }

need_cmd() { command -v "$1" &>/dev/null || die "'$1' not found and is required to continue"; }
need_cmd_or_install() { need_cmd "$1"; }  # reserved for future auto-install of deps

# ── Interactive arrow-key menu (cb.sh pattern, set -e-safe) ──────────────────
_MENU_ITEMS=(
  "android|Android toolchain (Java $JAVA_MAJOR + SDK)"
  "uv|uv (Python package manager)"
  "node|Node.js $NODE_MAJOR (managed tarball)"
  "opencode|OpenCode (AI Coding — direct GitHub release)"
  "ollama|Ollama (LLM runtime)"
  "claude|Claude Code (AI Coding)"
  "hermes|Hermes (AI Agent)"
  "ori|ORI (AI Coding)"
  "rclone|rclone (cloud storage sync)"
  "qbt|qBittorrent-nox (headless BitTorrent)"
  "aria2|aria2c (download utility)"
  "ffmpeg|FFmpeg (static GPL build)"
)
_MENU_CURSOR=0
_MENU_TOGGLE=()

_menu_init() {
  local i
  # Every item starts UNCHECKED in both modes — the user ticks what they want
  # (to install, or to remove in clean mode). In clean mode an empty selection
  # removes nothing; the menu can never trigger an irreversible full wipe
  # (that is --clean all only).
  for i in "${!_MENU_ITEMS[@]}"; do
    _MENU_TOGGLE[$i]=0
  done
  _status_init
}

# Current Status panel ─────────────────────────────────────────────────────
# Probed ONCE in _status_init (when the menu opens) and only re-echoed by
# _menu_draw — which redraws on EVERY keypress, so probing would fork a
# version binary per keystroke.
_STATUS_LINES=()

# Probes every tool once and stores pre-coloured status lines in
# _STATUS_LINES for _menu_draw to echo — one line per tool: green
# "[name] <version> (<path>)" when installed, red "[name] not installed"
# otherwise. The managed copy in XDG_BIN_HOME wins over a PATH hit.
_status_init() {
  local name bin path ver
  local TOOLS=(
    "java|java"
    "python|python"
    "uv|uv"
    "node|node"
    "adb|adb"
    "opencode|opencode"
    "ollama|ollama"
    "claude|claude"
    "hermes|hermes"
    "ori|ori"
    "rclone|rclone"
    "qbt-nox|qbittorrent-nox"
    "aria2c|aria2c"
    "ffmpeg|ffmpeg"
  )
  _STATUS_LINES=()
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r name bin <<< "$entry"
    path="$XDG_BIN_HOME/$bin"
    [[ -x "$path" ]] || path="$(command -v "$bin" 2>/dev/null || true)"
    ver="${path:+$("$path" --version 2>&1 | grep -v '^Picked up' | head -1 || true)}"
    if [[ -n "$ver" ]]; then
      _STATUS_LINES+=("${COL_GREEN}[$(printf '%-8s' "$name")] $ver${COL_RESET} ${COL_CYAN}($path)${COL_RESET}")
    else
      _STATUS_LINES+=("${COL_RED}[$(printf '%-8s' "$name")] not installed${COL_RESET}")
    fi
  done
}

_menu_draw() {
  clear
  local desc mark styled prefix selected=0
  local title="Toolchain Setup" verb="install"
  [[ "$MENU_MODE" == clean ]] && { title="Toolchain Cleanup"; verb="remove"; }
  [[ "$REPLIT_MODE" == true ]] && title="$title (Replit)"
  echo "${COL_BOLD}${COL_CYAN}${title}${COL_RESET}"
  if [[ "$REPLIT_MODE" == true ]]; then
    echo "${COL_GREEN}●${COL_RESET} ${COL_DIM}persistent workspace:${COL_RESET} ${COL_CYAN}$WORKSPACE${COL_RESET}"
  fi
  echo "${COL_DIM}↑/↓ move · space toggle · enter confirm · ${COL_RESET}${COL_RED}q${COL_RESET} ${COL_DIM}quit${COL_RESET}"
  echo ""
  echo "${COL_BOLD}Current Status${COL_RESET}"
  echo "${COL_DIM}─────────────────────────────────────────────${COL_RESET}"
  local line
  for line in "${_STATUS_LINES[@]}"; do
    echo "$line"
  done
  echo ""
  local i
  for i in "${!_MENU_ITEMS[@]}"; do
    IFS='|' read -r _ desc <<< "${_MENU_ITEMS[$i]}"
    if [[ "${_MENU_TOGGLE[$i]}" -eq 1 ]]; then
      mark="[${COL_GREEN}✓${COL_RESET}]"
    else
      mark="${COL_DIM}[ ]${COL_RESET}"
    fi
    if [[ "$i" -eq "$_MENU_CURSOR" ]]; then
      prefix="${COL_BOLD}${COL_CYAN}>${COL_RESET}"
      styled="${COL_BOLD}$desc${COL_RESET}"
    else
      prefix=" "
      styled="$desc"
    fi
    echo " ${prefix} ${mark} ${styled}"
  done
  for i in "${!_MENU_TOGGLE[@]}"; do
    [[ "${_MENU_TOGGLE[$i]}" -eq 1 ]] && selected=$((selected + 1))
  done
  echo ""
  if [[ $selected -gt 0 ]]; then
    echo "${COL_GREEN}enter${COL_RESET} ${verb} ${COL_BOLD}${selected}/${#_MENU_ITEMS[@]} selected tools${COL_RESET}"
  else
    echo "${COL_DIM}nothing selected — tick items with space${COL_RESET}"
  fi
}

_menu_read_key() {
  local key
  if ! IFS= read -rsn1 key; then
    echo quit  # EOF (Ctrl+D)
    return 0
  fi
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 key || true
    case "$key" in
      '[A') echo up ;;
      '[B') echo down ;;
    esac
  elif [[ "$key" == " " ]]; then
    echo space
  elif [[ -z "$key" ]]; then
    echo enter
  elif [[ "$key" == "q" || "$key" == "Q" ]]; then
    echo quit
  fi
}

_menu_keyloop() {
  while true; do
    _menu_draw
    case "$(_menu_read_key)" in
      up)
        _MENU_CURSOR=$((_MENU_CURSOR - 1))
        ((_MENU_CURSOR < 0)) && _MENU_CURSOR=$((${#_MENU_ITEMS[@]} - 1))
        ;;
      down)
        _MENU_CURSOR=$((_MENU_CURSOR + 1))
        ((_MENU_CURSOR >= ${#_MENU_ITEMS[@]})) && _MENU_CURSOR=0
        ;;
      space)
        if [[ "${_MENU_TOGGLE[$_MENU_CURSOR]}" -eq 1 ]]; then
          _MENU_TOGGLE[$_MENU_CURSOR]=0
        else
          _MENU_TOGGLE[$_MENU_CURSOR]=1
        fi
        ;;
      enter) return 0 ;;
      quit)  return 130 ;;
    esac
  done
}

_menu_apply() {
  local i label
  if [[ "$MENU_MODE" == clean ]]; then
    # Clean menu: remember the TICKED labels — exactly the tools to remove. An
    # EMPTY selection removes nothing (the menu starts unchecked and tick-to-
    # remove; there is no implicit "clean all" here).
    CLEAN_TOOLS=()
    for i in "${!_MENU_ITEMS[@]}"; do
      if [[ "${_MENU_TOGGLE[$i]}" -eq 1 ]]; then
        IFS='|' read -r label _ <<< "${_MENU_ITEMS[$i]}"
        CLEAN_TOOLS+=("$label")
      fi
    done
    return 0
  fi
  for i in "${!_MENU_ITEMS[@]}"; do
    if [[ "${_MENU_TOGGLE[$i]}" -eq 0 ]]; then continue; fi
    IFS='|' read -r label _ <<< "${_MENU_ITEMS[$i]}"
    case "$label" in
      android)  INSTALL_ANDROID=true ;;
      uv)       INSTALL_UV=true ;;
      node)     INSTALL_NODE=true ;;
      opencode) INSTALL_OPENCODE=true ;;
      ollama)   INSTALL_OLLAMA=true ;;
      claude)   INSTALL_CLAUDE=true ;;
      hermes)   INSTALL_HERMES=true ;;
      ori)      INSTALL_ORI=true ;;
      rclone)   INSTALL_RCLONE=true ;;
      qbt)      INSTALL_QBT=true ;;
      aria2)    INSTALL_ARIA2=true ;;
      ffmpeg)   INSTALL_FFMPEG=true ;;
    esac
  done
}

# NOTE: there is deliberately NO second y/N prompt after the menu — pressing
# Enter on the ticked list in interactive_menu IS the confirmation (the menu
# footer spells this out: "enter = remove/install N selected tools"). Asking
# again with a `[y/N]` (default No) after Enter was the old source of a
# spurious "Aborted." on every multi-tool selection, since the Enter needed
# to dismiss it produced an empty answer. Only the flag-driven path
# (`--clean <target>` / `--clean all`) confirms via confirm_clean in main.

interactive_menu() {
  _menu_init
  printf '\033[?25l'
  trap 'printf "\033[?25h\n" "${COL_YELLOW}Interrupted. Exiting.${COL_RESET}"; exit 130' INT
  set +e
  _menu_keyloop
  local rc=$?
  set -e
  printf '\033[?25h'
  trap - INT
  if [[ $rc -ne 0 ]]; then
    echo -e "\n${COL_YELLOW}Aborted.${COL_RESET}"
    exit "$rc"
  fi
  _menu_apply
}

# Symlink tool binaries into XDG_BIN_HOME — a single PATH entry covers everything.
# Usage: symlink_bins <target_dir> <binary1> [binary2 ...]
symlink_bins() {
  local target_dir="$1"; shift
  local bin
  for bin in "$@"; do
    if [[ -f "$target_dir/$bin" ]]; then
      ln -sfn "$target_dir/$bin" "$XDG_BIN_HOME/$bin"
    fi
  done
}

wait_for_jobs() {
  local context="$1"; shift
  local failed=0
  local pid
  for pid in "$@"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done
  (( failed != 0 )) && die "$context failed"
  return 0
}

# Verify a downloaded file's SHA256 against the expected hex digest.
# verify_sha256 <file> <expected-hex-checksum> <label>
verify_sha256() {
  local file="$1" expected="$2" label="$3"
  if ! command -v sha256sum >/dev/null 2>&1; then
    warn "sha256sum not found — skipping integrity check for $label"
    return 0
  fi
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ -n "$expected" ]] || die "$label: no SHA256 obtained from upstream - refusing unverified install"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$file"
    die "$label checksum mismatch (got $actual, expected $expected) — download may be corrupt"
  fi
  ok "$label verified (SHA256)"
}

usage() {
  cat <<USAGE
Usage: bash scripts/setup.sh [options]

Provisions the local development toolchain into XDG_BIN_HOME (binaries,
XDG_DATA_HOME payload). No 'source env.sh' needed either way.

Mode is AUTO-DETECTED from the environment (there is no flag): when \$REPL_HOME
is set to a real directory we are on Replit and install the persistent layout;
otherwise the \$HOME layout is used.
  replit  (auto): XDG dirs under \$REPL_HOME; shell env in a custom
shell custom rc at $REPL_HOME/.config/bashrc (auto-sourced by the Replit bootstrap; no .replit pin)
                  (applies to every repl process)
  default (auto): XDG dirs under \$HOME; minimal PATH block appended to
                  ~/.bashrc; no .replit, no Replit-specific wiring

Options:
  -a,  --all            Install everything (no menu)
  -at, --android-tools  Install Android toolchain (Java $JAVA_MAJOR + SDK)
  --uv                  Install uv (Python package manager)
  --node                Install Node.js $NODE_MAJOR (managed tarball)
  -oc, --opencode		    Install OpenCode (direct GitHub release binary into XDG_BIN_HOME)
  -ol, --ollama         Install Ollama (LLM runtime) into XDG_DATA_HOME/ollama
  -cl, --claude         Install Claude Code coding tool (direct SHA256-verified binary into XDG_BIN_HOME)
  -ha, --hermes         Install Hermes Agent assistant (curl -fsSL \$HERMES_INSTALL_URL, into \$HERMES_HOME)
  -ori, --openrouterai  Install ORI coding tool (direct SHA256-verified binary into XDG_BIN_HOME)
  --rclone              Install rclone (static binary from downloads.rclone.org into XDG_BIN_HOME)
  --qbt                 Install qBittorrent-nox (static binary from GitHub releases)
  --aria2               Install aria2c (static musl binary from GitHub releases)
  --ffmpeg              Install FFmpeg (BtbN static GPL build: ffmpeg/ffprobe/ffplay)
  --doctor              Verify the toolchain (no install) — prints versions and flags
  --clean [target]      Remove installed toolchain artifacts.
                        Bare --clean / -c opens the CLEAN PICK-MENU (tick the
                        tools to remove). An explicit target skips the menu:
                        `--clean all` (or `--clean --all`) removes everything;
                        --clean node|uv|android-tools|oc|opencode|ollama|
                        claude|hermes|ori|rclone|qbt|aria2|ffmpeg removes one
                        tool. Flag-driven cleanup prompts for confirmation
                        unless -y/--yes is given.
  --list, --show        Show current toolchain state (wired tools, binaries, env vars)
  -y,  --yes            Skip the cleanup confirmation prompt
  -h,  --help           Show this help

Examples:
  bash scripts/setup.sh                 interactive install menu (on a terminal)
  bash scripts/setup.sh -c              interactive clean menu — pick tools to remove
  bash scripts/setup.sh --clean         same as -c
  bash scripts/setup.sh --all           install everything (no menu)
  bash scripts/setup.sh --android-tools
  bash scripts/setup.sh --uv --node
  bash scripts/setup.sh --clean all     remove the entire toolchain (asks y/N)
  bash scripts/setup.sh --clean --all   same thing (flag form)
  bash scripts/setup.sh --clean node    remove Node.js
  bash scripts/setup.sh --clean all -y  remove everything, no prompt

After setup, every new shell sources the generated shell rc automatically, so
'java', 'python', 'uv', 'node', 'adb', 'opencode' are on PATH directly.
USAGE
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -a|--all)                  INSTALL_ALL=true ;;
      -at|--android-tools)       INSTALL_ANDROID=true ;;
      --uv)                      INSTALL_UV=true ;;
      --node)                    INSTALL_NODE=true ;;
      -oc|--opencode)       		 INSTALL_OPENCODE=true ;;
      -ol|--ollama)              INSTALL_OLLAMA=true ;;
      -cl|--claude)              INSTALL_CLAUDE=true ;;
      -ha|--hermes) 						 INSTALL_HERMES=true ;;
      -ori|--openrouterai) 			 INSTALL_ORI=true ;;
      --rclone)                 INSTALL_RCLONE=true ;;
      --qbt)                    INSTALL_QBT=true ;;
      --aria2)                  INSTALL_ARIA2=true ;;
      --ffmpeg)                 INSTALL_FFMPEG=true ;;
      --doctor)                  DOCTOR=true ;;
      --list|--show)             LIST_STATE=true ;;
      -c|--clean)
        CLEAN=true
        # Optional target: 'all' (or --all) = full wipe, a tool name =
        # single tool. No target (bare --clean) = open the CLEAN PICK-MENU on
        # a terminal; non-interactive bare --clean falls back to 'all'.
        if (($# > 1)); then
          case "$2" in
            all|--all)          CLEAN_TARGET="all"; shift ;;
            -y|--yes)           : ;;  # consumed by the loop on the next pass
            -*)
              # A flag directly after --clean is almost always a typo'd target
              # ('--clean --node'); refuse instead of silently opening the
              # menu (or, non-interactively, wiping everything).
              die "--clean takes 'all' or a tool target: use '--clean <target> <flags>' (got '$2' after --clean)"
              ;;
            *)                  CLEAN_TARGET="$2"; shift ;;
          esac
        fi
        ;;
      -y|--yes)                  YES=true ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option '$1'. Use --help for usage."
        ;;
    esac
    shift
  done

  # Default to full provisioning when nothing specific was requested.
  if ! $CLEAN && ! $INSTALL_ANDROID && ! $INSTALL_NODE && ! $INSTALL_UV \
     && ! $INSTALL_OPENCODE && ! $INSTALL_OLLAMA && ! $INSTALL_CLAUDE \
     && ! $INSTALL_HERMES && ! $INSTALL_ORI && ! $INSTALL_RCLONE \
     && ! $INSTALL_QBT && ! $INSTALL_ARIA2 && ! $INSTALL_FFMPEG \
     && ! $DOCTOR && ! $LIST_STATE; then
    INSTALL_ALL=true
  fi

  if $INSTALL_ALL; then
    INSTALL_ANDROID=true
    INSTALL_NODE=true
    INSTALL_UV=true
    INSTALL_OPENCODE=true
    INSTALL_OLLAMA=true
    INSTALL_CLAUDE=true
    INSTALL_HERMES=true
    INSTALL_ORI=true
    INSTALL_RCLONE=true
    INSTALL_QBT=true
    INSTALL_ARIA2=true
    INSTALL_FFMPEG=true
  fi
}

# Shell rc (managed block appended at the bottom) ────────────────────────────
# The managed block is APPENDED, never prepended: the file is the user's own
# rc and prepending would clobber their editorial header. The block lives at
# the bottom so user customizations above win. Two emitters:
#   emit_managed_block  replit mode: env-sync, platform XDG exports, PATH,
#                       aliases. env-sync and aliases are Replit-only
#                       (they live in /run/replit, e.g. 'replit shutdown').
#   emit_minimal_block  default mode: PATH + tool env vars ONLY, for the
#                       tools installed this run. No env-sync, no aliases.
#
# Shared PATH-line generator: one guard per dir registered by this run's
# installers (deduped — most tools share XDG_BIN_HOME), emitted REVERSED so
# the first-registered dir ends up first on PATH (binaries beat the
# payload's own bin dirs). Dirs are emitted as LITERAL paths: exactly
# where installers put things this run; the block bakes the same
# literals as the XDG exports.
rc_path_lines() {
  local dir d dup
  local out=() reversed=()
  for dir in ${_TOOL_PATH_DIRS[@]+"${_TOOL_PATH_DIRS[@]}"}; do
    dup=false
    for d in ${out[@]+"${out[@]}"}; do
      [[ "$d" == "$dir" ]] && { dup=true; break; }
    done
    $dup || out+=("$dir")
  done
  for dir in ${out[@]+"${out[@]}"}; do
    reversed=("$dir" ${reversed[@]+"${reversed[@]}"})
  done
  for dir in ${reversed[@]+"${reversed[@]}"}; do
    printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' \
      "$dir" "$dir"
  done
}

emit_managed_block() {
  cat <<EOF

# >>> toolchain >>>

# use global registry
export YARN_REGISTRY="https://registry.yarnpkg.com/"
export YARN_NPM_REGISTRY_SERVER="https://registry.yarnpkg.com/"
export PIP_INDEX_URL="https://pypi.org/simple/"
export npm_config_registry="https://registry.npmjs.org/"
export NPM_CONFIG_REGISTRY="https://registry.npmjs.org/"
export GOPROXY="https://proxy.golang.org,direct"
export PIP_TRUSTED_HOST="pypi.org"

# Platform-level dirs only. Tool vars (JAVA_HOME, NODE_DIR, OLLAMA_MODELS,
# config dirs) are NOT re-exported here: .replit [userenv.shared] is the single
# global source that reaches all shells; env-sync (above) + re-exporting would
# risk shadowing a value the platform/operator set.
export WORKSPACE="$WORKSPACE"
export XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
export XDG_DATA_HOME="$XDG_DATA_HOME"
export XDG_CACHE_HOME="$XDG_CACHE_HOME"
export XDG_STATE_HOME="$XDG_STATE_HOME"
export XDG_BIN_HOME="$XDG_BIN_HOME"

# git global config -> workspace-persisted file (tmpfs on /run is wiped)
export GIT_CONFIG_GLOBAL="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"

# PATH: prepend dirs registered by this run's installers, once per
# shell. Agent tooling spawns many nested shells that re-source this rc, so
# each entry is guarded individually (a single combined pattern can't work:
# adjacent PATH entries share one colon, which one pattern segment can't
# consume twice). rc_path_lines emits one guarded line per registered dir.
EOF
  rc_path_lines
  cat <<'EOF'

# aliases
alias l='ls --color=auto -a'
alias la='l -la'
alias c='clear'
alias q='exit'
alias off='replit shutdown'
alias setup='bash scripts/setup.sh'
alias glo='git log --oneline'

# <<< toolchain <<<
EOF
}

# Default-mode block: PATH + tool env vars for the tools installed THIS
# run. Values are baked at write time (concrete dirs) — unlike the replit
# block which re-exports vars via env-sync to keep them live. No env-sync,
# no aliases outside Replit.
emit_minimal_block() {
  cat <<'EOF'

# >>> toolchain >>>
# Managed by scripts/setup.sh — edit setup.sh and re-run, don't hand-edit.
EOF
  # Tool env vars first, then PATH. Same no-shadowing rule as the userenv
  # block: a var the operator set to a DIFFERENT value is not re-exported
  # here (snapshot taken at startup, so our own re-fed value still
  # re-emits on re-runs).
  local var
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"}; do
    if [[ -n "${_PRESET_ENV[$var]:-}" && "${_PRESET_ENV[$var]}" != "${!var}" ]]; then
      continue
    fi
    printf 'export %s="%s"\n' "$var" "${!var}"
  done
  rc_path_lines
  printf '# <<< toolchain <<<\n'
}

write_bashrc() {
  # Nothing registered this run (e.g. --doctor alone) — don't touch the rc at
  # all. Stripping the block here would WIPE the wiring a previous install
  # wrote, since the block would be regenerated with zero PATH lines.
  if [[ ${#_TOOL_ENV_VARS[@]} -eq 0 && ${#_TOOL_PATH_DIRS[@]} -eq 0 ]]; then
    skip "no tools installed this run — leaving $BASHRC untouched"
    return 0
  fi

  step "Configuring shell rc: $BASHRC"
  mkdir -p "$(dirname "$BASHRC")"
  [[ -f "$BASHRC" ]] || : > "$BASHRC"
  chmod u+rw "$BASHRC" 2>/dev/null || true

  # Strip any prior managed block (old or new markers) so re-runs stay clean,
  # and trim trailing blank lines — the block's separator line would otherwise
  # accumulate one per re-run. Read the whole file, filter in memory, and
  # write back THROUGH the path (cat >): if $BASHRC is a symlink
# sed on $BASHRC would silently replace a symlink with a plain file; the in-place edit happens here.
  # file; an in-place edit happens here.
  # Lift this run's predecessors' wiring before the strip — see rescue_tool_lines.
  rescue_tool_lines "$BASHRC"

  local rc_trim
  rc_trim="$(mktemp)"
  awk '
    $0 ~ /^# >>> toolchain >>>/ { inskip=1 }
    inskip { if ($0 ~ /^# <<< toolchain <<</) { inskip=0 }; next }
    { lines[NR]=$0 }
    END { n=NR; while (n>0 && lines[n]=="") n--; for (i=1;i<=n;i++) if (i in lines) print lines[i] }
  ' "$BASHRC" > "$rc_trim"
  cat "$rc_trim" > "$BASHRC"
  rm -f "$rc_trim"

  # Verify-and-revert (the shell-rc twin of write_replit_env's TOML check):
  # snapshot the stripped file, append the new block, then bash -n the
  # RESULT. A broken emit (e.g. an unbalanced quote in rc_path_lines) used to
  # ship straight into every shell's startup — now it reverts to the
  # pre-update file instead.
  local rc_backup
  rc_backup="$(mktemp)"
  cat "$BASHRC" > "$rc_backup"

  if [[ "$REPLIT_MODE" == true ]]; then
    # Append a fresh managed block at the bottom.
    emit_managed_block >> "$BASHRC"
  else
    emit_minimal_block >> "$BASHRC"
  fi

  if ! bash -n "$BASHRC" 2>/dev/null; then
    cat "$rc_backup" > "$BASHRC"
    rm -f "$rc_backup"
    die "$BASHRC failed 'bash -n' after toolchain update — reverted to the pre-update file"
  fi
  rm -f "$rc_backup"

  if [[ "$REPLIT_MODE" == true ]]; then
    ok "shell rc updated: $BASHRC (toolchain block appended at bottom)"
  else
    ok "shell rc updated: $BASHRC (minimal PATH block appended at bottom)"
  fi
}

# Workflow shim + REPLIT_BASHRC pin (replit mode only) ──────────────────────
# Two halves of one fix, so they live in one function:
#
#   1. $REPLIT_BASHRC_FILE — a tiny rc whose only job is `source ~/.bashrc`;
#   2. the [userenv.shared] key REPLIT_BASHRC = <absolute path to it>.
#
# Workflow tasks (shell.exec in .replit, the Run button, deploys) run bash
# non-interactively: they never read $BASHRC, and start with the platform's
# env. Their bootstrap reads $REPLIT_BASHRC instead, so between a bare
# platform shell and our toolchain env the only missing link is that one
# variable. Sourcing ~/.bashrc gets the managed block on $BASHRC sourced in
# turn, which is what makes a workflow see the same PATH/tool vars as the
# user's terminal.
#
# Runs on EVERY replit-mode setup (registered as an exit action next to
# write_replit_env) — not only when tools were installed — because the shim
# is fixed wiring, and a .replit whose userenv was rewritten by anything
# else would otherwise lose the pin silently.
write_replit_bashrc() {
  if [[ "$REPLIT_MODE" != true ]]; then
    skip "workflow bashrc shim not written in default mode (interactive rc only)"
    return 0
  fi

  # 1. The shim. Regenerated unconditionally: it is wiring, not user config,
  #    so it never accumulates edits the way $BASHRC can.
  local dir
  dir="$(dirname "$REPLIT_BASHRC_FILE")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    warn "cannot create $dir — workflow bashrc shim not written"
    return 0
  fi

  cat > "$REPLIT_BASHRC_FILE" <<'EOF'
# Workflow/agent shells run bash with REPLIT_MODE set (agent|workflow). The
# store bashrc guards `source "$BASHRC"` behind `[[ -z "${REPLIT_MODE}" ]]`
# (~line 322), so in a workflow shell that guard fails and the managed rc is
# NOT sourced. Unset it here so sourcing ~/.bashrc (which sources $BASHRC in
# turn) actually loads the toolchain, matching the interactive terminal's env.
unset REPLIT_MODE
source ~/.bashrc
EOF

  # Same verify pass as $BASHRC: a typo here would break every workflow
  # shell's startup, and the failure would be silent (workflows do not
  # print their bootstrap errors).
  if ! bash -n "$REPLIT_BASHRC_FILE" 2>/dev/null; then
    rm -f "$REPLIT_BASHRC_FILE"
    warn "$REPLIT_BASHRC_FILE failed 'bash -n' — removed; .replit pin not written"
    return 0
  fi
  ok "workflow bashrc shim written: $REPLIT_BASHRC_FILE"

  # 2. The pin. Forced: the platform PRE-SETS REPLIT_BASHRC to the read-only
  #    Nix-store bashrc, so the no-shadowing rule write_replit_env honours
  #    would classify our value as shadowing a platform choice and drop it.
  #    This key is the entire point of the function — it must land. Safe
  #    precisely because it only takes effect where nothing else does:
  #    interactive consoles keep sourcing $BASHRC.
  local replit_file="$REPL_HOME/.replit"
  if [[ ! -f "$replit_file" || ! -w "$replit_file" ]]; then
    skip ".replit missing or not writable — workflow shops keep the platform env"
    return 0
  fi

  # Absolute path, resolved now: .replit is TOML read by Replit, with no
  # shell expansion anywhere in it, so a $VAR here would be literal text.
  local target
  target="$(cd -- "$dir" && pwd)/$(basename "$REPLIT_BASHRC_FILE")"

  local -a py=()
  if ! replit_resolve_py py; then
    warn "no tomlkit-capable python (project .venv or uv) — REPLIT_BASHRC pin not written; set it by hand in $replit_file:"
    warn "  REPLIT_BASHRC = \"$target\""
    return 0
  fi

  if ! "${py[@]}" "$SCRIPT_DIR/replit_userenv.py" --file "$replit_file" \
       --set "REPLIT_BASHRC=$target"; then
    warn ".replit REPLIT_BASHRC pin failed — workflow shells keep the platform env"
    return 0
  fi
  ok "workflow bashrc pinned: REPLIT_BASHRC=$target (.replit userenv)"
}

# Lift the wiring a PRIOR run's managed block wrote (both writers regenerate
# the block from what was registered THIS run, so without this every new
# install wiped the previous tools' vars and PATH dirs). Rescued keys go into
# _TOOL_ENV_VARS / _TOOL_PATH_DIRS — the emitters then re-apply the
# no-shadowing rule, rc_path_lines dedupes PATH dirs, and a var/dir this
# run re-registers appears once. Keep ALL rescued lines (even for a tool this
# run explicitly cleans) because the block is the single source for these
# vars and an unregistered var can't be verified dead anywhere else;
# `--clean all` strips the whole block, which is the removal path. Only the
# LAST block (if any) counts — earlier ones are superseded.
rescue_tool_lines() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local line in_block=0 var
  local last_block=()
  while IFS= read -r line; do
    case "$line" in
      '# >>> toolchain >>>') in_block=1; last_block=(); continue ;;
      '# <<< toolchain <<<') in_block=0; continue ;;
    esac
    (( in_block )) && last_block+=("$line")
  done < "$file"

  # Seed this run's registrations so rescue never duplicates them.
  # rc_path_lines dedupes PATH dirs; the emitters' no-shadowing rule decides
  # vars. Platform vars (WORKSPACE and the five XDG/REPL_HOME exports the
  # replit block carries) lifted via 'export NAME=' syntax are NOT
  # re-registered — [userenv.shared] must not shadow the platform env.
  local -A seen=()
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"}; do seen["$var"]=1; done

  for line in ${last_block[@]+"${last_block[@]}"}; do
    if [[ "$line" == 'case ":$PATH:" in '* ]]; then
      # rc_path_lines' guarded line — lift the dir so guards come back. The
      # pattern segment is *":/dir:"* (colons included — the guard needs
      # them); the regex keeps inner colons: capture, then strip.
      # The regex lives in a variable because escaped quotes inline mis-parse.
      local re='\*"([^"]*)"\*'
      if [[ "$line" =~ $re ]]; then
        local dir="${BASH_REMATCH[1]#:}"
        _TOOL_PATH_DIRS+=("${dir%:}")
      fi
      continue
    fi
    # Tool-var line, in either writer's grammar: 'NAME = "value"' (userenv) or
    # 'export NAME="value"' (rc).
    if [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]] \
       || [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
      var="${BASH_REMATCH[1]}"
      case "$var" in
        WORKSPACE|REPL_HOME|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|XDG_STATE_HOME|XDG_BIN_HOME|REPLIT_BASHRC)
          continue ;;
      esac
      # A var the CURRENT script no longer defines (dropped in a newer
      # version): re-emitting ${!var} would be fatal under set -u; drop it.
      if [[ -z "${!var+x}" ]]; then
        continue
      fi
      if [[ -z "${seen[$var]:-}" ]]; then
        seen["$var"]=1
        _TOOL_ENV_VARS+=("$var")
      fi
    fi
  done
}

# [userenv.shared] manager ──────────────────────────────────────────────────
# The shell rc only reaches shells that source it (consoles). [userenv.shared]
# compiles into /run/replit/env/latest and applies to EVERY repl process —
# consoles, agents, workflows — the global env path. ALL TOML manipulation
# lives in scripts/replit_userenv.py (tomlkit): keys are added, updated in
# place, or deleted by NAME inside the table — no marker comments, no
# sed/awk line surgery. Everything else in .replit (workflows, ports, the
# operator's own keys) round-trips untouched.

# Resolve a tomlkit-capable interpreter into the array named $1: the
# project .venv first, then any python3 (Replit's) that has tomlkit, then
# uv (which fetches tomlkit on demand). Returns 1 when nothing qualifies.
replit_resolve_py() {
  local -n _py="$1"
  if [[ -x "$WORKSPACE/.venv/bin/python3" ]] \
    && "$WORKSPACE/.venv/bin/python3" -c 'import tomlkit' 2>/dev/null; then
    _py=("$WORKSPACE/.venv/bin/python3")
  elif command -v python3 &>/dev/null && python3 -c 'import tomlkit' 2>/dev/null; then
    _py=(python3)
  elif command -v uv &>/dev/null; then
    _py=(uv run --no-project --with tomlkit python3)
  elif [[ -x "$XDG_BIN_HOME/uv" ]]; then
    _py=("$XDG_BIN_HOME/uv" run --no-project --with tomlkit python3)
  else
    return 1
  fi
}

# The fixed registry overrides setup.sh maintains in [userenv.shared]. They
# are DEFAULTS only — a value the platform/operator feeds in the inherited
# env (Replit's package-firewall mirrors) wins. The shell-rc block in
# emit_managed_block carries the same values (kept in sync by hand).
_REGISTRY_ENV_VARS=(YARN_REGISTRY YARN_NPM_REGISTRY_SERVER PIP_INDEX_URL \
  npm_config_registry NPM_CONFIG_REGISTRY GOPROXY PIP_TRUSTED_HOST)
declare -A _REGISTRY_ENV_VALUES=(
  [YARN_REGISTRY]="https://registry.yarnpkg.com/"
  [YARN_NPM_REGISTRY_SERVER]="https://registry.yarnpkg.com/"
  [PIP_INDEX_URL]="https://pypi.org/simple/"
  [npm_config_registry]="https://registry.npmjs.org/"
  [NPM_CONFIG_REGISTRY]="https://registry.npmjs.org/"
  [GOPROXY]="https://proxy.golang.org,direct"
  [PIP_TRUSTED_HOST]="pypi.org"
)

# Carry forwards tool vars a previous run left in [userenv.shared] WITHOUT
# needing their installer to re-run this time. Candidates are restricted to
# keys WITH a wire owner (seed_tool_wiring / installers) — operator keys
# (NODE_ENV, SERVER_LOG_LEVEL, ...) are never re-registered. A key the
# current script no longer defines is dropped (re-emitting ${!var} would be
# fatal under set -u; the writer's --delete-key clears it).
rescue_userenv_keys() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local -A seen=()
  local var line in_section=0
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"}; do seen["$var"]=1; done
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[ ]]; then
      [[ "$line" == "[userenv.shared]" ]] && in_section=1 || in_section=0
      continue
    fi
    ((in_section)) || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] || continue
    var="${BASH_REMATCH[1]}"
    [[ -n "$(env_var_owner "$var")" ]] || continue
    [[ -n "${seen[$var]:-}" ]] && continue
    [[ -n "${!var+x}" ]] || continue
    seen["$var"]=1
    _TOOL_ENV_VARS+=("$var")
  done < "$file"
}

# Delete userenv keys owned by <labels> ('all' or space-joined wire labels)
# — the .replit twin of strip_tool_wiring (which is now rc-only). Pure
# depends on whether that key exists; an empty [userenv.shared] table is also dropped.
# [userenv.shared] table is removed by the helper.
strip_userenv_keys() {
  local labels="$1" file="$2"
  [[ -f "$file" && -w "$file" ]] || return 0
  local var owner
  # The REPLIT_BASHRC pin is owned by the shim mechanism, NOT by any single
  # tool — removing it on a per-tool clean would silently disable the
  # workflow/agent-shell toolchain fix. Only a full wipe ('all') drops it.
  local -a del=()
  [[ "$labels" == all ]] && del+=(--delete-key REPLIT_BASHRC)
  for var in "${!_WIRE_OWNER[@]}"; do
    [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue   # skip PATH dirs
    owner="$(env_var_owner "$var")"
    [[ -n "$owner" ]] || continue
    if [[ "$labels" == all ]] || owned_only_by "$owner" "$labels"; then
      del+=(--delete-key "$var")
    fi
  done
  if [[ "$labels" == all ]]; then
    for var in "${_REGISTRY_ENV_VARS[@]}"; do del+=(--delete-key "$var"); done
  fi
  ((${#del[@]})) || return 0
  local -a py=()
  replit_resolve_py py || { warn "no tomlkit-capable python (project .venv or uv) — $file userenv keys left untouched"; return 0; }
  if "${py[@]}" "$SCRIPT_DIR/replit_userenv.py" --file "$file" "${del[@]}"; then
    ok "Removed $labels-owned userenv keys from $file"
  else
    warn "userenv key cleanup failed for $file — edit it by hand"
  fi
}

write_replit_env() {
  if [[ "$REPLIT_MODE" != true ]]; then
    skip ".replit userenv not written in default mode (shell rc is the only env path)"
    return 0
  fi
  # Nothing registered this run (e.g. --doctor alone) — keep the existing
  # keys. Rewriting would drop the vars a previous install wrote.
  if [[ ${#_TOOL_ENV_VARS[@]} -eq 0 ]]; then
    skip "no tools installed this run — leaving .replit userenv untouched"
    return 0
  fi
  local replit_file="$REPL_HOME/.replit"
  if [[ ! -f "$replit_file" || ! -w "$replit_file" ]]; then
    skip ".replit missing or not writable — shell rc remains the only env path"
    return 0
  fi
  step "Configuring .replit userenv: $replit_file"

  local backup
  backup="$(mktemp)"
  cp "$replit_file" "$backup"

  # Lift this run's predecessors' tool vars before the delete+set — see
  # rescue_userenv_keys.
  rescue_userenv_keys "$replit_file"

  # This function only resolves an interpreter, snapshots a backup and
  # builds the key universe. The helper (tomlkit) clears every managed key
  # (--delete-key), re-adds the ones surviving the no-shadowing rule
  # (--set), then tomllib-validates and atomically replaces the file. The
  # backup is the revert path.
  local -a py=()
  if ! replit_resolve_py py; then
    rm -f "$backup"
    warn "no tomlkit-capable python (project .venv or uv) — .replit userenv untouched; shell rc remains the only env path"
    return 0
  fi

  local var value
  local -A seen=()
  # REPLIT_BASHRC is deliberately NOT in this delete list: the pin is owned
  # by write_replit_bashrc, which runs after this function and re-sets it.
  # Deleting it here would race that write on every install.
  local -a delete_args=() set_args=()
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"} "${_REGISTRY_ENV_VARS[@]}"; do
    [[ -n "${seen[$var]:-}" ]] && continue
    seen["$var"]=1
    delete_args+=(--delete-key "$var")
    # Registry vars are defaults-only; a live value (platform/operator fed)
    # wins. All other managed vars read from the current shell env.
    if [[ -n "${_REGISTRY_ENV_VALUES[$var]:-}" ]]; then
      value="${!var:-${_REGISTRY_ENV_VALUES[$var]}}"
    else
      value="${!var}"
    fi
    # No-shadowing rule: a var set in the inherited environment (user or
    # platform, snapshotted at startup) to a DIFFERENT value is SKIPPED —
    # userenv must not shadow a value the operator chose. An inherited
    # value equal to ours means it is (re)fed from our own previous write
    # and must be re-emitted, or the key would shrink to nothing on re-run.
    if [[ -n "${_PRESET_ENV[$var]:-}" && "${_PRESET_ENV[$var]}" != "$value" ]]; then
      continue
    fi
    set_args+=(--set "$var=$value")
  done

  if ! "${py[@]}" "$SCRIPT_DIR/replit_userenv.py" --file "$replit_file" \
      "${delete_args[@]}" "${set_args[@]}"; then
    mv -f "$backup" "$replit_file"
    die ".replit userenv update failed — reverted to backup"
  fi
  rm -f "$backup"
  ok "userenv updated: $replit_file"
}

# Doctor (no-install self-check) ──────────────────────────────────────────────
doctor() {
  step "Environment doctor"
  local fail=0
  local name cmd ver

  check_tool() {
    name="$1"; cmd="$2"
    if command -v "$cmd" &>/dev/null; then
      ver="$("$cmd" --version 2>&1 | grep -v '^Picked up' | head -1)"
      ok "$name: $ver"
    else
      warn "$name: NOT FOUND ($cmd)"
      fail=1
    fi
  }

  check_tool "Java" java
  check_tool "Android SDK (adb)" adb
  check_tool "uv" uv
  check_tool "Node" node
  check_tool "npm" npm
  check_tool "OpenCode" "$XDG_BIN_HOME/opencode"
  check_tool "Ollama" ollama
  check_tool "Claude" "$XDG_BIN_HOME/claude"
  check_tool "Hermes" "$HERMES_HOME/hermes-agent/venv/bin/hermes"
  check_tool "ORI" "$XDG_BIN_HOME/ori"
  check_tool "rclone" "$XDG_BIN_HOME/rclone"
  check_tool "qBittorrent-nox" "$XDG_BIN_HOME/qbittorrent-nox"
  check_tool "aria2c" "$XDG_BIN_HOME/aria2c"
  check_tool "FFmpeg" "$XDG_BIN_HOME/ffmpeg"

  if [[ -x "$WORKSPACE/gradlew" ]]; then
    ok "gradlew present"
  else
    warn "gradlew missing in $WORKSPACE"
    fail=1
  fi

  case ":$PATH:" in
    *":$XDG_BIN_HOME:"*) ok "XDG_BIN_HOME on PATH" ;;
    *) warn "XDG_BIN_HOME NOT on PATH (open a new shell)"; fail=1 ;;
  esac

  if (( fail == 0 )); then
    ok "All checks passed"
  else
    warn "Some checks failed — re-run: bash scripts/setup.sh"
  fi
  return $fail
}

# Show current toolchain state — read-only, no installs run.
list_state() {
  step "Toolchain state"
  local found
  echo "Mode: $( [[ "$REPLIT_MODE" == true ]] && echo 'replit (persistent)' || echo 'default (HOME)')"
  echo "Workspace: $WORKSPACE"
  echo "XDG_BIN_HOME: $XDG_BIN_HOME"
  echo "XDG_DATA_HOME: $XDG_DATA_HOME"
  echo "BASHRC target: $BASHRC"
  echo

  # Check managed block in BASHRC
  if [[ -f "$BASHRC" ]] && grep -q '# >>> toolchain >>>' "$BASHRC"; then
    echo "=== $BASHRC managed block ==="
    local in_block=0 line
    while IFS= read -r line; do
      case "$line" in
        '# >>> toolchain >>>') in_block=1; continue ;;
        '# <<< toolchain <<<') in_block=0; continue ;;
      esac
      (( in_block )) && echo "$line"
    done < "$BASHRC"
    echo
  else
    echo "=== $BASHRC: no managed block ==="
    echo
  fi

  # Check .replit [userenv.shared]
    local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
    if [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && grep -q '^\[userenv\.shared\]' "$replit_file"; then
      echo "=== $replit_file [userenv.shared] ==="
      awk '/^\[userenv\.shared\]/{s=1; print; next} /^\[/{s=0} s' "$replit_file"
      echo
    elif [[ "$REPLIT_MODE" == true ]]; then
      echo "=== $replit_file: no [userenv.shared] section ==="
      echo
    fi

  # Installed binaries
  echo "=== Installed binaries in $XDG_BIN_HOME ==="
  found=false
  local f
  for f in "$XDG_BIN_HOME"/*; do
    [[ -e "$f" && -x "$f" ]] || continue
    found=true
    local bin_name="$(basename "$f")"
    local owner="$(path_dir_owner "$XDG_BIN_HOME")"
    if [[ -n "$owner" ]]; then
      echo "  $bin_name (owned by: $owner)"
    else
      echo "  $bin_name"
    fi
  done
  $found || echo "  (none)"
  echo

  # Tool env vars registered this run (if any)
  echo "=== Tool env vars (current run registrations) ==="
  local var
  if [[ ${#_TOOL_ENV_VARS[@]} -eq 0 ]]; then
    echo "  (none registered this run)"
  else
    for var in "${_TOOL_ENV_VARS[@]}"; do
      local owner="$(env_var_owner "$var")"
      if [[ -n "$owner" ]]; then
        echo "  $var (owned by: $owner)"
      else
        echo "  $var"
      fi
    done
  fi
  echo

  # PATH dirs registered this run
  echo "=== PATH dirs (current run registrations) ==="
  local dir
  if [[ ${#_TOOL_PATH_DIRS[@]} -eq 0 ]]; then
    echo "  (none registered this run)"
  else
    for dir in "${_TOOL_PATH_DIRS[@]}"; do
      local owner="$(path_dir_owner "$dir")"
      if [[ -n "$owner" ]]; then
        echo "  $dir (owned by: $owner)"
      else
        echo "  $dir"
      fi
    done
  fi
}

# uv (no Python-specific dead code — uv IS the runtime manager) ──────────────
install_uv() {
  step "Installing uv"
  need_cmd curl
  local installer="$XDG_DATA_HOME/_uv-install.sh"
  curl -LsSf https://astral.sh/uv/install.sh -o "$installer" \
    || die "uv installer download failed"
  chmod +x "$installer"
  # Fresh-install contract: remove any stale target before installing, so a
  # re-run replaces (never merges with) the previous install.
  rm -f "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx"
  UV_INSTALL_DIR="$XDG_BIN_HOME" bash "$installer" --no-modify-path || die "uv install failed"
  rm -f "$installer"
  [[ -x "$XDG_BIN_HOME/uv" ]] || die "uv install did not produce $XDG_BIN_HOME/uv"
  ok "uv installed: $XDG_BIN_HOME/uv"
  record_tool_env_vars UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool uv UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH -- "$XDG_BIN_HOME"
}

# ── Android toolchain ─────────────────────────────────────────────────────────
accept_licenses() {
  mkdir -p "$SDK/licenses"
  printf "\n8933bad161af4178b1185d1a37fbf41ea5269c55\n"   > "$SDK/licenses/android-sdk-license"
  printf "\n84831b9409646a918e30573bab4c9c91346d8abd\n"  >> "$SDK/licenses/android-sdk-license"
  printf "\nd56f5187479451eabf01fb78af6dfcb131a6481e\n"  >> "$SDK/licenses/android-sdk-license"
  printf "\n33b6a2b64607f11b759f320ef9dff4ae5c47d97a\n"   > "$SDK/licenses/google-gdk-license"
  printf "\nd56f5187479451eabf01fb78af6dfcb131a6481e\n"   > "$SDK/licenses/android-googletv-license"
  printf "\n601085b94cd77f0b54ff86406957099ebe79c4d7\n"   > "$SDK/licenses/android-sdk-preview-license"
  ok "SDK license files written"

  echo "  Running sdkmanager --licenses (auto-accepting all)..."
  local log_file
  local pipeline_status
  log_file="$(mktemp)"
  set +e
  yes | ANDROID_HOME="$SDK" \
        JAVA_HOME="$JAVA_HOME" \
        JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTS_VALUE" \
        "$SDK/cmdline-tools/bin/sdkmanager" \
          --sdk_root="$SDK" --licenses >"$log_file" 2>&1
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  if (( pipeline_status[1] != 0 )); then
    cat "$log_file" >&2
    rm -f "$log_file"
    die "sdkmanager license acceptance failed"
  fi
  grep -v "^$" "$log_file" | grep -v "^-" | grep -v "^Terms" | tail -5 || true
  rm -f "$log_file"
  ok "Licenses accepted"
}

install_cmdline_tools() {
  need_cmd wget
  need_cmd unzip
  local TMP_ZIP="$XDG_DATA_HOME/_cmdline-tools.zip"
  local TMP_DIR="$XDG_DATA_HOME/_cmdline-tools-extract"
  echo "  Downloading cmdline-tools..."
  wget -q --show-progress -O "$TMP_ZIP" "$CMDLINE_TOOLS_URL" \
    || die "cmdline-tools download failed"
  echo "  Extracting cmdline-tools..."
  mkdir -p "$TMP_DIR"
  unzip -q -o "$TMP_ZIP" -d "$TMP_DIR"
  rm -rf "$SDK/cmdline-tools"
  mv "$TMP_DIR/cmdline-tools" "$SDK/cmdline-tools"
  rm -rf "$TMP_DIR" "$TMP_ZIP"
  chmod +x "$SDK/cmdline-tools/bin/sdkmanager"
  ok "cmdline-tools installed: $SDK/cmdline-tools"
}

install_java() {
  need_cmd wget
  need_cmd tar
  local TMP_TGZ="$XDG_DATA_HOME/_jdk$JAVA_MAJOR.tar.gz"
  local TMP_DIR="$XDG_DATA_HOME/_jdk$JAVA_MAJOR-extract"

  echo "  Downloading Eclipse Temurin JDK $JAVA_MAJOR (latest GA)..."
  wget -q --show-progress -L \
    --header="Accept: application/octet-stream" \
    "https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    -O "$TMP_TGZ" || die "JDK download failed"

  echo "  Extracting Java..."
  rm -rf "$TMP_DIR" "$JAVA_HOME"
  mkdir -p "$TMP_DIR"
  tar -xzf "$TMP_TGZ" -C "$TMP_DIR"

  local EXTRACTED
  EXTRACTED=$(ls "$TMP_DIR")
  [[ -n "$EXTRACTED" ]] || die "JDK extraction produced an empty directory"
  mkdir -p "$JAVA_HOME"
  cp -a "$TMP_DIR/$EXTRACTED"/. "$JAVA_HOME/"
  rm -rf "$TMP_DIR" "$TMP_TGZ"

  symlink_bins "$JAVA_HOME/bin" java javac jar jshell javap
  ok "Java installed: $JAVA_HOME  ($("$JAVA_HOME/bin/java" --version 2>&1 | grep -v '^Picked up' | head -1))"
}

install_sdk_pkg() {
  local pkg="$1"
  local label="$2"

  echo "  Installing $label..."
  local log_file
  log_file="$(mktemp)"
  if ! ANDROID_HOME="$SDK" \
       JAVA_HOME="$JAVA_HOME" \
       JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTS_VALUE" \
       "$SDK/cmdline-tools/bin/sdkmanager" \
         --sdk_root="$SDK" "$pkg" >"$log_file" 2>&1; then
    cat "$log_file" >&2
    rm -f "$log_file"
    die "Android SDK package installation failed: $pkg"
  fi
  grep -Ev "^$|^\[=|Preparing|Unzipping|Warning: File|^Done" "$log_file" |
    tail -5 || true
  rm -f "$log_file"
  ok "$label installed"
}

install_android_tools() {
  step "Android toolchain preflight"
  need_cmd wget
  need_cmd unzip
  need_cmd tar
  need_cmd curl
  local AVAIL_GB
  AVAIL_GB=$(df --output=avail -BG "$WORKSPACE" | tail -1 | tr -d 'G' | xargs)
  echo "  Workspace disk: ${AVAIL_GB} GB available (need ~5 GB)"
  [[ "$AVAIL_GB" -ge 5 ]] || die "Need at least 5 GB free in $WORKSPACE. Currently ${AVAIL_GB} GB."

  step "Creating persistent toolchain directories"
  mkdir -p "$SDK" "$JAVA_HOME" "$XDG_BIN_HOME" "$XDG_DATA_HOME"
  ok "Created: $XDG_DATA_HOME/{android-sdk, java}"

  step "Android cmdline-tools and Java prerequisites"
  install_cmdline_tools &
  local cmdline_tools_pid=$!
  install_java &
  local java_pid=$!
  wait_for_jobs "Android prerequisite installation" "$cmdline_tools_pid" "$java_pid"

  step "SDK licenses"
  accept_licenses

  step "Android SDK packages"
  install_sdk_pkg "platform-tools" "platform-tools"
  install_sdk_pkg "platforms;$ANDROID_PLATFORM" "Android platform $ANDROID_PLATFORM"
  install_sdk_pkg "build-tools;$ANDROID_BUILD_TOOLS" "Android build tools $ANDROID_BUILD_TOOLS"

  symlink_bins "$SDK/cmdline-tools/bin" sdkmanager avdmanager
  symlink_bins "$SDK/platform-tools" adb
  ok "Android bin dirs registered"

  step "Writing local.properties"
  cat > "$WORKSPACE/local.properties" <<EOF
sdk.dir=$SDK
EOF
  ok "local.properties written: $WORKSPACE/local.properties"

  step "Verification"
  if command -v java &>/dev/null; then
    ok "Java $JAVA_MAJOR: $(java --version 2>&1 | grep -v '^Picked up' | head -1)"
  else
    warn "Java $JAVA_MAJOR verification failed"
  fi
  if [[ -x "$SDK/platform-tools/adb" ]]; then
    ok "adb: $("$SDK/platform-tools/adb" --version 2>&1 | head -1)"
  else
    warn "Android SDK adb not found"
  fi

  record_tool_env_vars JAVA_HOME ANDROID_HOME JAVA_TOOL_OPTIONS
  record_tool_path_dirs "$JAVA_HOME/bin" "$SDK/cmdline-tools/bin" "$SDK/platform-tools" "$XDG_BIN_HOME"
  wire_tool android JAVA_HOME ANDROID_HOME JAVA_TOOL_OPTIONS -- "$JAVA_HOME/bin" "$SDK/cmdline-tools/bin" "$SDK/platform-tools" "$XDG_BIN_HOME"
}

# Node.js (managed tarball) ───────────────────────────────────────────────────
install_node() {
  step "Node.js (managed tarball)"
  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME"

  need_cmd wget
  need_cmd curl
  local idx="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/"
  local tar
  tar=$(curl -fsSL "$idx" | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz" | head -1)
  [[ -n "$tar" ]] || die "Could not resolve Node.js tarball from $idx"
  local url="$idx$tar"
  local tmp="$XDG_DATA_HOME/_node.tar.xz"

  echo "  Downloading $tar..."
  wget -q --show-progress -O "$tmp" "$url" || die "Node.js download failed"

  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR"
  tar -xJf "$tmp" -C "$XDG_DATA_HOME"
  local extracted="$XDG_DATA_HOME/$(tar -tf "$tmp" | head -1 | cut -d/ -f1)"
  { [[ -n "$extracted" ]] && [[ -d "$extracted" ]]; } || die "Node.js extraction produced no directory"
  cp -a "$extracted"/. "$NODE_DIR"/
  rm -rf "$tmp" "$extracted"

  symlink_bins "$NODE_DIR/bin" node npm npx
  ok "Node.js installed: $NODE_DIR ($("$NODE_DIR/bin/node" --version))"
  record_tool_env_vars NODE_DIR npm_config_prefix
  record_tool_path_dirs "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
  wire_tool node NODE_DIR npm_config_prefix -- "$NODE_DIR/bin" "$WORKSPACE/node_modules/.bin" "$XDG_BIN_HOME"
}

# ── OpenCode (direct GitHub release — smart installer, no curl|bash) ───────────
# The official installer hardcodes INSTALL_DIR=$HOME/.opencode/bin and just
# downloads opencode-$os-$arch.tar.gz from GitHub releases. We bypass it:
# resolve the asset name ourselves, download the tarball, extract the single
# binary to XDG_DATA_HOME/opencode/bin, symlink into XDG_BIN_HOME.
opencode_asset_name() {
  local os arch combo target
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      die "OpenCode: unsupported OS $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="x64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)              die "OpenCode: unsupported arch $(uname -m)" ;;
  esac
  combo="$os-$arch"
  target="$combo"
  # musl detection (Alpine / ldd reports musl)
  local is_musl=false
  if [[ "$os" == "linux" ]]; then
    if [[ -f /etc/alpine-release ]] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
      is_musl=true
    fi
  fi
  # baseline (x64 without AVX2)
  local needs_baseline=false
  if [[ "$target" == "linux-x64" ]] && ! grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then
    needs_baseline=true
  fi
  $needs_baseline && target="$target-baseline"
  $is_musl && target="$target-musl"
  echo "opencode-$target.tar.gz"
}

install_opencode() {
  step "OpenCode (direct GitHub release)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME"

  local asset
  asset="$(opencode_asset_name)"
  local url="https://github.com/$OPENCODE_REPO/releases/latest/download/$asset"
  local tmp="$XDG_DATA_HOME/_opencode.tar.gz"
  local tmpdir="$XDG_DATA_HOME/_opencode-extract"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "OpenCode download failed: $url"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$tmp" -C "$tmpdir"

  # The tarball holds a single 'opencode' binary — drop it straight into
  # XDG_BIN_HOME (already on PATH). No install dir, no symlink needed.
  [[ -f "$tmpdir/opencode" ]] || die "OpenCode archive is missing the 'opencode' binary"
  # Fresh-install contract: remove any stale target before installing.
  rm -f "$XDG_BIN_HOME/opencode"
  mv -f "$tmpdir/opencode" "$XDG_BIN_HOME/opencode"
  chmod +x "$XDG_BIN_HOME/opencode"
  rm -rf "$tmpdir" "$tmp"
  ok "opencode installed: $XDG_BIN_HOME/opencode ($("$XDG_BIN_HOME/opencode" --version 2>&1 | head -1))"
  record_tool_env_vars OPENCODE_CONFIG_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool opencode OPENCODE_CONFIG_DIR -- "$XDG_BIN_HOME"
}

# Ollama (LLM runtime) ───────────────────────────────────────────────────────
install_ollama() {
  step "Ollama (LLM runtime)"

  # The official Ollama installer needs zstd to decompress the release archive.
  # On Replit, apt is blocked but zstd ships in the Nix store — surface it on PATH.
  if ! command -v zstd >/dev/null; then
    local zstd_bin
    zstd_bin="$(ls -d /nix/store/*zstd-*-bin/bin 2>/dev/null | head -1)"
    if [[ -n "$zstd_bin" ]]; then
      export PATH="$zstd_bin:$PATH"
    fi
  fi

  # The official Ollama installer hardcodes /usr/local/bin and insists on sudo.
  # Patch it to honor OLLAMA_INSTALL_DIR (payload) and OLLAMA_BIN_DIR (symlink).
  need_cmd curl
  mkdir -p "$XDG_DATA_HOME" "$XDG_BIN_HOME"
  local installer="$XDG_DATA_HOME/_ollama-install.sh"
  curl -fsSL https://ollama.com/install.sh -o "$installer" \
    || die "could not download Ollama installer"
  chmod +x "$installer"

  sed -i \
    -e 's/SUDO="sudo"/SUDO=""/' \
    -e 's/ -o0 -g0//g' \
    -e 's#^OLLAMA_INSTALL_DIR=$(dirname${BINDIR})#:#' \
    -e "s#for BINDIR in /usr/local/bin /usr/bin /bin; do#OLLAMA_INSTALL_DIR=\"\${OLLAMA_INSTALL_DIR:-/usr/local}\"; OLLAMA_BIN_DIR=\"\${OLLAMA_BIN_DIR:-\$OLLAMA_INSTALL_DIR/bin}\"; for BINDIR in \"\$OLLAMA_BIN_DIR\"; do#" \
    "$installer"

  if grep -q 'SUDO="sudo"' "$installer"; then
    rm -f "$installer"
    die "Ollama installer patch failed (sudo still present) — upstream changed. Report: https://github.com/ollama/ollama/releases"
  fi

  # Fresh-install contract: replace the payload, KEEP downloaded models
  # ($OLLAMA_MODELS) — they are user data, not install artifacts.
  if [[ -d "$OLLAMA_MODELS" ]]; then
    local models_backup="$XDG_DATA_HOME/_ollama-models-backup"
    mv "$OLLAMA_MODELS" "$models_backup"
  fi
  rm -rf "$OLLAMA_INSTALL_DIR"
  mkdir -p "$XDG_BIN_HOME"
  if [[ -d "${models_backup:-}" ]]; then
    mkdir -p "$OLLAMA_INSTALL_DIR"
    mv "$models_backup" "$OLLAMA_MODELS"
  fi

  OLLAMA_INSTALL_DIR="$OLLAMA_INSTALL_DIR" OLLAMA_BIN_DIR="$OLLAMA_INSTALL_DIR/bin" bash "$installer" \
    || die "ollama installer failed"
  rm -f "$installer"

  if [[ ! -x "$OLLAMA_INSTALL_DIR/bin/ollama" && -x "$OLLAMA_INSTALL_DIR/ollama" ]]; then
    mkdir -p "$OLLAMA_INSTALL_DIR/bin"
    ln -sfn "$OLLAMA_INSTALL_DIR/ollama" "$OLLAMA_INSTALL_DIR/bin/ollama"
  fi

  [[ -x "$OLLAMA_INSTALL_DIR/bin/ollama" ]] \
    || die "ollama binary not found at $OLLAMA_INSTALL_DIR/bin/ollama"
  symlink_bins "$OLLAMA_INSTALL_DIR/bin" ollama
  ok "ollama installed: $OLLAMA_INSTALL_DIR/bin/ollama"
  record_tool_env_vars OLLAMA_INSTALL_DIR OLLAMA_MODELS
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool ollama OLLAMA_INSTALL_DIR OLLAMA_MODELS -- "$XDG_BIN_HOME"
}

# Claude Code (AI coding tool) — smart install ─────────────────────────────
# Claude Code is a single static binary served from downloads.claude.ai with a
# per-platform SHA256 manifest.json. No installer script, no $HOME hack,
# no .local/bin move — download, verify, place directly into XDG_BIN_HOME.
claude_platform() {
  local os arch libc
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      die "Claude: unsupported OS $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="x64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)              die "Claude: unsupported arch $(uname -m)" ;;
  esac
  libc="gnu"
  if [[ -f /lib/libc.musl-x86_64.so.1 || -f /lib/libc.musl-aarch64.so.1 ]] \
     || { command -v ldd >/dev/null 2>&1 && ldd /bin/ls 2>&1 | grep -qi musl; }; then
    libc="musl"
  fi
  case "$os" in
    darwin) echo "darwin-$arch" ;;
    linux)  [[ "$libc" == "musl" ]] && echo "linux-$arch-musl" || echo "linux-$arch" ;;
  esac
}

# Extract the platform's checksum from Claude's manifest.json.
# Prefers python3 (robust JSON), falls back to pure-bash regex (no jq).
# Returns the SHA256 hex digest, or empty string if not found.
claude_checksum() {
  local platform="$1" manifest="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print(d.get('platforms',{}).get('$platform',{}).get('checksum',''))" 2>/dev/null <<< "$manifest" && return 0
  fi
  # bash fallback: '... "linux-x64": ... "checksum": "<hex>" ...'
  if [[ "$manifest" =~ \"$platform\"[^}]*\"checksum\":[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo ""
}

install_claude() {
  step "Claude Code (direct SHA256-verified binary)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local platform base version manifest
  platform="$(claude_platform)"
  base="$CLAUDE_RELEASE_BASE"
  version="$(curl -fsSL "$base/latest" 2>/dev/null || true)"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Claude: could not resolve latest version (got '$version')"
  fi

  local tmp="$XDG_DATA_HOME/_claude.bin"
  local sha=""
  echo "  Resolving Claude Code $version ($platform)"
  manifest="$(curl -fsSL "$base/$version/manifest.json" 2>/dev/null || true)"
  if [[ -n "$manifest" ]]; then
    sha="$(claude_checksum "$platform" "$manifest")"
  fi

  echo "  Downloading claude-$version-$platform"
  curl -fsSL "$base/$version/$platform/claude" -o "$tmp" \
    || { rm -f "$tmp"; die "Claude download failed for $platform"; }

  verify_sha256 "$tmp" "$sha" "claude ($platform)"

  # Fresh-install contract: remove any stale target before installing.
  rm -f "$XDG_BIN_HOME/claude"
  mv -f "$tmp" "$XDG_BIN_HOME/claude"
  chmod +x "$XDG_BIN_HOME/claude"
  ok "claude installed: $XDG_BIN_HOME/claude ($version)"
  record_tool_env_vars CLAUDE_CONFIG_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool claude CLAUDE_CONFIG_DIR -- "$XDG_BIN_HOME"
}

# Hermes Agent (AI agent assistant) ──────────────────────────────────────────
# Fresh-install contract: a re-run REPLACES the existing install —
# HERMES_HOME (venv, config, state) and the launcher binaries are removed
# first so no stale files survive. To keep existing Hermes data
# (sessions/memory/config), back up memories/, config.yaml, state.db etc.
# before re-running.
install_hermes() {
  step "Hermes Agent (AI agent assistant)"
  need_cmd curl
  rm -rf "$HERMES_HOME"
  rm -f "$XDG_BIN_HOME/hermes" "$XDG_BIN_HOME/hermes-agent" "$XDG_BIN_HOME/hermes-acp"
  mkdir -p "$HERMES_HOME" "$XDG_BIN_HOME"

  local installer="$XDG_DATA_HOME/_hermes-install.sh"
  curl -fsSL "$HERMES_INSTALL_URL" -o "$installer" \
    || die "could not download Hermes installer: $HERMES_INSTALL_URL"
  chmod +x "$installer"

  # The installer places the `hermes` launcher in `$HOME/.local/bin` and only
  # appends that dir to `$HOME/.bashrc` when it is NOT on PATH. We
  # exploit that guard so no real rc is touched:
  #   replit mode: run with HOME=$WORKSPACE (the read-only/ephemeral Replit
  #     $HOME would fail the write anyway); $WORKSPACE/.local/bin == XDG_BIN_HOME
  #   default: run with the real $HOME — $HOME/.local/bin == XDG_BIN_HOME, the
  #     script's exported PATH contains it, and the
  #     installer's PATH check skips the .bashrc append.
  # HERMES_HOME governs the data dir (INSTALL_DIR=$HERMES_HOME/hermes-agent).
  # --skip-computer-use avoids cua-driver which writes to $HOME/.bashrc.
  # Skip the bundled Playwright Chromium; we hand Hermes the Replit Chromium.
  local chrome="${REPLIT_PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}"
  if [[ -n "$chrome" && -x "$chrome" ]]; then
    export AGENT_BROWSER_EXECUTABLE_PATH="$chrome"
    echo "  reusing Replit Chromium for Hermes browser tools: $chrome"
  fi

  local hermes_home="$WORKSPACE"
  if [[ "$REPLIT_MODE" != true ]]; then
    hermes_home="$HOME"
  fi
  HERMES_HOME="$HERMES_HOME" HOME="$hermes_home" bash "$installer" \
    --skip-setup --skip-computer-use --skip-browser \
    || die "Hermes installer failed"
  rm -f "$installer"

  # The launcher landed in $hermes_home/.local/bin (== XDG_BIN_HOME, on PATH) —
  # no rc edit by the installer.
  ok "HERMES_HOME=$HERMES_HOME browser=$([ -n "$chrome" ] && echo 'replit chromium' || echo 'none')"
  record_tool_env_vars HERMES_HOME
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool hermes HERMES_HOME -- "$XDG_BIN_HOME"
}

# ORI (AI coding tool) — smart install ─────────────────────────────────────
# ORI is a single static binary on GitHub releases with a SHA256SUMS file for
# verification. No installer script, no symlink — download, verify, place the
# binary directly into XDG_BIN_HOME (already on PATH).
ori_asset_name() {
  local os arch libc
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      die "ORI: unsupported OS $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="x64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)              die "ORI: unsupported arch $(uname -m)" ;;
  esac
  libc="gnu"
  if grep -qi musl /etc/alpine-release 2>/dev/null \
     || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
    libc="musl"
  fi
  if [[ "$os" == "darwin" ]]; then
    echo "ori-darwin-$arch"
  elif [[ "$os" == "linux" && "$libc" == "musl" ]]; then
    echo "ori-linux-$arch-musl"
  else
    echo "ori-linux-$arch"
  fi
}

install_ori() {
  step "ORI (direct GitHub release)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local asset url checksums_url
  asset="$(ori_asset_name)"
  url="$ORI_RELEASE_BASE/$asset"
  checksums_url="$ORI_RELEASE_BASE/SHA256SUMS"
  local tmp="$XDG_DATA_HOME/_ori.bin"
  local sha=""

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "ORI download failed: $url"

  # Fetch the matching checksum for this asset from SHA256SUMS.
  # Format per line: "<sha256>  <asset-name>" (two spaces).
  local sums="$XDG_DATA_HOME/_ori-sha256sums"
  if curl -fsSL "$checksums_url" -o "$sums" 2>/dev/null; then
    sha="$(awk -v a="$asset" '$2 == a {print $1}' "$sums")"
    rm -f "$sums"
  fi

  verify_sha256 "$tmp" "$sha" "ori ($asset)"

  # Fresh-install contract: remove any stale target before installing.
  rm -f "$XDG_BIN_HOME/ori"
  mv -f "$tmp" "$XDG_BIN_HOME/ori"
  chmod +x "$XDG_BIN_HOME/ori"
  ok "ori installed: $XDG_BIN_HOME/ori ($("$XDG_BIN_HOME/ori" --version 2>&1 | head -1))"
  record_tool_env_vars ORI_CONFIG_DIR
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool ori ORI_CONFIG_DIR -- "$XDG_BIN_HOME"
}

# ── Download / media tools (direct binaries) ────────────────────────────────
# rclone — downloads.rclone.org hosts a VERSIONLESS "current" symlink per
# platform (the canonical mirror of GitHub releases). The zip wraps the binary
# in a versioned dir (rclone-vX-linux-<arch>/); no checksum file on the current
# channel, so the binary is extracted and placed straight into XDG_BIN_HOME.
rclone_zip_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "rclone-current-linux-amd64.zip" ;;
    aarch64|arm64)  echo "rclone-current-linux-arm64.zip" ;;
    *)              die "rclone: unsupported arch $(uname -m)" ;;
  esac
}

install_rclone() {
  step "rclone (direct binary)"
  need_cmd curl
  need_cmd unzip
  mkdir -p "$XDG_BIN_HOME"

  local zip
  zip="$(rclone_zip_name)"
  local url="$RCLONE_DOWNLOAD_BASE/$zip"
  local tmp="$XDG_DATA_HOME/_rclone.zip"
  local tmpdir="$XDG_DATA_HOME/_rclone-extract"

  echo "  Downloading $zip"
  curl -fsSL "$url" -o "$tmp" || die "rclone download failed: $url"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  unzip -o -q "$tmp" -d "$tmpdir"

  local bin
  bin="$(find "$tmpdir" -type f -name rclone -print -quit)"
  [[ -n "$bin" ]] || die "rclone archive is missing the 'rclone' binary"
  rm -f "$XDG_BIN_HOME/rclone"
  mv -f "$bin" "$XDG_BIN_HOME/rclone"
  chmod +x "$XDG_BIN_HOME/rclone"
  rm -rf "$tmpdir" "$tmp"
  ok "rclone installed: $XDG_BIN_HOME/rclone ($("$XDG_BIN_HOME/rclone" --version 2>&1 | head -1))"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool rclone -- "$XDG_BIN_HOME"
}

# qBittorrent-nox — userdocs/qbittorrent-nox-static ships ONE static binary per
# arch (ARCH-qbittorrent-nox), versionless asset name so latest/download
# resolves. No upstream checksum file; downloaded straight into XDG_BIN_HOME.
qbt_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "x86_64-qbittorrent-nox" ;;
    aarch64|arm64)  echo "aarch64-qbittorrent-nox" ;;
    *)              die "qBittorrent-nox: unsupported arch $(uname -m)" ;;
  esac
}

install_qbt() {
  step "qBittorrent-nox (static binary)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local asset
  asset="$(qbt_asset_name)"
  local url="$QBT_RELEASE_BASE/$asset"
  local tmp="$XDG_DATA_HOME/_qbittorrent-nox.bin"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "qBittorrent-nox download failed: $url"
  chmod +x "$tmp"
  rm -f "$XDG_BIN_HOME/qbittorrent-nox"
  mv -f "$tmp" "$XDG_BIN_HOME/qbittorrent-nox"
  ok "qbittorrent-nox installed: $XDG_BIN_HOME/qbittorrent-nox ($("$XDG_BIN_HOME/qbittorrent-nox" --version 2>&1 | head -1))"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool qbt -- "$XDG_BIN_HOME"
}

# aria2c — github.com/aria2/aria2 releases ship SOURCE only (no Linux binary);
# abcfy2/aria2-static-build repackages them as static musl zips:
# aria2-<arch>-linux-musl_static.zip. Versionless asset -> latest/download;
# the zip holds a single top-level 'aria2c' binary.
aria2_zip_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "aria2-x86_64-linux-musl_static.zip" ;;
    aarch64|arm64)  echo "aria2-aarch64-linux-musl_static.zip" ;;
    *)              die "aria2c: unsupported arch $(uname -m)" ;;
  esac
}

install_aria2() {
  step "aria2c (direct static binary)"
  need_cmd curl
  need_cmd unzip
  mkdir -p "$XDG_BIN_HOME"

  local zip
  zip="$(aria2_zip_name)"
  local url="$ARIA2_RELEASE_BASE/$zip"
  local tmp="$XDG_DATA_HOME/_aria2.zip"
  local tmpdir="$XDG_DATA_HOME/_aria2-extract"

  echo "  Downloading $zip"
  curl -fsSL "$url" -o "$tmp" || die "aria2c download failed: $url"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  unzip -o -q "$tmp" -d "$tmpdir"
  [[ -f "$tmpdir/aria2c" ]] || die "aria2 archive is missing the 'aria2c' binary"
  rm -f "$XDG_BIN_HOME/aria2c"
  mv -f "$tmpdir/aria2c" "$XDG_BIN_HOME/aria2c"
  chmod +x "$XDG_BIN_HOME/aria2c"
  rm -rf "$tmpdir" "$tmp"
  ok "aria2c installed: $XDG_BIN_HOME/aria2c ($("$XDG_BIN_HOME/aria2c" --version 2>&1 | head -1))"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool aria2 -- "$XDG_BIN_HOME"
}

# FFmpeg — BtbN static GPL build (newer than the Replit Nix-built 6.1.2).
# linux64/linuxarm64 GPL tarballs bundle ffmpeg/ffprobe/ffplay with no shared
# -lib deps. Versionless asset names under the "latest" tag; SHA256 verified
# against the release's checksums.sha256.
ffmpeg_tar_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "ffmpeg-master-latest-linux64-gpl.tar.xz" ;;
    aarch64|arm64)  echo "ffmpeg-master-latest-linuxarm64-gpl.tar.xz" ;;
    *)              die "FFmpeg: unsupported arch $(uname -m)" ;;
  esac
}

install_ffmpeg() {
  step "FFmpeg (static GPL build)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME"

  local asset sha
  asset="$(ffmpeg_tar_name)"
  local url="$FFMPEG_RELEASE_BASE/$asset"
  local tmp="$XDG_DATA_HOME/_ffmpeg.tar.xz"
  local tmpdir="$XDG_DATA_HOME/_ffmpeg-extract"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "FFmpeg download failed: $url"

  # Verify against the release's checksums.sha256 (format "<sha>  <asset>").
  local sums="$XDG_DATA_HOME/_ffmpeg-checksums"
  sha=""
  if curl -fsSL "$FFMPEG_RELEASE_BASE/checksums.sha256" -o "$sums" 2>/dev/null; then
    sha="$(awk -v a="$asset" '$2 == a {print $1}' "$sums")"
    rm -f "$sums"
  fi
  verify_sha256 "$tmp" "$sha" "ffmpeg ($asset)"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xJf "$tmp" -C "$tmpdir"

  local bindir
  bindir="$(find "$tmpdir" -type d -name bin -print -quit)"
  [[ -n "$bindir" && -f "$bindir/ffmpeg" ]] || die "FFmpeg archive is missing bin/ffmpeg"
  rm -f "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"
  cp -f "$bindir/ffmpeg" "$XDG_BIN_HOME/ffmpeg"
  cp -f "$bindir/ffprobe" "$XDG_BIN_HOME/ffprobe"
  cp -f "$bindir/ffplay" "$XDG_BIN_HOME/ffplay"
  chmod +x "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"
  rm -rf "$tmpdir" "$tmp"
  ok "ffmpeg installed: $XDG_BIN_HOME/ffmpeg ($("$XDG_BIN_HOME/ffmpeg" -version 2>&1 | head -1))"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool ffmpeg -- "$XDG_BIN_HOME"
}

# Cleanup (removes installed toolchain artifacts) ─────────────────────────────
rm_bin() { local b; for b in "$@"; do rm -f "$XDG_BIN_HOME/$b"; done; }
rm_dir() { local d; for d in "$@"; do rm -rf "$d"; done; }

rm_data() {
  local tool="$1" dir="$2"
  rm -rf "$dir"
  rm_bin "$tool"
}

# True when the tool has something to remove — a binary in XDG_BIN_HOME or
# any of the extra paths given (payload dirs, npm-global copies, …). Used by
# every clean_* to skip rather than claim a removal that never happened.
# [[ -e || -L ]] so a dangling symlink (target already gone) still counts as
# present and gets cleaned up rather than left as a stale link.
_present() {
  local p
  for p in "$@"; do [[ -e "$p" || -L "$p" ]] && return 0; done
  return 1
}

# nothing_removed <label>: honest skip for an already-absent tool.
nothing_removed() { skip "$1 not installed — nothing to remove"; }

# True when the given package is installed as a GLOBAL npm package (opencode-ai,
# @anthropic-ai/claude-code). Those installs don't create an XDG_BIN_HOME binary,
# so _present alone would skip them and leak the global package on clean.
_npm_global_installed() {
  command -v npm &>/dev/null || return 1
  npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 "$1" &>/dev/null 2>&1
}

clean_android() {
  if ! _present "$JAVA_HOME" "$SDK" "$XDG_BIN_HOME/java" "$XDG_BIN_HOME/adb"; then
    nothing_removed "Android toolchain"; return 0
  fi
  step "Removing Android toolchain (Java $JAVA_MAJOR + SDK)"
  rm_data android "$JAVA_HOME"
  rm -rf "$SDK"
  rm_bin java javac jar jshell javap sdkmanager avdmanager adb
  ok "Android toolchain removed"
}

clean_uv() {
  if ! _present "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx" "$XDG_DATA_HOME/uv" \
                "$WORKSPACE/.local/bin/uv" "$WORKSPACE/.cargo/bin/uv" "$WORKSPACE/.cache/uv"; then
    nothing_removed "uv"; return 0
  fi
  step "Removing uv"
  rm -rf "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx" "$XDG_DATA_HOME/uv" \
         "$WORKSPACE/.local/bin/uv" "$WORKSPACE/.cargo/bin/uv" "$WORKSPACE/.cache/uv"
  ok "uv removed"
}

clean_node() {
  if ! _present "$NODE_DIR" "$XDG_BIN_HOME/node"; then
    nothing_removed "Node.js"; return 0
  fi
  step "Removing Node.js"
  rm_data node "$NODE_DIR"
  rm_bin node npm npx
  ok "Node.js removed"
}

clean_opencode() {
  if ! _present "$XDG_BIN_HOME/opencode" "$OPENCODE_CONFIG_DIR" \
       && ! _npm_global_installed "opencode-ai"; then
    nothing_removed "OpenCode"; return 0
  fi
  step "Removing OpenCode"
  # Binary lives directly in XDG_BIN_HOME (single-file install); the npm
  # package (opencode-ai) is a GLOBAL install, so it must be removed with
  # `npm uninstall -g` — a local `npm uninstall` leaves the global bin intact.
  rm -f "$XDG_BIN_HOME/opencode"
  if command -v npm &>/dev/null \
     && npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 opencode-ai &>/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g opencode-ai \
      || warn "npm uninstall -g opencode-ai failed — remove it manually"
  fi
  rm -rf "$OPENCODE_CONFIG_DIR"
  ok "OpenCode removed"
}

clean_ollama() {
  if ! _present "$OLLAMA_INSTALL_DIR" "$XDG_BIN_HOME/ollama"; then
    nothing_removed "Ollama"; return 0
  fi
  step "Removing Ollama"
  rm_data ollama "$OLLAMA_INSTALL_DIR"
  rm_bin ollama
  ok "Ollama removed"
}

clean_claude() {
  if ! _present "$XDG_BIN_HOME/claude" \
       && ! _npm_global_installed "@anthropic-ai/claude-code"; then
    nothing_removed "Claude Code"; return 0
  fi
  step "Removing Claude Code"
  # Binary lives directly in XDG_BIN_HOME (single-file smart install); if it
  # was installed as the global npm package @anthropic-ai/claude-code instead,
  # that copy survives an rm — so also `npm uninstall -g` it.
  rm -f "$XDG_BIN_HOME/claude"
  if command -v npm &>/dev/null \
     && npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 @anthropic-ai/claude-code &>/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g @anthropic-ai/claude-code \
      || warn "npm uninstall -g @anthropic-ai/claude-code failed — remove it manually"
  fi
  ok "Claude Code removed"
}

clean_hermes() {
  if ! _present "$HERMES_HOME" "$XDG_BIN_HOME/hermes"; then
    nothing_removed "Hermes Agent"; return 0
  fi
  step "Removing Hermes Agent"
  rm_data hermes "$HERMES_HOME"
  rm_bin hermes hermes-agent hermes-acp
  ok "Hermes Agent removed"
}

clean_ori() {
  if ! _present "$XDG_BIN_HOME/ori"; then
    nothing_removed "ORI"; return 0
  fi
  step "Removing ORI"
  # Binary lives directly in XDG_BIN_HOME (single-file smart install).
  rm -f "$XDG_BIN_HOME/ori"
  ok "ORI removed"
}

clean_rclone() {
  if ! _present "$XDG_BIN_HOME/rclone"; then
    nothing_removed "rclone"; return 0
  fi
  step "Removing rclone"
  rm -f "$XDG_BIN_HOME/rclone"
  ok "rclone removed"
}

clean_qbt() {
  if ! _present "$XDG_BIN_HOME/qbittorrent-nox"; then
    nothing_removed "qBittorrent-nox"; return 0
  fi
  step "Removing qBittorrent-nox"
  rm -f "$XDG_BIN_HOME/qbittorrent-nox"
  ok "qBittorrent-nox removed"
}

clean_aria2() {
  if ! _present "$XDG_BIN_HOME/aria2c"; then
    nothing_removed "aria2c"; return 0
  fi
  step "Removing aria2c"
  rm -f "$XDG_BIN_HOME/aria2c"
  ok "aria2c removed"
}

clean_ffmpeg() {
  if ! _present "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"; then
    nothing_removed "FFmpeg"; return 0
  fi
  step "Removing FFmpeg"
  rm -f "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"
  ok "FFmpeg removed"
}

# Strip the '# >>> toolchain >>>' … '# <<< toolchain <<<' managed block from a
# file, writing the result back THROUGH the path (cat >) so a symlink target
# is preserved — sed -i would replace the symlink with a plain file.
strip_rc_block() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk '/^# >>> toolchain >>>/{s=1} s{ if(/^# <<< toolchain <<</) s=0; next } {print}' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# Remove ONLY the lines owned by <tool> from the managed shell block (rc;
# the .replit twin is strip_userenv_keys, below).
# The block is stripped line-by-line; lines whose var/dir maps to <tool> via
# _WIRE_OWNER are dropped; everything else (including unregistered lines like
# the XDG exports from the replit block) is kept. The block markers themselves
# are preserved if ANY lines remain; if the block becomes empty, the whole
# block (markers + contents) is removed.
strip_tool_wiring() {
  local tool="$1" file="$2"
  [[ -f "$file" ]] || return 0

  local in_block=0
  local -a out=()
  local line var dir owner

  while IFS= read -r line; do
    case "$line" in
      '# >>> toolchain >>>')
        in_block=1
        out+=("$line")
        continue
        ;;
      '# <<< toolchain <<<')
        if (( in_block )); then
          # If the block is only markers (no tool lines left) remove both.
          local last_idx=$(( ${#out[@]} - 1 ))
          if [[ $last_idx -ge 0 && "${out[last_idx]}" == '# >>> toolchain >>>' ]]; then
            unset 'out[last_idx]'
          else
            out+=("$line")
          fi
        else
          out+=("$line")
        fi
        in_block=0
        continue
        ;;
    esac

    if (( in_block )); then
      owner=""
      if [[ "$line" == 'case ":$PATH:" in '* ]]; then
        local re='\*"([^"]*)"\*'
        if [[ "$line" =~ $re ]]; then
          dir="${BASH_REMATCH[1]#:}"
          dir="${dir%:}"
          owner="$(path_dir_owner "$dir")"
        fi
      elif [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]] \
         || [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
        var="${BASH_REMATCH[1]}"
        owner="$(env_var_owner "$var")"
      fi

      if owned_only_by "$owner" "$tool"; then
        # Drop the line — it's owned by the tool being cleaned.
        continue
      fi
      # Keep lines owned by other tools and unregistered lines (platform exports, etc.)
      out+=("$line")
    else
      out+=("$line")
    fi
  done < "$file"

  # Write back through the path (preserves symlinks)
  local tmp="$(mktemp)"
  printf '%s\n' ${out[@]+"${out[@]}"} > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Prompts for confirmation before an irreversible cleanup. Skips when
# `--yes` was given or stdin isn't a TTY (non-interactive default is proceed).
confirm_clean() {
  $YES && return 0
  [[ -t 0 ]] || return 0
  local ans
  printf '%sProceed with cleanup of %s%s? [y/N] ' \
    "$COL_YELLOW" "${CLEAN_TARGET:-all}" "$COL_RESET"
  IFS= read -r ans || true
  # Declining (or Ctrl-D) is a voluntary no-op, NOT a failure — never a red
  # ERROR and never exit 1. Mirrors the menu-quit idiom in interactive_menu.
  if [[ "$ans" != y && "$ans" != Y && "$ans" != yes && "$ans" != YES ]]; then
    echo -e "\n${COL_YELLOW}Cleanup cancelled.${COL_RESET}"
    exit 130
  fi
}

clean() {
  seed_tool_wiring
  mkdir -p "$XDG_BIN_HOME"
  unset _MENU_ITEMS _MENU_CURSOR _MENU_TOGGLE 2>/dev/null || true
  local summary hint

  # Dispatch order (explicit target / full wipe / misc state → wiring
  # strip; menu-selected tools → per-tool only). No set -e trap under us: the
  # function returns 0 only after real cleanup; an empty menu selection
  # (nothing ticked) short-circuits below as a graceful no-op — the menu can
  # never trigger an irreversible full wipe.
  summary="$CLEAN_TARGET"
  hint="bash scripts/setup.sh --all"
  case "$CLEAN_TARGET" in
    android-tools|uv|node|oc|opencode|ollama|claude|hermes|ori|rclone|qbt|aria2|ffmpeg)
      hint="bash scripts/setup.sh --$CLEAN_TARGET"
      ;;
  esac
  case "$CLEAN_TARGET" in
    all)
      step "Cleaning entire toolchain"
      # Strip env wiring FIRST: strip_userenv_keys needs a tomlkit-capable
      # interpreter, and clean_uv deletes uv — the fallback tomlkit source
      # when python3/.venv lack it — as a side effect of removing binaries.
      # 'all' is the ONLY path that strips env wiring (the rc / .replit
      # managed blocks) — per-target clean removes binaries + payload only.
      if [[ -f "$BASHRC" ]]; then
        strip_rc_block "$BASHRC"
        ok "Stripped managed block from $BASHRC"
      fi
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      # Only replit mode ever wrote a userenv block — don't touch .replit
      # otherwise (default mode is .bashrc-only by design). strip_userenv_keys
      # checks writability and removes every managed key (an emptied
      # [userenv.shared] table is dropped by the tomlkit writer).
      if [[ "$REPLIT_MODE" == true && -f "$replit_file" ]]; then
        strip_userenv_keys all "$replit_file"
      fi
      clean_android
      clean_uv
      clean_node
      clean_opencode
      clean_ollama
      clean_claude
      clean_hermes
      clean_ori
      clean_rclone
      clean_qbt
      clean_aria2
      clean_ffmpeg
      ok "Full toolchain cleanup complete"
      ;;
    android-tools|uv|node|oc|opencode|ollama|claude|hermes|ori|rclone|qbt|aria2|ffmpeg)
      # Drop this tool's wiring from the managed blocks FIRST (strip_userenv_keys
      # needs a tomlkit-capable interpreter; clean_uv deletes uv, the fallback
      # source), then remove the binaries + payload. Labels here differ from
      # wire_tool ownership labels: android-tools -> android, oc -> opencode.
      local wire_label="$CLEAN_TARGET"
      case "$wire_label" in
        android-tools) wire_label=android ;;
        oc) wire_label=opencode ;;
      esac
      [[ -f "$BASHRC" ]] && strip_tool_wiring "$wire_label" "$BASHRC"
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && strip_userenv_keys "$wire_label" "$replit_file"
      case "$CLEAN_TARGET" in
        android-tools) clean_android ;;
        uv)            clean_uv ;;
        node)          clean_node ;;
        oc|opencode)   clean_opencode ;;
        ollama)        clean_ollama ;;
        claude)        clean_claude ;;
        hermes)        clean_hermes ;;
        ori)           clean_ori ;;
        rclone)        clean_rclone ;;
        qbt)           clean_qbt ;;
        aria2)         clean_aria2 ;;
        ffmpeg)        clean_ffmpeg ;;
      esac
      ;;
    "")
      # Reached from the clean MENU: remove exactly the tools TICKED
      # (binary + payload only, not env wiring). An empty selection is a
      # graceful no-op — nothing to remove.
      if [[ ${#CLEAN_TOOLS[@]} -eq 0 ]]; then
        skip "no tools selected in the cleanup menu — nothing removed"
        return 0
      fi
      summary="$(IFS=','; echo "${CLEAN_TOOLS[*]}")"
      hint="bash scripts/setup.sh"
      # Drop env wiring FIRST (strip_userenv_keys needs a tomlkit-capable
      # interpreter; clean_uv deletes uv, the fallback source), then remove
      # the ticked binaries + payload.
      [[ -f "$BASHRC" ]] && strip_tool_wiring "${CLEAN_TOOLS[*]}" "$BASHRC"
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && strip_userenv_keys "${CLEAN_TOOLS[*]}" "$replit_file"
      local label
      for label in "${CLEAN_TOOLS[@]}"; do
        case "$label" in
          android)  clean_android ;;
          uv)       clean_uv ;;
          node)     clean_node ;;
          opencode) clean_opencode ;;
          ollama)   clean_ollama ;;
          claude)   clean_claude ;;
          hermes)   clean_hermes ;;
          ori)      clean_ori ;;
          rclone)   clean_rclone ;;
          qbt)      clean_qbt ;;
          aria2)    clean_aria2 ;;
          ffmpeg)   clean_ffmpeg ;;
          *)        warn "Unknown clean target '$label' — skipped" ;;
        esac
      done
      ;;
    *)
      die "Unknown --clean target '$CLEAN_TARGET'. Valid: all, android-tools, uv, node, oc, opencode, ollama, claude, hermes, ori, rclone, qbt, aria2, ffmpeg"
      ;;
  esac
  cat <<CLEANMSG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Cleanup complete for: $summary

 Reinstall: $hint
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CLEANMSG
}

# Main ───────────────────────────────────────────────────────────────────────
main() {
  # Tool selection:
  #   "tool args" = any option that is NOT a BARE --clean/-c (an install flag,
  #     --all, --doctor, --help, or --clean with an explicit target such as
  #     '--clean all'). When no tool args are present and stdout is a
  #     terminal, open the interactive menu — which serves BOTH install
  #     (pick tools to install) and clean (pick tools to remove):
  #       bare `setup.sh`          -> install pick-menu
  #       bare `setup.sh --clean`  -> clean pick-menu    (`-c` is the same)
  #   - Explicit targets never open a menu: `--clean all` (or `--clean --all`)
  #     wipes everything, `--clean node` removes one tool, `--all` installs all.
  #   - Non-interactive (no TTY): parse_args decides — "no flag" installs all,
  #     and BARE --clean cleans all (full wipe), the documented
  #     non-interactive default.
  local _arg tool_args=0 bare_clean=0 menu_ran=0
  for _arg in "$@"; do
    if [[ "$_arg" == "--clean" || "$_arg" == "-c" ]]; then
      # Bare --clean / -c: records the clean intent. A following target word
      # (or flag) flips tool_args below and routes through parse_args.
      bare_clean=1
    else
      # A bareword target ('all', 'node', ...) or any other flag — an explicit
      # selection that never opens a pick-menu.
      tool_args=1
      break
    fi
  done
  if (( tool_args == 0 )) && [[ -t 1 ]]; then
    if (( bare_clean )); then
      # Bare --clean/-c on a terminal: open the CLEAN pick-menu.
      CLEAN=true
      MENU_MODE="clean"
    fi
    interactive_menu
    menu_ran=1
    unset _MENU_ITEMS _MENU_CURSOR _MENU_TOGGLE 2>/dev/null || true
    if ! $CLEAN \
      && ! $INSTALL_ANDROID && ! $INSTALL_NODE && ! $INSTALL_UV \
      && ! $INSTALL_OPENCODE && ! $INSTALL_OLLAMA && ! $INSTALL_CLAUDE \
      && ! $INSTALL_HERMES && ! $INSTALL_ORI && ! $INSTALL_RCLONE \
      && ! $INSTALL_QBT && ! $INSTALL_ARIA2 && ! $INSTALL_FFMPEG; then
      die "No tools selected. Aborting."
    fi
  else
    parse_args "$@"
    # A bare --clean (no target) means a full wipe when non-interactive.
    if $CLEAN && [[ -z "$CLEAN_TARGET" ]]; then
      CLEAN_TARGET="all"
    fi
  fi

  if $CLEAN; then
    # The pick-menu already confirmed the selection; only a flag-driven
    # cleanup still needs the y/N prompt.
    (( menu_ran )) || confirm_clean
    clean
    exit 0
  fi

  if $LIST_STATE; then
    list_state
    exit 0
  fi

  # Always (re)wire the shell environment on exit — even if an install step
  # fails, the toolchain portions that succeeded remain usable in new
  # shells (e.g. running --all where one component errors out).
  add_exit_action 'write_bashrc'
  add_exit_action 'write_replit_env'
  # After write_replit_env, and unconditional in replit mode: the workflow
  # shim + its REPLIT_BASHRC pin must be re-asserted on every run, because
  # write_replit_env rewrites the [userenv.shared] table wholesale.
  add_exit_action 'write_replit_bashrc'

  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME"

  $INSTALL_ANDROID  && install_android_tools
  $INSTALL_UV       && install_uv
  $INSTALL_NODE     && install_node
  $INSTALL_OPENCODE && install_opencode
  $INSTALL_OLLAMA   && install_ollama
  $INSTALL_CLAUDE   && install_claude
  $INSTALL_HERMES   && install_hermes
  $INSTALL_ORI      && install_ori
  $INSTALL_RCLONE   && install_rclone
  $INSTALL_QBT      && install_qbt
  $INSTALL_ARIA2    && install_aria2
  $INSTALL_FFMPEG   && install_ffmpeg

  if $DOCTOR; then
    doctor || true
  fi

  if $INSTALL_ANDROID; then
    local USED
    USED=$(du -sh "$XDG_DATA_HOME" 2>/dev/null | cut -f1 || echo "?")
    echo ""
    echo "  Android toolchain size: $USED"
  fi

  if [[ "$REPLIT_MODE" == true ]]; then
    cat <<SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Setup complete!

 Toolchain lives in: $WORKSPACE
   binaries  $XDG_BIN_HOME
   payload   $XDG_DATA_HOME
 Shell env written to: $BASHRC
# (=$WORKSPACE/.config/bashrc; open a new shell to load it)
 Global env written to: ${REPL_HOME:-$WORKSPACE}/.replit
   ([userenv.shared] — applies to all repl processes after env rebuild)

 Run directly, no sourcing needed:
   java --version  adb --version  node --version
   opencode  ollama  claude  hermes  ori
   rclone  qbittorrent-nox  aria2c  ffmpeg  ffprobe
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
  else
    cat <<SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Setup complete! (default mode — \$HOME layout)

 Toolchain lives in:
   binaries  $XDG_BIN_HOME
   payload   $XDG_DATA_HOME
   workspace $WORKSPACE
 Shell env written to: $BASHRC
   (minimal PATH block — open a new shell)

 Run directly, no sourcing needed:
   java --version  adb --version  node --version
   opencode  ollama  claude  hermes  ori
   rclone  qbittorrent-nox  aria2c  ffmpeg  ffprobe
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
  fi
}

if ! bash -n "$0"; then
  die "Script has syntax errors — refusing to run"
fi

main "$@"
