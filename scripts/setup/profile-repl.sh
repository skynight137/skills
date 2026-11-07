#!/usr/bin/env bash
# setup.sh

set -e

# The payloads use bash 4+ features (associative arrays). Fail loudly
# here instead of dying mid-run with a cryptic declare error — stock
# macOS ships bash 3.2 (on a Mac: brew install bash, then re-run).
if (( BASH_VERSINFO[0] < 4 )); then
  printf 'setup: bash >= 4 required (this is %s)\n' "$BASH_VERSION" >&2
  exit 1
fi

# Absolute path of this script's directory — the tomlkit .replit writer
# (dot_replit.py) lives next to setup.sh.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Location map after the S4 move (this profile lives in scripts/setup/;
# its lanes and payloads stay in scripts/replit/):
SETUP_LIB_DIR="$SCRIPT_DIR"               # scripts/setup — core.sh, join.sh, profiles
REPL_SKILL_DIR="$SCRIPT_DIR/../replit"    # scripts/replit — setup/ lanes + payloads
SETUP_ENTRY="$SCRIPT_DIR/../setup.sh"     # the one entry (scripts/setup.sh)

# Install root (resolved once — no flag, one env override) ──────────────────
# Set BEFORE the XDG defaults below because every path root depends on it.
# Resolve the install root ONCE, before anything else derives a path
# (setup/root.sh). The resolver owns $REPL_HOME from here on: explicit
# $SETUP_ROOT -> recorded root -> platform workspace -> die. The old silent
# default layout (WORKSPACE=$(pwd), $HOME roots) was a trap — a shell missing
# the platform env installed into the wiped $HOME tree without a word — so
# it is gone: every root uses the persistent layout, and an unresolvable
# root stops the run before anything installs.
source "$SCRIPT_DIR/../replit/setup/root.sh"
resolve_setup_root || exit 1
[[ "$SETUP_ROOT_SOURCE" == env ]] && record_setup_root
setup_root_persistence_check
mkdir -p "$SETUP_ROOT"
# A root other than the platform home must also own the XDG dirs: the
# platform pre-sets them under ITS workspace, and "pre-set wins" below
# would otherwise leak installs back into the platform workspace.
if [[ "$SETUP_ROOT" != "$(__setup_platform_home)" ]]; then
  unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_BIN_HOME
fi
REPL_HOME="$SETUP_ROOT"
REPLIT_MODE=true
printf 'setup root: %s (source: %s)\n' "$SETUP_ROOT" "$SETUP_ROOT_SOURCE"

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

# Remote access (direct binaries — see references/exposing-ports.md)
# cloudflared: Cloudflare's tunnel client. Versionless asset name, but the
# release publishes NO checksum asset (only the binary and the .deb/.rpm
# packages), so the download is unverified — same class as rclone/qbt/aria2c.
CLOUDFLARED_RELEASE_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"
# tailscale: official stable channel. The tarball name embeds the version, so it
# is resolved from the channel's JSON index at install time, and each archive
# has a `<tarball>.sha256` next to it (verified).
TAILSCALE_PKGS_BASE="https://pkgs.tailscale.com/stable"
# sshx: collaborative web terminal. Its GitHub releases carry NO assets at all
# (checked: v0.4.1 has none); the canonical artifact is the versionless S3
# tarball the sshx.io/get script pulls. No checksum published.
SSHX_DOWNLOAD_BASE="https://s3.amazonaws.com/sshx"

# Lightpanda: lightweight headless browser (CDP server) for keep-alive
# tours. Pinned release — the release publishes NO checksum asset, so
# setup/lightpanda.sh carries the per-arch size + SHA256 pins computed
# from the official downloads; they move with this version.
LIGHTPANDA_VERSION="1.0.3"
LIGHTPANDA_RELEASE_BASE="https://github.com/lightpanda-io/browser/releases/download"
# The tour client's playwright pin — the version proven against
# Lightpanda 1.0.3's CDP in the fleet trial (references/lightpanda.md).
LIGHTPANDA_PLAYWRIGHT_VERSION="1.64.1"

# OmniRoute: OpenAI-compatible AI router server (npm-global). Pinned —
# the npm registry is the only artifact source (no checksum to verify
# against beyond npm's own integrity); bump deliberately, the install
# verifies the bin + the installed package version.
OMNIROUTE_VERSION="3.8.53"

# AI agent
HERMES_INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"

# Paths ──────────────────────────────────────────────────────────────────────
# The resolved root ($REPL_HOME, owned by the resolver above) is the
# persistent dir ($HOME is wiped on restart), so the workspace and every
# XDG dir live under it.
WORKSPACE="$REPL_HOME"
cd "$WORKSPACE"

# XDG roots ──────────────────────────────────────────────────────────────────
# The FOUR vars below must end set, each honoring a pre-set XDG_* value
# (the platform/operator may have chosen one) and otherwise falling back
# UNDER $WORKSPACE (persistent). $HOME is forbidden — wiped on restart.
# NOTE (soft assumption — tweak if needed): the rc target is
# $WORKSPACE/.config/bashrc — the Replit bootstrap auto-sources it (see
# _bashrc_candidate). XDG_BIN_HOME is the single PATH entry every tool
# binary lands in. Var names below are load-bearing: the rest of the
# script, the emitted shell rc, and [userenv.shared] all read them.
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$WORKSPACE/.config}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORKSPACE/.cache}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$WORKSPACE/.local/share}"
XDG_BIN_HOME="${XDG_BIN_HOME:-$REPL_HOME/.local/bin}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_BIN_HOME WORKSPACE

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
_bashrc_candidate(){
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
  REPLIT_BASHRC_FILE="${REPLIT_BASHRC_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/replit_bashrc}"
fi

# Snapshot the environment (name → value) BEFORE the script assigns or
# exports anything — input to write_replit_env's no-shadowing rule. Values
# matter, not names: our own previous managed block comes back through the
# inherited env on re-runs (userenv feeds every repl) and must be re-emitted,
# not mistaken for operator choices.
declare -A _PRESET_ENV=()
# compgen prints BARE variable names (one per line, no value) — read each
# name and capture its VALUE via ${!name}. (The old "read line, split on ="
# form broke on '=' in input, storing name→name so no-shadowing never
# actually compared values.) Names are valid identifiers, safe to index.
while IFS= read -r _env_name; do
  [[ "$_env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && _PRESET_ENV["$_env_name"]="${!_env_name}"
done < <(compgen -e)

# Source order matters only for the top-level setup each module runs at
# source time (common initialises env/paths first; cli runs main last).
source "$SCRIPT_DIR/core.sh"
source "$SCRIPT_DIR/join.sh"  # shared join engine (S3)
source "$SCRIPT_DIR/../replit/setup/common.sh"
source "$SCRIPT_DIR/../replit/setup/ui_menu.sh"
source "$SCRIPT_DIR/../replit/setup/bin.sh"
source "$SCRIPT_DIR/../replit/setup/fix.sh"
source "$SCRIPT_DIR/../replit/setup/rc.sh"
source "$SCRIPT_DIR/../replit/setup/doctor.sh"
source "$SCRIPT_DIR/../replit/setup/uv.sh"
source "$SCRIPT_DIR/../replit/setup/zsh.sh"
source "$SCRIPT_DIR/../replit/setup/android.sh"
source "$SCRIPT_DIR/../replit/setup/node_opencode.sh"
source "$SCRIPT_DIR/../replit/setup/download.sh"
source "$SCRIPT_DIR/../replit/setup/expose.sh"
source "$SCRIPT_DIR/../replit/setup/join.sh"
source "$SCRIPT_DIR/../replit/setup/camofox.sh"
source "$SCRIPT_DIR/../replit/setup/lightpanda.sh"
source "$SCRIPT_DIR/../replit/setup/omniroute.sh"
source "$SCRIPT_DIR/../replit/setup/hermes_chromium.sh"
source "$SCRIPT_DIR/../replit/setup/llm-wiki.sh"
source "$SCRIPT_DIR/../replit/setup/cleanup.sh"
source "$SCRIPT_DIR/../replit/setup/cli.sh"
