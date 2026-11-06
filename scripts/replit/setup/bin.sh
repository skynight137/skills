# shellcheck shell=bash
# Binary symlinking + parallel-job helpers. Sourced by setup.sh.
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
