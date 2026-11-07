# shellcheck shell=bash
# uv installer. Sourced by setup.sh.
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
  # UV_NO_MODIFY_PATH=1 replaces the deprecated --no-modify-path flag
  # (astral's installer warns on the flag: "please set UV_NO_MODIFY_PATH=1").
  UV_NO_MODIFY_PATH=1 UV_INSTALL_DIR="$XDG_BIN_HOME" bash "$installer" || die "uv install failed"
  rm -f "$installer"
  [[ -x "$XDG_BIN_HOME/uv" ]] || die "uv install did not produce $XDG_BIN_HOME/uv"
  ok "uv installed: $XDG_BIN_HOME/uv"
  record_tool_env_vars UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool uv UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH -- "$XDG_BIN_HOME"
}

# Resolve a runnable uv into the variable named $1 — PATH first, then the
# lane's own install home — INSTALLING it (same official installer as
# install_uv) when neither has one. Unlike install_uv this never dies and
# never reinstalls over an existing binary: it exists for machinery that
# needs uv as a means to an end (the tomlkit provisioning in rc.sh) on
# boxes where the uv lane itself never ran. Returns 1 when uv cannot be
# obtained (no curl, no network, installer failure).
ensure_uv_bin() {
  local -n _uv_out="$1"
  if command -v uv &>/dev/null; then
    _uv_out="$(command -v uv)"
    return 0
  fi
  if [[ -x "$XDG_BIN_HOME/uv" ]]; then
    _uv_out="$XDG_BIN_HOME/uv"
    return 0
  fi
  command -v curl &>/dev/null || return 1
  step "uv not found — installing it (needed to provision the tomlkit python)"
  local installer="$XDG_DATA_HOME/_uv-install.sh"
  mkdir -p "$XDG_BIN_HOME" "$XDG_DATA_HOME" || return 1
  curl -LsSf https://astral.sh/uv/install.sh -o "$installer" || return 1
  chmod +x "$installer"
  UV_NO_MODIFY_PATH=1 UV_INSTALL_DIR="$XDG_BIN_HOME" bash "$installer" &>/dev/null || {
    rm -f "$installer"
    return 1
  }
  rm -f "$installer"
  [[ -x "$XDG_BIN_HOME/uv" ]] || return 1
  _uv_out="$XDG_BIN_HOME/uv"
  ok "uv installed: $_uv_out"
}
