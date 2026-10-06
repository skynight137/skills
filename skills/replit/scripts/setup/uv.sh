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
  UV_INSTALL_DIR="$XDG_BIN_HOME" bash "$installer" --no-modify-path || die "uv install failed"
  rm -f "$installer"
  [[ -x "$XDG_BIN_HOME/uv" ]] || die "uv install did not produce $XDG_BIN_HOME/uv"
  ok "uv installed: $XDG_BIN_HOME/uv"
  record_tool_env_vars UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool uv UV_PYTHON_DOWNLOADS UV_PYTHON_PREFERENCE PYTHONPATH -- "$XDG_BIN_HOME"
}
