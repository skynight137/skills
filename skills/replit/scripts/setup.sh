#!/usr/bin/env bash
# setup.sh

set -e 

# Absolute path of this script's directory — the tomlkit .replit writer
# (dot_replit.py) lives next to setup.sh.
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

# CLIProxyAPI (router-for-me) — OAuth CLI-subscription bridge (Claude Code /
# Codex / Antigravity / Gemini CLI / Kimi / xAI → OpenAI+Claude+Gemini APIs).
# Release asset name embeds the version (CLIProxyAPI_<N>_linux_amd64.tar.gz),
# so the tarball URL comes from a resolved tag (see cliproxy_asset_name).
CLIPROXY_REPO="router-for-me/CLIProxyAPI"
CLIPROXY_RELEASE_BASE="https://github.com/router-for-me/CLIProxyAPI/releases"

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
# Replit workflows run their tasks in a NON-INTERACTIVE shell with
# REPLIT_MODE=agent|workflow. The platform's store bashrc sources the
# toolchain rc (${REPL_HOME}/.config/bashrc) ONLY when REPLIT_MODE is EMPTY
# (store bashrc: `if [[ -f "${BASHRC}" ]] && [[ -z "${REPLIT_MODE}" ]]`), so in
# a workflow shell that guard fails and the managed block is skipped — a
# workflow process (shell.exec tasks in .replit, the Run button, deploys)
# inherited none of the toolchain env, and managed binaries in XDG_BIN_HOME
# were "command not found" even though the same command worked in the terminal.
#
# The platform runs non-interactive bash with $REPLIT_BASHRC as its rc file.
# Pinning REPLIT_BASHRC to this shim closes the gap: the shim unsets
# REPLIT_MODE and re-sources ~/.bashrc, so the store bashrc's guard passes and
# workflows get exactly the user terminal's env.
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

# Source order matters only for the top-level setup each module runs at
# source time (common initialises env/paths first; cli runs main last).
source "$SCRIPT_DIR/setup/common.sh"
source "$SCRIPT_DIR/setup/ui_menu.sh"
source "$SCRIPT_DIR/setup/bin.sh"
source "$SCRIPT_DIR/setup/hermes_tools.sh"
source "$SCRIPT_DIR/setup/fix.sh"
source "$SCRIPT_DIR/setup/rc.sh"
source "$SCRIPT_DIR/setup/doctor.sh"
source "$SCRIPT_DIR/setup/uv.sh"
source "$SCRIPT_DIR/setup/android.sh"
source "$SCRIPT_DIR/setup/node_opencode.sh"
source "$SCRIPT_DIR/setup/download.sh"
source "$SCRIPT_DIR/setup/cliproxy.sh"
source "$SCRIPT_DIR/setup/camofox.sh"
source "$SCRIPT_DIR/setup/cleanup.sh"
source "$SCRIPT_DIR/setup/cli.sh"
