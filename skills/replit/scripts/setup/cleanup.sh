# shellcheck shell=bash
# Per-tool cleanup (--clean). Sourced by setup.sh.
# Cleanup (removes installed toolchain artifacts) ─────────────────────────────
rm_bin() { local b; for b in "$@"; do rm -f "$XDG_BIN_HOME/$b"; done; }
rm_dir() { local d; for d in "$@"; do rm -rf "$d"; done; }

rm_data() {
  local tool="$1" dir="$2"
  rm -rf "$dir"
  rm_bin "$tool"
}

# True when the tool has something to remove — a binary in XDG_BIN_HOME or
# any of the extra paths given (payload dirs, npm-global copies, …). Used by
# every clean_* to skip rather than claim a removal that never happened.
# [[ -e || -L ]] so a dangling symlink (target already gone) still counts as
# present and gets cleaned up rather than left as a stale link.
_present() {
  local p
  for p in "$@"; do [[ -e "$p" || -L "$p" ]] && return 0; done
  return 1
}

# nothing_removed <label>: honest skip for an already-absent tool.
nothing_removed() { skip "$1 not installed — nothing to remove"; }

# ── User-data backup before destructive removal ──────────────────────────────
# Some payload dirs are NOT pure install artifacts — they hold the operator's
# data. `--clean` must not destroy that silently, so any tool that owns user
# data goes through back_up_tool FIRST. The archive lives OUTSIDE the dir being
# removed (a backup inside $HERMES_HOME would be deleted by the very rm it is
# protecting against).
#
# hermes_backup: use the tool's OWN CLI (`hermes backup`) to produce the
# archive, then COPY it to the destination OUTSIDE $HERMES_HOME. The CLI knows
# what to include/exclude (skills, sessions, memory-provider state) and takes
# SQLite-safe copies of state.db, producing an archive `hermes import` can
# restore. A manual zip is only a fallback for a box where the CLI is missing
# or fails — the guarantee that matters is: no deletion without a backup.
HERMES_BACKUP_EXCLUDES=(
  '*/cache/*' '*/installs/*' '*/hermes-agent/*' '*/tools/*' '*/logs/*'
  '*/telemetry/*' '*/audio_cache/*' '*/image_cache/*' '*/node_modules/*'
  '*/models_dev_cache.json' '*/provider_models_cache.json' '*.lock'
)

# Manual fallback archive (used only when the CLI is unavailable/failed).
_hermes_backup_zip_fallback() {
  local dest="$1"
  command -v zip >/dev/null 2>&1 || return 1
  rm -f "$dest"
  ( cd "$(dirname "$HERMES_HOME")" \
      && zip -q -r "$dest" "$(basename "$HERMES_HOME")" -x "${HERMES_BACKUP_EXCLUDES[@]}" )
  [[ -s "$dest" ]]
}

hermes_backup() {
  local dest_dir="$XDG_CONFIG_HOME/hermes"
  local dest="$dest_dir/hermes-backup.zip"
  [[ -d "$HERMES_HOME" ]] || return 0
  mkdir -p "$dest_dir"

  # 1. Preferred: the tool's own CLI, staged OUTSIDE $HERMES_HOME (scratch
  #    TMPDIR), then copied in — a backup written inside the dir being removed
  #    would be deleted by the very rm it protects against. `timeout` guards
  #    against the launcher booting a source-update cycle (never block a
  #    --clean on the network); HERMES_HOME is passed explicitly so the CLI
  #    archives THIS home.
  local staging_dir staging rc=1
  staging_dir="$(mktemp -d)"; staging="$staging_dir/hermes-backup.zip"
  if command -v hermes >/dev/null 2>&1; then
    if HERMES_HOME="$HERMES_HOME" timeout "${HERMES_BACKUP_TIMEOUT:-900}" \
         hermes backup -o "$staging" >/dev/null 2>&1 \
       && [[ -s "$staging" ]]; then
      rc=0
    fi
  fi

  # 2. Fallback: manual zip when the CLI is absent or produced no archive.
  if (( rc != 0 )); then
    warn "hermes backup CLI unavailable or produced no archive — falling back to a manual zip"
    _hermes_backup_zip_fallback "$staging" && rc=0
  fi

  if (( rc == 0 )) && cp -f "$staging" "$dest" && [[ -s "$dest" ]]; then
    rm -rf "$staging_dir"
    ok "Hermes user data backed up: $dest"
    _BACKUPS_TAKEN+=("hermes->$dest")
    return 0
  fi

  rm -rf "$staging_dir"
  warn "Hermes backup produced no archive — refusing to delete $HERMES_HOME"
  rm -f "$dest"
  return 1
}

# Dispatcher: back up <tool>'s user data before removal. Returns 0 when there
# is nothing to back up OR the backup succeeded; non-zero means the backup was
# attempted and FAILED, in which case the caller must NOT delete the payload.
back_up_tool() {
  case "$1" in
    hermes)  hermes_backup ;;
    ollama)  : ;;  # models are preserved in place by clean_ollama (too big to archive)
    camofox) : ;;  # ~/.camofox server state is preserved by clean_camofox
    hermes-chromium) : ;;  # the browser itself is Hermes-managed; clean_ drops only the closure
    *)       : ;;  # nothing user-owned (binary-only tools)
  esac
}

# Human-readable "what this tool owns" — used by the pre-flight summary.
clean_paths_for() {
  case "$1" in
    android)       echo "$JAVA_HOME $SDK (binaries: java/adb/sdkmanager/…)" ;;
    uv)            echo "uv/uvx binaries, $XDG_DATA_HOME/uv, uv cache" ;;
    node)          echo "$NODE_DIR + node/npm/npx symlinks" ;;
    opencode)      echo "$XDG_BIN_HOME/opencode, $OPENCODE_CONFIG_DIR" ;;
    ollama)        echo "$OLLAMA_INSTALL_DIR binaries (MODELS PRESERVED)" ;;
    claude)        echo "$XDG_BIN_HOME/claude" ;;
    hermes)        echo "$HERMES_HOME (backed up via hermes CLI first), hermes launchers" ;;
    ori)           echo "$XDG_BIN_HOME/ori" ;;
    cliproxy)      echo "cli-proxy-api binary (config + OAuth logins PRESERVED)" ;;
    camofox)       echo "npm package, $CAMOUFOX_INSTALL_DIR engine, closure (server state PRESERVED)" ;;
    rclone)        echo "$XDG_BIN_HOME/rclone" ;;
    qbt)           echo "$XDG_BIN_HOME/qbittorrent-nox" ;;
    aria2)         echo "$XDG_BIN_HOME/aria2c" ;;
    ffmpeg)        echo "$XDG_BIN_HOME/ffmpeg ffprobe ffplay" ;;
    *)             echo "$1" ;;
  esac
}

# Pre-flight: print exactly what is about to be removed (and what is kept)
# BEFORE anything is deleted. Purely informational — the y/N confirm in
# confirm_clean is the actual gate.
clean_preflight() {
  local -a targets=("$@")
  ((${#targets[@]})) || return 0
  echo ""
  echo "${COL_BOLD}The following will be REMOVED:${COL_RESET}"
  local t
  for t in "${targets[@]}"; do
    printf '  %s- %-12s%s %s\n' "$COL_RED" "$t" "$COL_RESET" "$(clean_paths_for "$t")"
  done
  case " ${targets[*]} " in
    *" hermes "*) echo "  ${COL_YELLOW}• hermes: backed up via 'hermes backup' CLI -> $XDG_CONFIG_HOME/hermes/hermes-backup.zip first${COL_RESET}" ;;
  esac
}

# True when the given package is installed as a GLOBAL npm package (opencode-ai,
# @anthropic-ai/claude-code). Those installs don't create an XDG_BIN_HOME binary,
# so _present alone would skip them and leak the global package on clean.
_npm_global_installed() {
  command -v npm &>/dev/null || return 1
  npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 "$1" &>/dev/null 2>&1
}

clean_android() {
  if ! _present "$JAVA_HOME" "$SDK" "$XDG_BIN_HOME/java" "$XDG_BIN_HOME/adb"; then
    nothing_removed "Android toolchain"; return 0
  fi
  step "Removing Android toolchain (Java $JAVA_MAJOR + SDK)"
  rm_data android "$JAVA_HOME"
  rm -rf "$SDK"
  rm_bin java javac jar jshell javap sdkmanager avdmanager adb
  ok "Android toolchain removed"
}

clean_uv() {
  if ! _present "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx" "$XDG_DATA_HOME/uv" \
                "$WORKSPACE/.local/bin/uv" "$WORKSPACE/.cargo/bin/uv" "$WORKSPACE/.cache/uv"; then
    nothing_removed "uv"; return 0
  fi
  step "Removing uv"
  rm -rf "$XDG_BIN_HOME/uv" "$XDG_BIN_HOME/uvx" "$XDG_DATA_HOME/uv" \
         "$WORKSPACE/.local/bin/uv" "$WORKSPACE/.cargo/bin/uv" "$WORKSPACE/.cache/uv"
  ok "uv removed"
}

clean_node() {
  if ! _present "$NODE_DIR" "$XDG_BIN_HOME/node"; then
    nothing_removed "Node.js"; return 0
  fi
  step "Removing Node.js"
  rm_data node "$NODE_DIR"
  rm_bin node npm npx
  ok "Node.js removed"
}

clean_opencode() {
  if ! _present "$XDG_BIN_HOME/opencode" "$OPENCODE_CONFIG_DIR" \
       && ! _npm_global_installed "opencode-ai"; then
    nothing_removed "OpenCode"; return 0
  fi
  step "Removing OpenCode"
  # Binary lives directly in XDG_BIN_HOME (single-file install); the npm
  # package (opencode-ai) is a GLOBAL install, so it must be removed with
  # `npm uninstall -g` — a local `npm uninstall` leaves the global bin intact.
  rm -f "$XDG_BIN_HOME/opencode"
  if command -v npm &>/dev/null \
     && npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 opencode-ai &>/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g opencode-ai \
      || warn "npm uninstall -g opencode-ai failed — remove it manually"
  fi
  rm -rf "$OPENCODE_CONFIG_DIR"
  ok "OpenCode removed"
}

clean_ollama() {
  if ! _present "$OLLAMA_INSTALL_DIR" "$XDG_BIN_HOME/ollama"; then
    nothing_removed "Ollama"; return 0
  fi
  step "Removing Ollama"
  rm_data ollama "$OLLAMA_INSTALL_DIR"
  rm_bin ollama
  ok "Ollama removed"
}

clean_claude() {
  if ! _present "$XDG_BIN_HOME/claude" \
       && ! _npm_global_installed "@anthropic-ai/claude-code"; then
    nothing_removed "Claude Code"; return 0
  fi
  step "Removing Claude Code"
  # Binary lives directly in XDG_BIN_HOME (single-file smart install); if it
  # was installed as the global npm package @anthropic-ai/claude-code instead,
  # that copy survives an rm — so also `npm uninstall -g` it.
  rm -f "$XDG_BIN_HOME/claude"
  if command -v npm &>/dev/null \
     && npm_config_prefix="$NPM_GLOBAL_PREFIX" npm ls -g --depth=0 @anthropic-ai/claude-code &>/dev/null 2>&1; then
    npm_config_prefix="$NPM_GLOBAL_PREFIX" npm uninstall -g @anthropic-ai/claude-code \
      || warn "npm uninstall -g @anthropic-ai/claude-code failed — remove it manually"
  fi
  ok "Claude Code removed"
}

clean_hermes() {
  if ! _present "$HERMES_HOME" "$XDG_BIN_HOME/hermes"; then
    nothing_removed "Hermes Agent"; return 0
  fi
  step "Removing Hermes Agent"
  # User data (config.yaml, .env, auth.json, sessions, memories, cron, skills,
  # state.db) lives in $HERMES_HOME — back it up BEFORE the rm. If the backup
  # cannot be produced, do NOT delete: a silent loss of the whole agent config
  # is exactly the failure this guards against.
  if ! back_up_tool hermes; then
    warn "Hermes NOT removed — backup failed; $HERMES_HOME left intact"
    _CLEAN_SKIPPED+=("hermes")
    return 0
  fi
  rm_data hermes "$HERMES_HOME"
  rm_bin hermes hermes-agent hermes-acp
  ok "Hermes Agent removed"
}

clean_ori() {
  if ! _present "$XDG_BIN_HOME/ori"; then
    nothing_removed "ORI"; return 0
  fi
  step "Removing ORI"
  # Binary lives directly in XDG_BIN_HOME (single-file smart install).
  rm -f "$XDG_BIN_HOME/ori"
  ok "ORI removed"
}

clean_rclone() {
  if ! _present "$XDG_BIN_HOME/rclone"; then
    nothing_removed "rclone"; return 0
  fi
  step "Removing rclone"
  rm -f "$XDG_BIN_HOME/rclone"
  ok "rclone removed"
}

clean_qbt() {
  if ! _present "$XDG_BIN_HOME/qbittorrent-nox"; then
    nothing_removed "qBittorrent-nox"; return 0
  fi
  step "Removing qBittorrent-nox"
  rm -f "$XDG_BIN_HOME/qbittorrent-nox"
  ok "qBittorrent-nox removed"
}

clean_aria2() {
  if ! _present "$XDG_BIN_HOME/aria2c"; then
    nothing_removed "aria2c"; return 0
  fi
  step "Removing aria2c"
  rm -f "$XDG_BIN_HOME/aria2c"
  ok "aria2c removed"
}

clean_ffmpeg() {
  if ! _present "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"; then
    nothing_removed "FFmpeg"; return 0
  fi
  step "Removing FFmpeg"
  rm -f "$XDG_BIN_HOME/ffmpeg" "$XDG_BIN_HOME/ffprobe" "$XDG_BIN_HOME/ffplay"
  ok "FFmpeg removed"
}

# CLIProxyAPI — removes the symlink + binary only. $CLIPROXY_HOME (config.yaml
# with keys/OAuth logins, server.log, ~/.cli-proxy-api auth dir) is the user's
# data and is deliberately PRESERVED; delete the dir by hand for a full wipe.
clean_cliproxy() {
  if ! _present "$XDG_BIN_HOME/cli-proxy-api" "$CLIPROXY_HOME/cli-proxy-api"; then
    nothing_removed "CLIProxyAPI"; return 0
  fi
  step "Removing CLIProxyAPI (config + OAuth logins kept in $CLIPROXY_HOME)"
  rm -f "$XDG_BIN_HOME/cli-proxy-api" "$CLIPROXY_HOME/cli-proxy-api"
  ok "CLIProxyAPI removed (preserved: $CLIPROXY_HOME)"
}

# Strip the '# >>> toolchain >>>' … '# <<< toolchain <<<' managed block from a
# file, writing the result back THROUGH the path (cat >) so a symlink target
# is preserved — sed -i would replace the symlink with a plain file.
strip_rc_block() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk '/^# >>> toolchain >>>/{s=1} s{ if(/^# <<< toolchain <<</) s=0; next } {print}' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# Remove ONLY the lines owned by <tool> from the managed shell block (rc;
# the .replit twin is strip_userenv_keys, below).
# The block is stripped line-by-line; lines whose var/dir maps to <tool> via
# _WIRE_OWNER are dropped; everything else (including unregistered lines like
# the XDG exports from the replit block) is kept. The block markers themselves
# are preserved if ANY lines remain; if the block becomes empty, the whole
# block (markers + contents) is removed.
strip_tool_wiring() {
  local tool="$1" file="$2"
  [[ -f "$file" ]] || return 0

  local in_block=0
  local -a out=()
  local line var dir owner

  while IFS= read -r line; do
    case "$line" in
      '# >>> toolchain >>>')
        in_block=1
        out+=("$line")
        continue
        ;;
      '# <<< toolchain <<<')
        if (( in_block )); then
          # If the block is only markers (no tool lines left) remove both.
          local last_idx=$(( ${#out[@]} - 1 ))
          if [[ $last_idx -ge 0 && "${out[last_idx]}" == '# >>> toolchain >>>' ]]; then
            unset 'out[last_idx]'
          else
            out+=("$line")
          fi
        else
          out+=("$line")
        fi
        in_block=0
        continue
        ;;
    esac

    if (( in_block )); then
      owner=""
      if [[ "$line" == 'case ":$PATH:" in '* ]]; then
        local re='\*"([^"]*)"\*'
        if [[ "$line" =~ $re ]]; then
          dir="${BASH_REMATCH[1]#:}"
          dir="${dir%:}"
          owner="$(path_dir_owner "$dir")"
        fi
      elif [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]] \
         || [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
        var="${BASH_REMATCH[1]}"
        owner="$(env_var_owner "$var")"
      fi

      if owned_only_by "$owner" "$tool"; then
        # Drop the line — it's owned by the tool being cleaned.
        continue
      fi
      # Keep lines owned by other tools and unregistered lines (platform exports, etc.)
      out+=("$line")
    else
      out+=("$line")
    fi
  done < "$file"

  # Write back through the path (preserves symlinks)
  local tmp="$(mktemp)"
  printf '%s\n' ${out[@]+"${out[@]}"} > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Prompts for confirmation before an irreversible cleanup. Skips when
# `--yes` was given or stdin isn't a TTY (non-interactive default is proceed).
confirm_clean() {
  $YES && return 0
  [[ -t 0 ]] || return 0
  local ans
  printf '%sProceed with cleanup of %s%s? [y/N] ' \
    "$COL_YELLOW" "${CLEAN_TARGET:-all}" "$COL_RESET"
  IFS= read -r ans || true
  # Declining (or Ctrl-D) is a voluntary no-op, NOT a failure — never a red
  # ERROR and never exit 1. Mirrors the menu-quit idiom in interactive_menu.
  if [[ "$ans" != y && "$ans" != Y && "$ans" != yes && "$ans" != YES ]]; then
    echo -e "\n${COL_YELLOW}Cleanup cancelled.${COL_RESET}"
    exit 130
  fi
}

clean() {
  seed_tool_wiring
  mkdir -p "$XDG_BIN_HOME"
  unset _MENU_ITEMS _MENU_CURSOR _MENU_TOGGLE 2>/dev/null || true
  local summary hint

  # Pre-flight: show what is about to go (and which tools keep user data)
  # BEFORE any deletion. Label normalization: android-tools -> android,
  # oc -> opencode, matching the wire labels used below.
  local _pf=""
  case "$CLEAN_TARGET" in
    ""|all) _pf="" ;;
    android-tools|uv|node|oc|opencode|ollama|claude|hermes|ori|cliproxy|camofox|rclone|qbt|aria2|ffmpeg)
      _pf="$CLEAN_TARGET"; [[ "$_pf" == android-tools ]] && _pf=android; [[ "$_pf" == oc ]] && _pf=opencode ;;
  esac
  if [[ -n "$_pf" ]]; then
    clean_preflight "$_pf"
  elif [[ "$CLEAN_TARGET" == all || -z "$CLEAN_TARGET" ]]; then
    (( ${#CLEAN_TOOLS[@]} )) && clean_preflight "${CLEAN_TOOLS[@]}" || clean_preflight all
  fi

  # Dispatch order (explicit target / full wipe / misc state → wiring
  # strip; menu-selected tools → per-tool only). No set -e trap under us: the
  # function returns 0 only after real cleanup; an empty menu selection
  # (nothing ticked) short-circuits below as a graceful no-op — the menu can
  # never trigger an irreversible full wipe.
  summary="$CLEAN_TARGET"
  hint="bash setup.sh --all"
  case "$CLEAN_TARGET" in
    android-tools|uv|node|oc|opencode|ollama|claude|hermes|ori|cliproxy|camofox|rclone|qbt|aria2|ffmpeg)
      hint="bash setup.sh --$CLEAN_TARGET"
      ;;
  esac
  case "$CLEAN_TARGET" in
    all)
      step "Cleaning entire toolchain"
      # Strip env wiring FIRST: strip_userenv_keys needs a tomlkit-capable
      # interpreter, and clean_uv deletes uv — the fallback tomlkit source
      # when python3/.venv lack it — as a side effect of removing binaries.
      # 'all' is the ONLY path that strips env wiring (the rc / .replit
      # managed blocks) — per-target clean removes binaries + payload only.
      if [[ -f "$BASHRC" ]]; then
        strip_rc_block "$BASHRC"
        ok "Stripped managed block from $BASHRC"
        strip_hermes_tools "$BASHRC"
      fi
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      # Only replit mode ever wrote a userenv block — don't touch .replit
      # otherwise (default mode is .bashrc-only by design). strip_userenv_keys
      # checks writability and removes every managed key (an emptied
      # [userenv.shared] table is dropped by the tomlkit writer).
      if [[ "$REPLIT_MODE" == true && -f "$replit_file" ]]; then
        strip_userenv_keys all "$replit_file"
      fi
      clean_android
      clean_uv
      clean_node
      clean_opencode
      clean_ollama
      clean_claude
      clean_hermes
      clean_ori
      clean_rclone
      clean_qbt
      clean_aria2
      clean_ffmpeg
      clean_cliproxy
      clean_camofox
      ok "Full toolchain cleanup complete"
      ;;
    android-tools|uv|node|oc|opencode|ollama|claude|hermes|ori|cliproxy|camofox|rclone|qbt|aria2|ffmpeg)
      # Drop this tool's wiring from the managed blocks FIRST (strip_userenv_keys
      # needs a tomlkit-capable interpreter; clean_uv deletes uv, the fallback
      # source), then remove the binaries + payload. Labels here differ from
      # wire_tool ownership labels: android-tools -> android, oc -> opencode.
      local wire_label="$CLEAN_TARGET"
      case "$wire_label" in
        android-tools) wire_label=android ;;
        oc) wire_label=opencode ;;
      esac
      [[ -f "$BASHRC" ]] && strip_tool_wiring "$wire_label" "$BASHRC"
      # The hermes-tools rc block lives OUTSIDE the managed block (own
      # markers), so strip_tool_wiring can't see it — drop it explicitly.
      [[ "$wire_label" == hermes ]] && strip_hermes_tools "$BASHRC"
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && strip_userenv_keys "$wire_label" "$replit_file"
      case "$CLEAN_TARGET" in
        android-tools) clean_android ;;
        uv)            clean_uv ;;
        node)          clean_node ;;
        oc|opencode)   clean_opencode ;;
        ollama)        clean_ollama ;;
        claude)        clean_claude ;;
        hermes)        clean_hermes ;;
        ori)           clean_ori ;;
        cliproxy)      clean_cliproxy ;;
        camofox)       clean_camofox ;;
        hermes-chromium) clean_hermes_chromium ;;
        rclone)        clean_rclone ;;
        qbt)           clean_qbt ;;
        aria2)         clean_aria2 ;;
        ffmpeg)        clean_ffmpeg ;;
      esac
      ;;
    "")
      # Reached from the clean MENU: remove exactly the tools TICKED
      # (binary + payload only, not env wiring). An empty selection is a
      # graceful no-op — nothing to remove.
      if [[ ${#CLEAN_TOOLS[@]} -eq 0 ]]; then
        skip "no tools selected in the cleanup menu — nothing removed"
        return 0
      fi
      summary="$(IFS=','; echo "${CLEAN_TOOLS[*]}")"
      hint="bash setup.sh"
      # Drop env wiring FIRST (strip_userenv_keys needs a tomlkit-capable
      # interpreter; clean_uv deletes uv, the fallback source), then remove
      # the ticked binaries + payload.
      [[ -f "$BASHRC" ]] && strip_tool_wiring "${CLEAN_TOOLS[*]}" "$BASHRC"
      [[ " ${CLEAN_TOOLS[*]} " == *" hermes "* ]] && strip_hermes_tools "$BASHRC" || true
      local replit_file="${REPL_HOME:-$WORKSPACE}/.replit"
      [[ "$REPLIT_MODE" == true && -f "$replit_file" ]] && strip_userenv_keys "${CLEAN_TOOLS[*]}" "$replit_file"
      local label
      for label in "${CLEAN_TOOLS[@]}"; do
        case "$label" in
          android)  clean_android ;;
          uv)       clean_uv ;;
          node)     clean_node ;;
          opencode) clean_opencode ;;
          ollama)   clean_ollama ;;
          claude)   clean_claude ;;
          hermes)   clean_hermes ;;
          ori)      clean_ori ;;
          cliproxy) clean_cliproxy ;;
          camofox)  clean_camofox ;;
          rclone)   clean_rclone ;;
          qbt)      clean_qbt ;;
          aria2)    clean_aria2 ;;
          ffmpeg)   clean_ffmpeg ;;
          *)        warn "Unknown clean target '$label' — skipped" ;;
        esac
      done
      ;;
    *)
      die "Unknown --clean target '$CLEAN_TARGET'. Valid: all, android-tools, uv, node, oc, opencode, ollama, claude, hermes, ori, cliproxy, camofox, rclone, qbt, aria2, ffmpeg"
      ;;
  esac
  cat <<CLEANMSG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Cleanup complete for: $summary

 Reinstall: $hint
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CLEANMSG
  if ((${#_BACKUPS_TAKEN[@]})); then
    echo ""
    for summary in "${_BACKUPS_TAKEN[@]}"; do
      ok "Backup kept: ${summary#*->}"
    done
  fi
  if ((${#_CLEAN_SKIPPED[@]})); then
    echo ""
    for summary in "${_CLEAN_SKIPPED[@]}"; do
      warn "Not removed (backup failed, payload intact): $summary"
    done
  fi
}
