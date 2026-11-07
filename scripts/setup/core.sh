# shellcheck shell=bash
# core.sh — shared library for BOTH setup entry points (muse + replit).
# Sourced, never executed. Stage S1 of the shared-setup refactor
# (one setup.sh --machine muse|repl): the primitives both setups used
# to carry as private copies live here exactly once. Machine-specific
# flows stay in the profiles; this file holds only what is identical.
#
# Contents: the house logging palette + helpers, need_cmd, the
# SHA256 verifier, and the tailscale channel asset naming. The repl
# setup adopts this file in S1; the muse setup adopts it in S2 when
# its profile is built on the shared modules.

# Logging ─────────────────────────────────────────────────────────────
# House style: ANSI-colored by severity, always on; the message text
# stays plain inside the color span so grep keeps working.
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

# Verify a downloaded file's SHA256 against the expected hex digest.
# verify_sha256 <file> <expected-hex-checksum> <label>
# The expected value is the FIRST FIELD of upstream's .sha256 file —
# upstream formats vary ("<sha>  <name>" vs a bare hash), and the
# caller extracts the field; this function only compares.
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

# Tailscale ───────────────────────────────────────────────────────────
# Channel asset name for a version from the pkgs.tailscale.com index.
tailscale_asset_name() {  # $1 = version from the channel index
  case "$(uname -m)" in
    x86_64|amd64)   echo "tailscale_${1}_amd64.tgz" ;;
    aarch64|arm64)  echo "tailscale_${1}_arm64.tgz" ;;
    *)              die "tailscale: unsupported arch $(uname -m)" ;;
  esac
}
