# shellcheck shell=bash
# Remote-access installers: cloudflared (Cloudflare Tunnel), tailscale
# (userspace tailnet client), sshx (collaborative web terminal). Sourced by
# setup.sh. Runtime recipes live in references/exposing-ports.md — auth,
# funnel/serve, exit nodes and the Cloudflare edge gotchas.
# ─────────────────────────────────────────────────────────────────────────────
# All three are OPTIONAL extras and none of them is STARTED here: tailscale
# needs a tailnet login, cloudflared needs a tunnel or a token, sshx prints a
# URL when it runs. setup.sh installs the binaries (checksum-verified when
# upstream publishes one) and prints the first command to run.
# ─────────────────────────────────────────────────────────────────────────────

# cloudflared — Cloudflare's tunnel client. Versionless asset name under
# latest/download; the release publishes no checksum asset (only the binary and
# the .deb/.rpm packages), so this download is unverified like rclone/qbt/aria2c.
cloudflared_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "cloudflared-linux-amd64" ;;
    aarch64|arm64)  echo "cloudflared-linux-arm64" ;;
    *)              die "cloudflared: unsupported arch $(uname -m)" ;;
  esac
}

install_cloudflared() {
  step "cloudflared (Cloudflare Tunnel client)"
  need_cmd curl
  mkdir -p "$XDG_BIN_HOME"

  local asset url tmp
  asset="$(cloudflared_asset_name)"
  url="$CLOUDFLARED_RELEASE_BASE/$asset"
  tmp="$XDG_DATA_HOME/_cloudflared.bin"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "cloudflared download failed: $url"
  chmod +x "$tmp"
  rm -f "$XDG_BIN_HOME/cloudflared"
  mv -f "$tmp" "$XDG_BIN_HOME/cloudflared"
  ok "cloudflared installed: $XDG_BIN_HOME/cloudflared ($("$XDG_BIN_HOME/cloudflared" --version 2>&1 | head -1))"
  ok "  quick tunnel (no account, prints a https://<rand>.trycloudflare.com URL):"
  ok "    cloudflared tunnel --url http://localhost:<port>"
  ok "  named tunnel: cloudflared tunnel run --token \"\$TOKEN\"  (see references/exposing-ports.md)"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool cloudflared -- "$XDG_BIN_HOME"
}

# tailscale — official stable channel. The tarball name embeds the version, so
# the version is resolved from the channel's JSON index; each archive ships a
# `<tarball>.sha256` next to it, which is verified.
tailscale_asset_name() {  # $1 = version from the channel index
  case "$(uname -m)" in
    x86_64|amd64)   echo "tailscale_${1}_amd64.tgz" ;;
    aarch64|arm64)  echo "tailscale_${1}_arm64.tgz" ;;
    *)              die "tailscale: unsupported arch $(uname -m)" ;;
  esac
}

install_tailscale() {
  step "tailscale (userspace tailnet client)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME" "$TAILSCALE_DATA_DIR/state"

  # awk reads to EOF deliberately: `grep -m1` would close the pipe early and
  # pipefail would then turn curl's SIGPIPE (23) into a hard failure.
  local ver asset url tmp tmpdir sums sha
  ver="$(curl -fsSL "$TAILSCALE_PKGS_BASE/?mode=json" 2>/dev/null \
         | awk -F'"' '/"Version"/{v=$4} END{print v}')" || true
  [[ -n "$ver" ]] || die "tailscale: could not resolve the stable version from $TAILSCALE_PKGS_BASE/?mode=json"
  asset="$(tailscale_asset_name "$ver")"
  url="$TAILSCALE_PKGS_BASE/$asset"
  tmp="$XDG_DATA_HOME/_tailscale.tgz"
  tmpdir="$XDG_DATA_HOME/_tailscale-extract"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "tailscale download failed: $url"

  # The channel publishes <tarball>.sha256 as "<sha>  <name>".
  sha=""
  sums="$XDG_DATA_HOME/_tailscale.sha256"
  if curl -fsSL "$url.sha256" -o "$sums" 2>/dev/null; then
    sha="$(awk 'NR==1{print $1}' "$sums")"
    rm -f "$sums"
  fi
  verify_sha256 "$tmp" "$sha" "tailscale ($asset)"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$tmp" -C "$tmpdir"

  local dir
  dir="$(find "$tmpdir" -maxdepth 1 -type d -name 'tailscale_*' -print -quit)"
  [[ -n "$dir" && -f "$dir/tailscale" && -f "$dir/tailscaled" ]] \
    || die "tailscale archive is missing tailscale/tailscaled"
  rm -f "$XDG_BIN_HOME/tailscale" "$XDG_BIN_HOME/tailscaled"
  mv -f "$dir/tailscale" "$XDG_BIN_HOME/tailscale"
  mv -f "$dir/tailscaled" "$XDG_BIN_HOME/tailscaled"
  chmod +x "$XDG_BIN_HOME/tailscale" "$XDG_BIN_HOME/tailscaled"
  rm -rf "$tmpdir" "$tmp"

  # These are REAL binaries in $XDG_BIN_HOME, not symlinks into a payload dir:
  # two files, no indirection, and --clean tailscale removes exactly them while
  # preserving the tailnet state under $TAILSCALE_DATA_DIR.
  ok "tailscale installed: $XDG_BIN_HOME/tailscale ($("$XDG_BIN_HOME/tailscale" version 2>&1 | head -1))"
  ok "  userspace networking is required here (no /dev/net/tun on Replit):"
  ok "    tailscaled --tun=userspace-networking --state=$TAILSCALE_DATA_DIR/state/tailscaled.state --socket=$TAILSCALE_DATA_DIR/state/tailscaled.sock &"
  ok "    tailscale --socket=$TAILSCALE_DATA_DIR/state/tailscaled.sock up --hostname=<name>"
  ok "  (run tailscaled with --statedir too: without it ACME/Funnel certs fail — see references/exposing-ports.md)"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool tailscale -- "$XDG_BIN_HOME"
}

# sshx — collaborative web terminal. Its GitHub releases carry NO assets, so the
# versionless S3 tarball (what sshx.io/get pulls) is the only artifact; no
# checksum is published. The archive holds a single `sshx` binary.
sshx_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "sshx-x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64|arm64)  echo "sshx-aarch64-unknown-linux-musl.tar.gz" ;;
    *)              die "sshx: unsupported arch $(uname -m)" ;;
  esac
}

install_sshx() {
  step "sshx (collaborative web terminal)"
  need_cmd curl
  need_cmd tar
  mkdir -p "$XDG_BIN_HOME"

  local asset url tmp tmpdir bin
  asset="$(sshx_asset_name)"
  url="$SSHX_DOWNLOAD_BASE/$asset"
  tmp="$XDG_DATA_HOME/_sshx.tar.gz"
  tmpdir="$XDG_DATA_HOME/_sshx-extract"

  echo "  Downloading $asset"
  curl -fsSL "$url" -o "$tmp" || die "sshx download failed: $url"

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$tmp" -C "$tmpdir"
  # Layout-agnostic: the archive may or may not wrap the binary in a dir.
  bin="$(find "$tmpdir" -type f -name sshx -print -quit)"
  [[ -n "$bin" ]] || die "sshx archive is missing the 'sshx' binary"
  rm -f "$XDG_BIN_HOME/sshx"
  mv -f "$bin" "$XDG_BIN_HOME/sshx"
  chmod +x "$XDG_BIN_HOME/sshx"
  rm -rf "$tmpdir" "$tmp"
  ok "sshx installed: $XDG_BIN_HOME/sshx ($("$XDG_BIN_HOME/sshx" --version 2>&1 | head -1))"
  ok "  share a shell: sshx   (prints a web URL; nothing listens locally)"
  record_tool_path_dirs "$XDG_BIN_HOME"
  wire_tool sshx -- "$XDG_BIN_HOME"
}
