# llm-wiki.sh — the llm-wiki knowledge server, installed by one flag.
#
#   bash setup.sh --llm-wiki
#
# Installs the bundle shipped in scripts/llm-wiki/ into
# ${LLM_WIKI_HOME:-$XDG_DATA_HOME/llmwiki-app}:
#
#   install.sh        fetch the AppImage, extract it, mint the shared token
#   run-public.sh     supervisor: Xvfb + WM + app + the REST/MCP server
#                     (19828 app API · public port $LLM_WIKI_PORT or 8080, token required
#                      · 8199 loopback, no token)
#   run-ui.sh         supervisor: x11vnc (loopback 5900) + noVNC (public 8000) so the real
#                     desktop UI opens in a browser — the frontend is Tauri, there is no
#                     web UI to serve
#   start-app.sh      app launcher with the software-GL / pixbuf env it needs headless
#   llmwiki-server.js the Node server that speaks REST + MCP (streamable HTTP)
#
# Replit is a NixOS box: packages come from the nix store, never apt. Everything on PATH
# here is already nix-provided, and a missing piece is one `nix build` away (a replit.nix
# entry makes it survive a recreate). Nothing in this path needs Nix itself — the app is a
# prebuilt AppImage and the server is Node stdlib.
#
# Runtime facts that cost real debugging time (see references/llm-wiki-server.md):
#   * a window manager is mandatory — without one GTK windows are created but never mapped
#   * shared-mime-info must be on XDG_DATA_DIRS, or gdk-pixbuf rejects every image format
#   * the app needs node >= 18 for the server, and curl for the download

install_llm_wiki() {
  local src="$SCRIPT_DIR/llm-wiki" dest note=""

  # Never create a SECOND copy: on a box that already runs the server from its own
  # directory (a workflow points at it and it holds that box's tokens + port), reuse
  # that directory. Otherwise a re-run silently forks the install and the old copy
  # keeps serving whatever the workflow starts.
  if [[ -n "${LLM_WIKI_HOME:-}" ]]; then
    dest="$LLM_WIKI_HOME"
  elif [[ -n "${WORKSPACE:-}" && -x "$WORKSPACE/tools/llmwiki-app/run-public.sh" ]]; then
    dest="$WORKSPACE/tools/llmwiki-app"
    note=" (reusing the existing install)"
  else
    dest="${XDG_DATA_HOME:-$HOME/.local/share}/llmwiki-app"
  fi

  [ -d "$src" ] || { warn "bundle missing: $src"; return 1; }
  mkdir -p "$dest"
  cp -f "$src/install.sh" "$src/run-public.sh" "$src/run-ui.sh" \
        "$src/start-app.sh" "$src/llmwiki-server.js" "$dest/"
  chmod +x "$dest"/*.sh
  echo "  llm-wiki bundle -> $dest$note"

  llm_wiki_requirements
  ( cd "$dest" && bash install.sh ) || return 1

  local port="${LLM_WIKI_PORT:-8080}"
  cat <<NEXT

  llm-wiki is installed. Start it:
    bash $dest/run-public.sh        # app + REST/MCP server (public :$port, loopback :8199)
    bash $dest/run-ui.sh            # optional: the desktop UI in a browser (noVNC :8000)

  Add this URL to your MCP client:
    http://127.0.0.1:8199/mcp                # loopback, no token (agents on this machine)
    https://<host>:$port/mcp                 # other machines; header Authorization: Bearer <token>

  Token: $dest/llmwiki.env (chmod 600) — share that file's value when access is needed.
NEXT
}

# Report-only: a user-level setup never installs system packages. Resolve each tool from
# PATH first, then the nix store — on Replit a built package is reachable there even when
# it never made it onto PATH.
_llm_wiki_bin() {
  command -v "$1" >/dev/null 2>&1 && return 0
  # shellcheck disable=SC2086
  ls -d $2 >/dev/null 2>&1
}

llm_wiki_requirements() {
  local missing=()
  command -v node >/dev/null 2>&1 || missing+=("node (>=18 — runs the REST/MCP server)")
  command -v curl >/dev/null 2>&1 || missing+=("curl (fetches the AppImage)")
  _llm_wiki_bin Xvfb '/nix/store/*-xorg-server-*/bin/Xvfb' \
    || missing+=("Xvfb (headless display)")
  { _llm_wiki_bin fluxbox '/nix/store/*fluxbox-*/bin/fluxbox' \
    || _llm_wiki_bin openbox '/nix/store/*openbox-*/bin/openbox'; } \
    || missing+=("a window manager (fluxbox/openbox) — GTK windows stay unmapped without one")
  _llm_wiki_bin x11vnc '/nix/store/*x11vnc-*/bin/x11vnc' \
    || missing+=("x11vnc (only for the noVNC browser view)")
  if ((${#missing[@]})); then
    warn "llm-wiki: missing on this machine —"
    local m
    for m in "${missing[@]}"; do printf '    - %s\n' "$m"; done
    printf '    nix build nixpkgs#xvfb nixpkgs#fluxbox nixpkgs#x11vnc nixpkgs#novnc\n'
    printf '    (or the same names in replit.nix, so they survive a recreate)\n'
  fi
  return 0
}
