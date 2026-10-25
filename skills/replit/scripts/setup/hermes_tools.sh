# shellcheck shell=bash
# Hermes env rc block (write/strip). Sourced by setup.sh.
# Hermes' own environment for user shells (appended by write_bashrc AFTER the
# managed block, only when a Hermes install is present) ───────────────────────
# The block owns exactly two things: HERMES_HOME / HERMES_MANAGED_DIR (where a
# `hermes` call in this shell finds its state) and the launcher dir
# ($HERMES_HOME/hermes-agent/.hermes/bin) so a bare `hermes` reaches the stable
# entrypoint that resolves its own environment.
#
# $HERMES_HOME/tools/* is deliberately NOT put on PATH. Those binaries are the
# agent's managed install (node, npm, python, uv, gh, ffmpeg, ripgrep, ...) —
# versioned dirs that `hermes update` replaces and an uninstall/`--clean hermes`
# deletes. On a user PATH the install target follows the binary: `npm i -g
# <pkg>` writes into Hermes' npm prefix and dies with Hermes, `pip` follows
# Hermes' interpreter, gh extensions land under $HERMES_HOME, and PATH order
# silently decides which node/python a user's script ran under. User shell and
# agent keep separate toolchains: the shell gets the platform one (.replit's
# nodejs-24 / python3.13 modules plus anything setup.sh installs into
# $XDG_BIN_HOME), while Hermes launches its own binaries from its own PATH and
# never reads this block.
#
# .replit is deliberately NOT touched: nodejs-24 / python3.13 keep installing
# as the nix-profile fallback.
#
# OUTSIDE the # >>> toolchain >>> markers on purpose: the managed block is
# stripped+rewritten on every setup.sh run and rescue_tool_lines/
# strip_tool_wiring only understand the guarded-line grammar — a file with its
# own explanatory comments would be eaten or unrescued. With its own marker the
# block survives every other rewrite; --clean hermes drops it explicitly.
# The block is REGENERATED in place (strip + append) rather than skipped when
# present: write_bashrc always appends the managed block at the END, so a
# stale guard would leave this block ABOVE the toolchain block and silently
# flip PATH precedence (later prepends win). Regenerating keeps it last and
# lets manual marker edits survive exactly one run — documented behavior: edit
# setup.sh, don't hand-edit between the markers.
write_hermes_tools_block() {
  local TOOLS_DIR="${HERMES_HOME:-${REPL_HOME:-$HOME}/.hermes}/tools"
  local HERMES_ROOT="${HERMES_HOME:-${REPL_HOME:-$HOME}/.hermes}"
  local MARK='# >>> hermes-tools >>>'
  [[ -d "$TOOLS_DIR" ]] || { skip "no $TOOLS_DIR — PM tools not staged, PATH hook not written"; return 0; }
  mkdir -p "$(dirname "$BASHRC")"; [[ -f "$BASHRC" ]] || : > "$BASHRC"
  local rc_tmp; rc_tmp="$(mktemp)"
  # copy of current rc minus any existing marker block (awk swallows the
  # block INCLUDING both marker lines; outer file otherwise untouched)
  awk '/^# >>> hermes-tools >>>/{s=1} s{ if(/^# <<< hermes-tools <<</) s=0; next } {print}' \
    "$BASHRC" > "$rc_tmp"
  cat >> "$rc_tmp" <<RC

$MARK
# Hermes env — appended by setup.sh (--hermes). HERMES_HOME / HERMES_MANAGED_DIR
# live here (not the generic toolchain block) because they are only meaningful
# alongside a Hermes install, and this block is written only when
# $HERMES_HOME/tools exists. HERMES_MANAGED_DIR relocates the managed-scope
# directory off its /etc/hermes default: on Replit /etc is a read-only mount
# and cannot be created without root, so pin it under $HERMES_HOME/managed.
# Exporting both here means every interactive shell and the gateway/workflow
# shells inherit them — no manual export needed.
export HERMES_HOME="$HERMES_ROOT"
export HERMES_MANAGED_DIR="$HERMES_ROOT/managed"
# The launcher dir, and nothing else: hermes / hermes-acp reset PYTHONHOME
# and PYTHONPATH and resolve the environment to run themselves, so this stays
# correct across hermes update, a version swap and a Recreate.
[[ -d "$HERMES_ROOT/hermes-agent/.hermes/bin" ]] && export PATH="$HERMES_ROOT/hermes-agent/.hermes/bin:\$PATH"
# $HERMES_ROOT/tools/* is deliberately NOT on PATH — do not add it back.
# Those are the agent's managed binaries (node, npm, python, uv, gh, ffmpeg,
# ripgrep, ...): versioned dirs that hermes update replaces and an
# uninstall / --clean hermes deletes. A global install follows the binary, so
# on the user PATH a global npm install would write into Hermes' npm prefix and
# be removed with Hermes, pip would follow Hermes' interpreter, and PATH order
# would silently pick which node/python a user's script ran under. The user
# shell keeps the platform toolchain instead (.replit's nodejs-24 /
# python3.13 modules, plus anything setup.sh installs into $XDG_BIN_HOME);
# Hermes runs its own binaries from its own PATH and ignores this block.
# NOTE: $HERMES_ROOT/installs/*/environments/*/venv/bin and hermes-agent/venv/bin
# are deliberately NOT put on PATH. Those venvs belong to an isolated session run
# (installs/<hash>/environments/<hash>/) and are not stable across sessions or
# updates — a public shell that picked one up would call a binary from a session
# that may not exist and crash. The .hermes/bin launcher above is the stable
# entrypoint; it resolves the correct environment itself.
# <<< hermes-tools <<<
RC
  # Squeeze blank runs to one: every rewriter above (write_bashrc's strip +
  # append, this function's strip + append) leaves a separator at its seam,
  # and un-squeezed those blanks accumulate two per run forever. Collapsing
  # runs makes the rc a fixed point: re-running --fix changes nothing.
  local rc_sq; rc_sq="$(mktemp)"
  awk 'BEGIN{b=0} /^$/{b++; next} {if(b>0) print ""; b=0; print} END{if(b>0) print ""}' "$rc_tmp" > "$rc_sq"
  if ! bash -n "$rc_sq" 2>/dev/null; then
    rm -f "$rc_tmp" "$rc_sq"
    warn "hermes-tools block failed 'bash -n' — $BASHRC left untouched"
    return 0
  fi
  cat "$rc_sq" > "$BASHRC"
  rm -f "$rc_tmp" "$rc_sq"
  ok "hermes-tools rc block written to $BASHRC (HERMES_HOME + launcher PATH)"
}

# Drop the hermes-tools rc block. Marker-balanced strip (same awk idiom as
# strip_rc_block, own markers); safe when the block is absent.
strip_hermes_tools() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  grep -qF '# >>> hermes-tools >>>' "$f" || return 0
  local tmp; tmp="$(mktemp)"
  awk '/^# >>> hermes-tools >>>/{s=1} s{ if(/^# <<< hermes-tools <<</) s=0; next } {print}' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  ok "hermes-tools rc block stripped from $f"
}
