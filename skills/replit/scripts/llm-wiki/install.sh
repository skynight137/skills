#!/usr/bin/env bash
# llm-wiki installer + server bootstrap (plain Linux; nothing Nix-specific).
#
#   bash install.sh                       # fetch the AppImage, extract, make a token
#   LLM_WIKI_APPIMAGE=/tmp/app.AppImage bash install.sh
#   LLM_WIKI_APPIMAGE_URL=https://.../app.AppImage bash install.sh
#
# After it finishes:  bash run-public.sh   (supervisor: app + node server)
# Server endpoint:    https://<host>:8080/mcp   (Authorization: Bearer <token>)
# Local agents:       http://127.0.0.1:8199/mcp (loopback, no token)
#
# Requirements: node >= 18 (that is the whole runtime for the server), curl,
# and for the desktop app itself an X display: a real one, or Xvfb + a window
# manager. On this image (NixOS) they are in the nix store:
#   nix build nixpkgs#xvfb nixpkgs#fluxbox nixpkgs#shared-mime-info
set -uo pipefail
APP="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$APP/llmwiki.env"
REPO="nashsu/llm_wiki"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || die "node is required (v18+); install it and re-run"
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' \
  || die "node $(node -v) is too old; need v18+"
command -v curl >/dev/null 2>&1 || die "curl is required"

# --- 1. the desktop app -----------------------------------------------------
if [ ! -x "$APP/squashfs-root/usr/bin/llm-wiki" ]; then
  IMG="${LLM_WIKI_APPIMAGE:-$APP/app.AppImage}"
  if [ ! -f "$IMG" ]; then
    URL="${LLM_WIKI_APPIMAGE_URL:-}"
    if [ -z "$URL" ]; then
      say "looking up the latest release of $REPO ..."
      URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -o '"browser_download_url": *"[^"]*\.AppImage"' | head -1 | cut -d'"' -f4)
    fi
    [ -n "$URL" ] || die "no AppImage URL found; pass LLM_WIKI_APPIMAGE=/path or LLM_WIKI_APPIMAGE_URL=..."
    say "downloading $URL"
    curl -fL --retry 3 -o "$IMG" "$URL" || die "download failed"
  fi
  chmod +x "$IMG"
  say "extracting $IMG"
  ( cd "$APP" && "$IMG" --appimage-extract >/dev/null ) || die "extraction failed"
  [ -x "$APP/squashfs-root/usr/bin/llm-wiki" ] || die "extraction produced no binary"
else
  say "app already extracted"
fi

# --- 2. shared token --------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  TOKEN=$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')
  printf 'LLM_WIKI_API_TOKEN=%s\n' "$TOKEN" >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "wrote $ENV_FILE (chmod 600)"
  say "token sha256[:12] = $(printf %s "$TOKEN" | sha256sum | cut -c1-12)"
else
  say "token file already present: $ENV_FILE"
fi

# --- 3. machine-specific library dirs (optional) ----------------------------
[ -f "$APP/.libdirs.pre" ] || { : >"$APP/.libdirs.pre"; say "created empty .libdirs.pre (add lib dirs only if the app fails to start)"; }

# --- 4. sanity checks -------------------------------------------------------
command -v Xvfb >/dev/null 2>&1 || say "note: no Xvfb found — the app needs a display (nix build nixpkgs#xvfb)"
command -v fluxbox >/dev/null 2>&1 || command -v openbox >/dev/null 2>&1 \
  || say "note: no window manager found — GTK windows stay unmapped without one (nix build nixpkgs#fluxbox)"

say ""
say "done. start the stack with:"
say "  bash $APP/run-public.sh"
say ""
say "endpoints once running:"
say "  public : https://<host>:8080/mcp     header  Authorization: Bearer \$(cat $ENV_FILE)"
say "  local  : http://127.0.0.1:8199/mcp   (loopback only, no header)"
say "  rest   : https://<host>:8080/api/v1/health"
say ""
say "register with a local Hermes profile:"
say "  hermes -p <profile> mcp add llm-wiki --url http://127.0.0.1:8199/mcp"
