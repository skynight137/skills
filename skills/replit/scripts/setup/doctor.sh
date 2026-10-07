# shellcheck shell=bash
# Read-only toolchain self-check (--doctor). Sourced by setup.sh.
# Doctor (no-install self-check) ──────────────────────────────────────────────
doctor() {
  step "Environment doctor"
  local fail=0 wfail=0
  local name cmd ver

  check_tool() {
    name="$1"; cmd="$2"
    # Optional 3rd arg: the version flag to probe with. Defaults to GNU
    # --version; FFmpeg only accepts the single-dash -version and exits 8 on
    # --version by design, which used to read as a broken install.
    local vflag="${3:---version}"
    if command -v "$cmd" &>/dev/null; then
      # Gate on the tool's OWN exit status: a pipe under pipefail reports the
      # pipeline (a loader-failed binary exits nonzero but the exit-141 of a
      # short 'head' is noise, and 'grep -q' masks the real code). Capture
      # raw output + rc, then filter. Loader failures (libatomic.so.1) used
      # to print as '✓ Node: error while loading shared libraries...'.
      local _raw _rc=0
      _raw="$("$cmd" "$vflag" 2>&1)" || _rc=$?
      _raw="$(printf '%s\n' "$_raw" | grep -v '^Picked up' | head -1)"
      if (( _rc == 0 )); then
        ok "$name: $_raw"
      else
        warn "$name: found but FAILED to run (exit $_rc): ${_raw:-no output} (check ldd / LD_LIBRARY_PATH wiring; 'bash setup.sh --fix' heals the pool+rc wiring — some tools like ffmpeg's static builds exit nonzero on --version by design)"
        fail=1
      fi
    else
      # NOT FOUND is an INSTALLATION state, not a wiring failure — --fix
      # cannot make a never-installed tool appear. Tracked separately from
      # the wiring checks below so the summary doesn't point at --fix for
      # tools the operator deliberately skipped.
      warn "$name: NOT FOUND ($cmd) — install it, or ignore if not used"
      fail=1
    fi
  }

  check_tool "Java" java
  check_tool "Android SDK (adb)" adb
  check_tool "uv" uv
  check_tool "Node" node
  check_tool "npm" npm
  check_tool "OpenCode" "$XDG_BIN_HOME/opencode"
  check_tool "Ollama" ollama
  check_tool "Claude" "$XDG_BIN_HOME/claude"
  check_tool "Hermes" "$HERMES_HOME/hermes-agent/venv/bin/hermes"
  check_tool "ORI" "$XDG_BIN_HOME/ori"
  check_tool "rclone" "$XDG_BIN_HOME/rclone"
  check_tool "qBittorrent-nox" "$XDG_BIN_HOME/qbittorrent-nox"
  check_tool "aria2c" "$XDG_BIN_HOME/aria2c"
  # FFmpeg probes with -version (single dash): --version prints the banner
  # and exits 8 by design, so the generic --version probe false-fails.
  check_tool "FFmpeg" "$XDG_BIN_HOME/ffmpeg" -version
  # Camofox: the npm binary on PATH + engine presence.
  if command -v camofox-browser >/dev/null 2>&1; then
    if [[ -f "$CAMOUFOX_INSTALL_DIR/version.json" ]]; then
      ok "Camofox: camofox-browser + engine ($(cat "$CAMOUFOX_INSTALL_DIR/version.json" 2>/dev/null))"
    else
      warn "camofox-browser present but engine missing in $CAMOUFOX_INSTALL_DIR — run: bash setup.sh --camofox"
      fail=1
    fi
  else
    warn "Camofox: NOT FOUND (camofox-browser) — install with --camofox, or ignore if not used"
    fail=1
  fi
  # CLIProxyAPI has NO --version flag: any unknown flag prints the version
  # banner and exits 2, so the generic check_tool would report a false
  # 'FAILED to run'. Probe the banner text instead of the exit code.
  if [[ -x "$XDG_BIN_HOME/cli-proxy-api" || -x "$CLIPROXY_HOME/cli-proxy-api" ]]; then
    local _cpa_bin="$XDG_BIN_HOME/cli-proxy-api"; [[ -x "$_cpa_bin" ]] || _cpa_bin="$CLIPROXY_HOME/cli-proxy-api"
    local _cpa_out; _cpa_out="$("$_cpa_bin" --help 2>&1 | grep -m1 '^CLIProxyAPI Version' || true)"
    if [[ -n "$_cpa_out" ]]; then ok "CLIProxyAPI: $_cpa_out"; else warn "CLIProxyAPI: present but did not print its version banner ($_cpa_bin)"; fail=1; fi
  else
    warn "CLIProxyAPI: NOT FOUND ($XDG_BIN_HOME/cli-proxy-api) — install with --cliproxy, or ignore if not used"
    fail=1
  fi

  case ":$_ENTRY_PATH:" in
    *":$XDG_BIN_HOME:"*) ok "XDG_BIN_HOME on PATH" ;;
    *) warn "XDG_BIN_HOME NOT on PATH (open a new shell)"; fail=1 ;;
  esac

  # --- wiring integrity (repairs: bash setup.sh --fix) ---
  if [[ "$REPLIT_MODE" == true ]]; then
    if [[ -f "${REPLIT_BASHRC_FILE:-}" ]]; then
      ok "workflow shim: $REPLIT_BASHRC_FILE"
    else
      warn "workflow shim missing ($REPLIT_BASHRC_FILE) — run: bash setup.sh --fix"
      wfail=1
    fi
  fi
  if [[ -f "$BASHRC" ]] && grep -q '# >>> toolchain >>>' "$BASHRC"; then
    ok "managed toolchain block in $BASHRC"
  else
    warn "no managed toolchain block in $BASHRC — run: bash setup.sh --fix"
    wfail=1
  fi
  # libatomic pool: the exact v4.5.x failure class ('✓ staged' while node
  # dies) is invisible to every other wiring check — verify the durable copy
  # itself. Skip on boxes where the system loader really resolves it (same
  # trust-but-verify as ensure_libatomic: cached path must exist + be x86-64).
  _doc_la="$(command -v ldconfig &>/dev/null && ldconfig -p 2>/dev/null | grep 'libatomic\.so\.1' | head -1)"; _doc_la="${_doc_la##*=> }"
  if [[ -n "$_doc_la" && -e "$_doc_la" ]] && file -L "$_doc_la" 2>/dev/null | grep -q 'ELF 64-bit LSB shared object, x86-64'; then
    ok "libatomic resolved by the system loader"
  elif [[ -e "$WORKSPACE/.local/lib/libatomic.so.1" ]] \
     && file -L "$WORKSPACE/.local/lib/libatomic.so.1" 2>/dev/null | grep -q 'ELF 64-bit LSB shared object, x86-64'; then
    ok "libatomic in pool ($WORKSPACE/.local/lib)"
  else
    warn "libatomic missing/not x86-64 in $WORKSPACE/.local/lib — node will fail to load; run: bash setup.sh --fix"
    wfail=1
  fi
  if [[ -d "$HERMES_HOME/tools" ]]; then
    if [[ -f "$BASHRC" ]] && grep -qF '# >>> hermes-tools >>>' "$BASHRC"; then
      ok "hermes-tools PATH block in $BASHRC"
    else
      warn "hermes-tools PATH block missing — run: bash setup.sh --fix"
      wfail=1
    fi
  fi
  # Camofox closure bus: env.sh + the launcher shim. A NON-interactive shell
  # (every .replit workflow task, the Run button, MCP/cron children) never
  # sources env.sh, so a bare `camofox-browser` there launches Firefox with no
  # GTK closure and dies with `libmozgtk.so: libgtk-3.so.0: cannot open shared
  # object file` — surfacing to camofox.py as an opaque 500 on cookie import
  # (six logged "rp" runs hit this). Gate on the wiring, not just the binary.
  if [[ -x "$XDG_BIN_HOME/camofox-browser" || -x "$NODE_DIR/bin/camofox-browser" ]]; then
    if [[ -s "$CAMOFOX_CLOSURE_FILE" ]]; then
      ok "camofox lib closure ($(tr ':' '\n' < "$CAMOFOX_CLOSURE_FILE" | grep -c .) lib dirs)"
    else
      warn "camofox lib closure missing/empty ($CAMOFOX_CLOSURE_FILE) — Firefox cannot start; run: bash setup.sh --camofox"
      wfail=1
    fi
    if [[ -s "$CAMOFOX_ENV_SNIPPET" ]]; then
      ok "camofox env snippet: $CAMOFOX_ENV_SNIPPET"
    else
      warn "camofox env snippet missing ($CAMOFOX_ENV_SNIPPET) — non-interactive shells get no GTK closure; run: bash setup.sh --fix"
      wfail=1
    fi
    if [[ -x "$XDG_BIN_HOME/launch-camofox-browser" ]]; then
      ok "camofox launcher shim: $XDG_BIN_HOME/launch-camofox-browser"
    else
      warn "camofox launcher shim missing ($XDG_BIN_HOME/launch-camofox-browser) — a bare 'camofox-browser' in a workflow shell dies without GTK; run: bash setup.sh --fix"
      wfail=1
    fi
    # State dir: $HOME is wiped on recreate, so a profile/cookie jar left at the
    # package default (~/.camofox) silently loses the login. Gate on the pins.
    if [[ "${CAMOFOX_PROFILE_DIR:-}" == "$WORKSPACE"/* || "${CAMOFOX_PROFILE_DIR:-}" == "$REPL_HOME"/* ]]; then
      ok "camofox state dir: ${CAMOFOX_PROFILE_DIR}"
    elif [[ -n "${CAMOFOX_PROFILE_DIR:-}" ]]; then
      warn "camofox state dir is OUTSIDE the persistent workspace (${CAMOFOX_PROFILE_DIR}) — profiles/cookies die on recreate; run: bash setup.sh --fix"
      wfail=1
    else
      warn "camofox state dir not pinned — the server defaults to \$HOME/.camofox (wiped on recreate); run: bash setup.sh --fix"
      wfail=1
    fi
    # Legacy state still sitting at the volatile $HOME default: only a problem when
    # the persistent target has NOT been populated yet (migration pending). Both
    # dirs holding data is the normal post-migration state — the copy is
    # deliberately non-destructive, so it must not read as a wiring failure.
    if [[ -n "${CAMOFOX_PROFILE_DIR:-}" && "$CAMOFOX_PROFILE_DIR" != "$HOME/.camofox/profiles" ]] \
       && [[ -z "$(find "$CAMOFOX_PROFILE_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]] \
       && [[ -d "$HOME/.camofox/profiles" ]] \
       && [[ -n "$(find "$HOME/.camofox/profiles" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      warn "camofox state not migrated: \$HOME/.camofox has cookies/profiles but ${CAMOFOX_PROFILE_DIR} is empty — run: bash setup.sh --camofox"
      wfail=1
    fi
  fi
  if [[ -f "$HOME/.profile" ]] && grep -qF 'toolchain-profile' "$HOME/.profile"; then
    ok "toolchain lines in ~/.profile"
  else
    warn "no toolchain lines in ~/.profile (login/ssh shells lack PATH) — run: bash setup.sh --fix"
    wfail=1
  fi
  if [[ -f "${HERMES_HOME}/config.yaml" ]] \
     && _parse_shell_init "${HERMES_HOME}/config.yaml" | grep -q '~/.profile' \
     && _parse_shell_init "${HERMES_HOME}/config.yaml" | grep -q 'REPLIT_BASHRC'; then
    ok "hermes config shell_init_files chained"
  else
    warn "hermes terminal shells don't source ~/.profile/\$REPLIT_BASHRC — run: bash setup.sh --fix"
    wfail=1
  fi

  # Summary: installation gaps (missing tools) and wiring gaps get separate
  # advice — --fix repairs wiring, only an install run brings back binaries.
  if (( fail == 0 && wfail == 0 )); then
    ok "All checks passed"
  else
    (( wfail )) && warn "Wiring incomplete — repair with: bash setup.sh --fix"
    (( fail )) && warn "Some tools missing — install them (or ignore if never installed)"
  fi
  (( wfail )) && return 2
  return $fail
}

# Show current toolchain state — read-only, no installs run.
list_state() {
  step "Toolchain state"
  local found
  echo "Mode: $( [[ "$REPLIT_MODE" == true ]] && echo 'replit (persistent)' || echo 'default (HOME)')"
  echo "Workspace: $WORKSPACE"
  echo "XDG_BIN_HOME: $XDG_BIN_HOME"
  echo "XDG_DATA_HOME: $XDG_DATA_HOME"
  echo "BASHRC target: $BASHRC"
  echo

  # Check managed block in BASHRC
  if [[ -f "$BASHRC" ]] && grep -q '# >>> toolchain >>>' "$BASHRC"; then
    echo "=== $BASHRC managed block ==="
    local in_block=0 line
    while IFS= read -r line; do
      case "$line" in
        '# >>> toolchain >>>') in_block=1; continue ;;
        '# <<< toolchain <<<') in_block=0; continue ;;
      esac
      (( in_block )) && echo "$line"
    done < "$BASHRC"
    echo
  else
    echo "=== $BASHRC: no managed block ==="
    echo
  fi

  # Check .replit [userenv.shared]
    local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
    if [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && grep -q '^\[userenv\.shared\]' "$replit_file"; then
      echo "=== $replit_file [userenv.shared] ==="
      awk '/^\[userenv\.shared\]/{s=1; print; next} /^\[/{s=0} s' "$replit_file"
      echo
    elif [[ "$REPLIT_MODE" == true ]]; then
      echo "=== $replit_file: no [userenv.shared] section ==="
      echo
    fi

  # Installed binaries
  echo "=== Installed binaries in $XDG_BIN_HOME ==="
  found=false
  local f
  for f in "$XDG_BIN_HOME"/*; do
    [[ -e "$f" && -x "$f" ]] || continue
    found=true
    local bin_name="$(basename "$f")"
    local owner="$(path_dir_owner "$XDG_BIN_HOME")"
    if [[ -n "$owner" ]]; then
      echo "  $bin_name (owned by: $owner)"
    else
      echo "  $bin_name"
    fi
  done
  $found || echo "  (none)"
  echo

  # Tool env vars registered this run (if any)
  echo "=== Tool env vars (current run registrations) ==="
  local var
  if [[ ${#_TOOL_ENV_VARS[@]} -eq 0 ]]; then
    echo "  (none registered this run)"
  else
    for var in "${_TOOL_ENV_VARS[@]}"; do
      local owner="$(env_var_owner "$var")"
      if [[ -n "$owner" ]]; then
        echo "  $var (owned by: $owner)"
      else
        echo "  $var"
      fi
    done
  fi
  echo

  # PATH dirs registered this run
  echo "=== PATH dirs (current run registrations) ==="
  local dir
  if [[ ${#_TOOL_PATH_DIRS[@]} -eq 0 ]]; then
    echo "  (none registered this run)"
  else
    for dir in "${_TOOL_PATH_DIRS[@]}"; do
      local owner="$(path_dir_owner "$dir")"
      if [[ -n "$owner" ]]; then
        echo "  $dir (owned by: $owner)"
      else
        echo "  $dir"
      fi
    done
  fi
}
