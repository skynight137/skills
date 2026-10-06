# shellcheck shell=bash
# Node.js (managed tarball) + OpenCode installers. Sourced by setup.sh.
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
  # A failed $(node --version) inside an ok line does NOT trip set -e — on
  # this exact bug class it printed '✓ Node.js installed: ( )' with an empty
  # version while the binary could not load. Probe explicitly and die.
  local node_ver
  if ! node_ver="$("$NODE_DIR/bin/node" --version 2>&1)"; then
    die "node staged at $NODE_DIR but cannot load: $node_ver (ensure_libatomic output above? rerun: bash setup.sh --fix)"
  fi
  ok "Node.js installed: $NODE_DIR ($node_ver)"
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
    --skip-setup --skip-browser --skip-computer-use \
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
