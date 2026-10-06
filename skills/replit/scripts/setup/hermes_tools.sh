# shellcheck shell=bash
# Hermes PM tools PATH block (write/strip). Sourced by setup.sh.
# Hermes tool dirs on the user PATH (appended by write_bashrc AFTER the
# managed block, only when hermes was installed this run) ─────────────────────
# Hermes stages its own tool binaries under $HERMES_HOME/tools/<name-ver>-
# linux-x64[/bin] and injects those exact dirs into the agent process PATH.
# Interactive shells saw a DIFFERENT node (Replit's nix nodejs-24 module)
# than the one Hermes runs, which made `npm i -g` and version checks
# confusing. This hook mirrors the agent's PATH set into the user rc so
# shells and Hermes share one toolset.
#
# .replit is deliberately NOT touched: nodejs-24 / python3.13 keep installing
# (the nix profile + pnpm/bun/yarn stay available as fallback). The block is
# appended AFTER the managed toolchain block so its PREPENDS win PATH order
# over both XDG_BIN_HOME (managed block prepends first) and the nix dirs.
#
# OUTSIDE the # >>> toolchain >>> markers on purpose: the managed block is
# stripped+rewritten on every setup.sh run and rescue_tool_lines/
# strip_tool_wiring only understand the guarded-line grammar — a lazy-glob
# block inside it would be eaten or unrescued. With its own marker the block
# survives every other rewrite; --clean hermes drops it explicitly.
# The block is REGENERATED in place (strip + append) rather than skipped when
# present: write_bashrc always appends the managed block at the END, so a
# stale guard would leave this block ABOVE the toolchain block and silently
# flip PATH precedence (later prepends win). Regenerating keeps it last and
# lets manual marker edits (e.g. dropping a tool dir from the glob list)
# survive exactly one run — documented behavior: edit setup.sh, don't
# hand-edit between the markers.
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
# Hermes tool dirs — appended by setup.sh (--hermes). Mirrors the
# agent process PATH into interactive shells: same node/npm/gh/ffmpeg/rg/
# uv/tirith/python 3.14 + the hermes launcher, so user and Hermes run ONE
# toolset. .replit stays as-is (nodejs-24 / python3.13 modules remain
# installed as the nix-profile fallback); these dirs are PREPENDED after the
# toolchain block so they win PATH order.
# Globbing is LAZY: every dir is re-resolved (newest version via sort -V) on
# each shell start, so 'hermes update' swapping versions needs no rc rewrite
# and a stale pinned path can never break an existing PATH.
# Prepend order reproduces the agent's own PATH (agent-browser ... node ...
# venv, .hermes/bin first): visit in reverse, prepend each. Duplication is
# bounded (once per shell start). Remove hermes: 'setup.sh --clean hermes'
# or delete this block (between the markers).
for sub in \\
    'agent-browser-*/bin' 'bws-*' 'cua-driver-*' 'ffmpeg-*/bin' 'gh-*/bin' \\
    'node-*/bin' 'npm-*/bin' 'python-*/bin' 'ripgrep-*' 'tirith-*' 'uv-*'; do
  d="\$(ls -d "$TOOLS_DIR"/\$sub 2>/dev/null | sort -V | tail -1)"
  [[ -n "\$d" && -d "\$d" ]] || continue
  export PATH="\$d:\$PATH"
done
[[ -d "$HERMES_ROOT/hermes-agent/.hermes/bin" ]] && export PATH="$HERMES_ROOT/hermes-agent/.hermes/bin:\$PATH"
hvenv="\$(ls -d "$HERMES_ROOT"/hermes-agent/venv/bin "$HERMES_ROOT"/installs/*/environments/*/venv/bin 2>/dev/null | head -1)"
[[ -n "\$hvenv" ]] && export PATH="\$hvenv:\$PATH"
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
  ok "hermes-tools PATH block appended to $BASHRC"
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
  ok "hermes-tools PATH block stripped from $f"
}
