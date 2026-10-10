# shellcheck shell=bash
# Shell rc writers, workflow shim, .replit userenv manager. Sourced by setup.sh.
usage() {
  cat <<USAGE
Usage: bash setup.sh [options]

Provisions the local development toolchain into XDG_BIN_HOME (binaries,
XDG_DATA_HOME payload). No 'source env.sh' needed either way.

Mode is AUTO-DETECTED from the environment (there is no flag): when \$REPL_HOME
is set to a real directory we are on Replit and install the persistent layout;
otherwise the \$HOME layout is used.
  replit  (auto): XDG dirs under \$REPL_HOME; shell env in a custom
shell custom rc at $REPL_HOME/.config/bashrc (auto-sourced by the Replit bootstrap; no .replit pin)
                  (applies to every repl process)
  default (auto): XDG dirs under \$HOME; minimal PATH block appended to
                  ~/.bashrc; no .replit, no Replit-specific wiring

Options:
  -a,  --all            Install everything (no menu)
  -at, --android-tools  Install Android toolchain (Java $JAVA_MAJOR + SDK)
  --uv                  Install uv (Python package manager)
  --node                Install Node.js $NODE_MAJOR (managed tarball)
  -oc, --opencode		    Install OpenCode (direct GitHub release binary into XDG_BIN_HOME)
  -ol, --ollama         Install Ollama (LLM runtime) into XDG_DATA_HOME/ollama
  -cl, --claude         Install Claude Code coding tool (direct SHA256-verified binary into XDG_BIN_HOME)
  -ha, --hermes         Install Hermes Agent assistant (curl -fsSL \$HERMES_INSTALL_URL, into \$HERMES_HOME)
                        Also mirrors \$HERMES_HOME/tools onto the shell PATH
                        (hermes-tools rc block) so user shells run the same
                        node/python/gh/... as the Hermes agent
  -ori, --openrouterai  Install ORI coding tool (direct SHA256-verified binary into XDG_BIN_HOME)
  -cp, --cliproxy       Install CLIProxyAPI (CLIProxyAPI_<ver>_linux_<arch> release
                        tarball, SHA256-verified against checksums.txt) into
                        $CLIPROXY_HOME + 'cli-proxy-api' symlink on PATH.
                        Bridges CLI OAuth subscriptions (Codex/Claude/Antigravity/
                        Gemini CLI/Kimi/xAI) into OpenAI/Claude/Gemini APIs on
                        port 8317. Existing config.yaml is NEVER overwritten.
                        After install, log in accounts with:
                          cli-proxy-api --config $CLIPROXY_HOME/config.yaml
                          cli-proxy-api -codex-login -no-browser   # remote-safe
  --rclone              Install rclone (static binary from downloads.rclone.org into XDG_BIN_HOME)
  --qbt                 Install qBittorrent-nox (static binary from GitHub releases)
  --aria2               Install aria2c (static musl binary from GitHub releases)
  --ffmpeg              Install FFmpeg (BtbN static GPL build: ffmpeg/ffprobe/ffplay)
  --camofox             Install Camofox (npm-global @askjo/camofox-browser: anti-detection
                        Firefox server + MCP adapter). Provisions the package-pinned
                        Camoufox engine into the persistent cache, applies the Replit
                        lib closure + WebGL auto-skip, then run: camofox-browser
                        (API on http://127.0.0.1:9377)
  --doctor              Verify the toolchain (no install) — prints versions and flags
  --fix                 Rewrite ALL wiring without deleting/reinstalling any
                        tool: shell rc (toolchain block + hermes-tools block,
                        when $HERMES_HOME/tools exists), .replit userenv keys,
                        the workflow shim + REPLIT_BASHRC pin, ~/.profile,
                        hermes config terminal.shell_init_files, and the
                        durable libatomic. Reads installed payloads to
                        resolve per-tool values; a tool that is NOT installed
                        is not resurrected. Combine: --doctor --fix (report,
                        then repair), or bare --fix (repair + report).
  --clean [target]      Remove installed toolchain artifacts. A pre-flight
                        summary lists exactly what will be removed first.
                        Bare --clean / -c opens the CLEAN PICK-MENU (tick the
                        tools to remove). An explicit target skips the menu:
                        \`--clean all\` (or \`--clean --all\`) removes everything;
                        --clean node|uv|android-tools|oc|opencode|ollama|
                        claude|hermes|ori|cliproxy|camofox|rclone|qbt|aria2|ffmpeg removes one
                        tool. Flag-driven cleanup prompts for confirmation
                        unless -y/--yes is given.
                        USER DATA: tools that own it are handled safely —
                        hermes is backed up with its OWN CLI (`hermes backup`,
                        restorable via `hermes import`) and the archive copied
                        to $XDG_CONFIG_HOME/hermes/hermes-backup.zip BEFORE its
                        dir is removed (left intact if the backup fails);
                        ollama models and
                        camofox server state are preserved; cliproxy keeps
                        config + OAuth logins.
                        NON-INTERACTIVE: a bare \`--clean\` with no target is
                        REFUSED (it would wipe everything, Hermes included).
                        Use \`--clean all -y\` to confirm a full wipe.
  --list, --show        Show current toolchain state (wired tools, binaries, env vars)
  -y,  --yes            Skip the cleanup confirmation prompt
  -h,  --help           Show this help

Examples:
  bash setup.sh                 interactive install menu (on a terminal)
  bash setup.sh -c              interactive clean menu — pick tools to remove
  bash setup.sh --clean         same as -c
  bash setup.sh --all           install everything (no menu)
  bash setup.sh --android-tools
  bash setup.sh --uv --node
  bash setup.sh --clean all     remove the entire toolchain (asks y/N)
  bash setup.sh --clean --all   same thing (flag form)
  bash setup.sh --clean node    remove Node.js
  bash setup.sh --clean all -y  remove everything, no prompt

After setup, every new shell sources the generated shell rc automatically, so
'java', 'python', 'uv', 'node', 'adb', 'opencode' are on PATH directly.
USAGE
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -a|--all)                  INSTALL_ALL=true ;;
      -at|--android-tools)       INSTALL_ANDROID=true ;;
      --uv)                      INSTALL_UV=true ;;
      --node)                    INSTALL_NODE=true ;;
      -oc|--opencode)       		 INSTALL_OPENCODE=true ;;
      -ol|--ollama)              INSTALL_OLLAMA=true ;;
      -cl|--claude)              INSTALL_CLAUDE=true ;;
      -ha|--hermes) 						 INSTALL_HERMES=true ;;
      -ori|--openrouterai) 		 INSTALL_ORI=true ;;
      -cp|--cliproxy)           INSTALL_CLIPROXY=true ;;
      --rclone)                 INSTALL_RCLONE=true ;;
      --qbt)                    INSTALL_QBT=true ;;
      --aria2)                  INSTALL_ARIA2=true ;;
      --ffmpeg)                 INSTALL_FFMPEG=true ;;
      --camofox)                INSTALL_CAMOFOX=true ;;
      -hb|--hermes-browser|--hermes-chromium) INSTALL_HERMES_CHROMIUM=true ;;
      --doctor)                  DOCTOR=true ;;
      --fix)                     FIX=true ;;
      --list|--show)             LIST_STATE=true ;;
      -c|--clean)
        CLEAN=true
        # Optional target: 'all' (or --all) = full wipe, a tool name =
        # single tool. No target (bare --clean) = open the CLEAN PICK-MENU on
        # a terminal; non-interactive bare --clean falls back to 'all'.
        if (($# > 1)); then
          case "$2" in
            all|--all)          CLEAN_TARGET="all"; shift ;;
            -y|--yes)           : ;;  # consumed by the loop on the next pass
            -*)
              # A flag directly after --clean is almost always a typo'd target
              # ('--clean --node'); refuse instead of silently opening the
              # menu (or, non-interactively, wiping everything).
              die "--clean takes 'all' or a tool target: use '--clean <target> <flags>' (got '$2' after --clean)"
              ;;
            *)                  CLEAN_TARGET="$2"; shift ;;
          esac
        fi
        ;;
      -y|--yes)                  YES=true ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option '$1'. Use --help for usage."
        ;;
    esac
    shift
  done

  # Default to full provisioning when nothing specific was requested.
  if ! $CLEAN && ! $INSTALL_ANDROID && ! $INSTALL_NODE && ! $INSTALL_UV \
     && ! $INSTALL_OPENCODE && ! $INSTALL_OLLAMA && ! $INSTALL_CLAUDE \
     && ! $INSTALL_HERMES && ! $INSTALL_ORI && ! $INSTALL_RCLONE \
     && ! $INSTALL_QBT && ! $INSTALL_ARIA2 && ! $INSTALL_FFMPEG && ! $INSTALL_CLIPROXY \
     && ! $INSTALL_CAMOFOX \
     && ! $DOCTOR && ! $FIX && ! $LIST_STATE; then
    INSTALL_ALL=true
  fi

  if $INSTALL_ALL; then
    INSTALL_ANDROID=true
    INSTALL_NODE=true
    INSTALL_UV=true
    INSTALL_OPENCODE=true
    INSTALL_OLLAMA=true
    INSTALL_CLAUDE=true
    INSTALL_HERMES=true
    INSTALL_ORI=true
    INSTALL_RCLONE=true
    INSTALL_QBT=true
    INSTALL_ARIA2=true
    INSTALL_FFMPEG=true
    INSTALL_CLIPROXY=true
    INSTALL_CAMOFOX=true
    INSTALL_HERMES_CHROMIUM=true
  fi
}

# Shell rc (managed block appended at the bottom) ────────────────────────────
# The managed block is APPENDED, never prepended: the file is the user's own
# rc and prepending would clobber their editorial header. The block lives at
# the bottom so user customizations above win. Two emitters:
#   emit_managed_block  replit mode: env-sync, platform XDG exports, PATH,
#                       aliases. env-sync and aliases are Replit-only
#                       (they live in /run/replit, e.g. 'replit shutdown').
#   emit_minimal_block  default mode: PATH + tool env vars ONLY, for the
#                       tools installed this run. No env-sync, no aliases.
#
# Shared PATH-line generator: one guard per dir registered by this run's
# installers (deduped — most tools share XDG_BIN_HOME), emitted REVERSED so
# the first-registered dir ends up first on PATH (binaries beat the
# payload's own bin dirs). Dirs are emitted as LITERAL paths: exactly
# where installers put things this run; the block bakes the same
# literals as the XDG exports.
rc_path_lines() {
  local dir d dup
  local out=() reversed=()
  for dir in ${_TOOL_PATH_DIRS[@]+"${_TOOL_PATH_DIRS[@]}"}; do
    dup=false
    for d in ${out[@]+"${out[@]}"}; do
      [[ "$d" == "$dir" ]] && { dup=true; break; }
    done
    $dup || out+=("$dir")
  done
  for dir in ${out[@]+"${out[@]}"}; do
    reversed=("$dir" ${reversed[@]+"${reversed[@]}"})
  done
  for dir in ${reversed[@]+"${reversed[@]}"}; do
    printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' \
      "$dir" "$dir"
  done
}

# Tool env vars for the managed rc block. One guarded line per var registered
# by this run's installers: ${VAR:-<value>} so a platform/operator value in the
# inherited env wins at SOURCE time (never shadow it), while an unset var gets
# the value baked at write time. This is the rc path that replaces
# [userenv.shared] tool keys (only REPLIT_BASHRC stays in .replit).
rc_tool_env_lines() {
  local var skip
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"}; do
    [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue   # skip PATH dirs
    # Registries are emitted by emit_managed_block's hardcoded top block; never
    # repeat them here (a legacy [userenv.shared] registry key rescued into
    # _TOOL_ENV_VARS would otherwise emit the same export twice).
    skip=0
    for r in "${_FIXED_RC_ENV_VARS[@]}"; do
      [[ "$var" == "$r" ]] && { skip=1; break; }
    done
    ((skip)) && continue
    # A registered-but-unset var (its module was not sourced this run) is
    # skipped, never emitted empty — `${!var}` under set -u would abort the run.
    [[ -n "${!var+x}" ]] || continue
    printf 'export %s="${%s:-%s}"\n' "$var" "$var" "${!var}"
  done
}

# Hermes PM stages its own x64 Node tarball under $HERMES_HOME/tools; the
# official Node linux-x64 binary (>=22 line — what install_node ships, and
# what Camofox requires) is dynamically linked against libatomic.so.1, which
# this Nix image only ships inside /nix/store — hashed paths that get
# garbage-collected, so they must never be referenced directly. Copy a
# verified x86-64 build into the durable $WORKSPACE/.local/lib (the dir the
# managed rc block puts on LD_LIBRARY_PATH; note the gcc-14.2.1 copy on some
# images is i386 — check ELF class).
# Runs every setup.sh: cheap no-op once the lib is in place.
# _ldpool_prepend DIR — make the current setup process (and every child it
# spawns: install_node's version probe, npm, the node server when setup.sh is
# used as a launcher) see the pool WITHOUT clobbering an LD_LIBRARY_PATH the
# platform already set. Idempotent; mirrors emit_managed_block's guard.
_ldpool_prepend() {
  [[ -d "$1" ]] || return 0   # loader skips missing dirs; keep the env clean
  case ":${LD_LIBRARY_PATH:-}:" in
    *":$1:"*) ;;
    *) export LD_LIBRARY_PATH="$1${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
  esac
}

ensure_libatomic() {
  local target_dir="${1:-$WORKSPACE/.local/lib}" marker src found=0
  # A staged/present lib counts only if it is an x86-64 shared object: the
  # image also ships i386 gcc copies, /nix/store is runner-writable on Replit
  # (so a planted path can win the glob), and 'ELF 64-bit' alone would accept
  # aarch64/ppc64 too. file -L dereferences the SONAME symlink (plain `file`
  # would print "symbolic link to ..." and fail the grep); missing file(1)
  # fails closed (nonzero -> re-scan).
  _la_is_x86_64() { file -L "$1" 2>/dev/null | grep -q 'ELF 64-bit LSB shared object, x86-64'; }
  # Marker cache: /nix/store is a NETWORK filesystem on Replit — every glob
  # here costs minutes on a cold store (measured: one /*gcc-*-lib/ pass =
  # 70s). The marker makes repeat runs instant — but ONLY as EVIDENCE, not
  # attestation: at stage time it records the sha256 of the staged lib, and
  # the fast path re-verifies the hash (and the x86-64 ELF class), so a
  # swapped/tampered libatomic.so.1 or a stale 0-byte pre-4.5.2 marker falls
  # through to a re-scan instead of printing "✓ already staged" while node
  # dies at the loader. Empty marker = pre-hash era: accept the lib only
  # after the ELF check, then backfill the hash.
  marker="$target_dir/.libatomic-ok"
  if [[ -f "$marker" && -e "$target_dir/libatomic.so.1" ]] && _la_is_x86_64 "$target_dir/libatomic.so.1"; then
    local _rec _now
    _rec="$(cat "$marker" 2>/dev/null | tr -d '[:space:]')"
    _now="$(sha256sum "$(readlink -f "$target_dir/libatomic.so.1")" 2>/dev/null | cut -d' ' -f1)"
    if [[ -z "$_rec" ]]; then          # pre-hash marker: ELF-verified, backfill
      [[ -n "$_now" ]] && printf '%s\n' "$_now" > "$marker"
      ok "libatomic already staged (marker backfilled: $marker)"
      _ldpool_prepend "$target_dir"
      return 0
    fi
    if [[ "$_rec" == "$_now" ]]; then
      ok "libatomic already staged (hash verified: $marker)"
      _ldpool_prepend "$target_dir"
      return 0
    fi
    warn "staged libatomic.so.1 does not match recorded hash — re-staging"
  fi
  if command -v ldconfig &>/dev/null; then
    # Trust but verify: a stale ldconfig cache or an i386-only entry also
    # GREP positive while node's loader still fails ('cannot open shared
    # object file' — measured on a repl where setup printed nothing here).
    # Require the cached path to exist AND be an x86-64 ELF.
    local _sys_la
    _sys_la="$(ldconfig -p 2>/dev/null | grep 'libatomic\.so\.1' | head -1)"; _sys_la="${_sys_la##*=> }"
    if [[ -n "$_sys_la" && -e "$_sys_la" ]] && _la_is_x86_64 "$_sys_la"; then
      _ldpool_prepend "$target_dir"
      return 0  # plain distro / NixOS: the system loader really resolves it
    fi
  fi
  mkdir -p "$target_dir" 2>/dev/null || { warn "cannot create $target_dir — libatomic not staged"; return 0; }
  # -e (not compgen -G): a DANGLING symlink matches a glob but satisfies no
  # loader — demand a real, x86-64 file and re-stage otherwise.
  if [[ -e "$target_dir/libatomic.so.1" ]] && _la_is_x86_64 "$target_dir/libatomic.so.1"; then
    sha256sum "$(readlink -f "$target_dir/libatomic.so.1")" 2>/dev/null | cut -d' ' -f1 > "$marker" || touch "$marker"
    ok "libatomic for official Node tarballs already present: $target_dir"
    _ldpool_prepend "$target_dir"
    return 0
  fi
  # ONE store pass, gcc-lib dir only — libatomic always ships there. Never
  # glob all of /nix/store/*/* (each pass costs minutes on a cold store).
  # Negative cache: a FAILED scan is also expensive to repeat — every --fix
  # on a still-cold image would re-pay the ~70s glob. Skip rescans for 15m;
  # a successful stage removes the miss marker above.
  if [[ -f "$target_dir/.libatomic-miss" ]] \
     && (( $(date +%s) - $(stat -c %Y "$target_dir/.libatomic-miss" 2>/dev/null || echo 0) < 900 )); then
    warn "libatomic scan previously failed (<15m ago) — rerun setup.sh --fix once the image is warm"
    return 0
  fi
  echo "  scanning /nix/store for libatomic (first run only; cold store: up to a few minutes)..."
  for src in /nix/store/*gcc-*-lib/lib/libatomic.so.1.*; do
    [[ -f "$src" ]] || continue
    found=1
    _la_is_x86_64 "$src" || continue
    # cp to temp + mv (rename(2) is atomic): cp -f over a lib currently
    # mmapped by a running node falls back to unlink+recreate and opens a
    # demand-load failure window for live consumers.
    cp -f "$src" "$target_dir/.la.tmp.$$" 2>/dev/null || { warn "copy failed from $src"; continue; }
    mv -f "$target_dir/.la.tmp.$$" "$target_dir/$(basename -- "$src")" 2>/dev/null || { warn "rename failed into $target_dir"; rm -f "$target_dir/.la.tmp.$$"; continue; }
    ln -sf "$(basename -- "$src")" "$target_dir/libatomic.so.1"
    sha256sum "$target_dir/$(basename -- "$src")" 2>/dev/null | cut -d' ' -f1 > "$marker" || touch "$marker"
    rm -f "$target_dir/.libatomic-miss"
    ok "libatomic staged: $target_dir/libatomic.so.1 (from $(basename "$(dirname "$(dirname "$src")")"))"
    _ldpool_prepend "$target_dir"
    return 0
  done
  if [[ "$found" == 1 ]]; then
    warn "no usable libatomic staged — candidates failed the x86-64 ELF check or the copy (see messages above)"
  else
    # No usable lib found: cache the miss for 15 min so --fix/next run does
    # not re-pay the 70s network-store glob while the image is still cold.
    touch "$target_dir/.libatomic-miss"
    warn "no gcc-*-lib dirs in /nix/store yet (store cold?) — rerun setup.sh once the image is warm"
  fi
}

emit_managed_block() {
  cat <<EOF

# >>> toolchain >>>

# Registry defaults. Replit feeds the package-firewall
# (http://package-firewall.replit.internal/...) into the runtime env BEFORE
# this block is sourced, so these are FALLBACKS only: the \${VAR:-default}
# form resolves at SOURCE time and leaves a platform/operator value intact.
# Unguarded exports here previously forced the public registry and shadowed
# the firewall — `echo $NPM_CONFIG_REGISTRY` showed registry.npmjs.org.
export YARN_REGISTRY="\${YARN_REGISTRY:-https://registry.yarnpkg.com}"
export YARN_NPM_REGISTRY_SERVER="\${YARN_NPM_REGISTRY_SERVER:-https://registry.yarnpkg.com}"
export PIP_INDEX_URL="\${PIP_INDEX_URL:-https://pypi.org/simple}"
export npm_config_registry="\${npm_config_registry:-https://registry.npmjs.org}"
export NPM_CONFIG_REGISTRY="\${NPM_CONFIG_REGISTRY:-https://registry.npmjs.org}"
export GOPROXY="\${GOPROXY:-https://proxy.golang.org,direct}"
export PIP_TRUSTED_HOST="\${PIP_TRUSTED_HOST:-pypi.org}"

# npm lifecycle scripts. The literal form the docs suggest,
#   npm config set dangerously-allow-all-scripts=true --location=user
# writes $HOME/.npmrc — and on Replit $HOME is WIPED on recreate, so the
# setting silently disappears. The env form is read by npm identically
# (verified with npm config ls -l) and lives in this persistent block.
export npm_config_dangerously_allow_all_scripts=true

# TLS / CA bundle. The cacert package in replit.nix exports
# SYSTEM_CERTIFICATE_PATH; wire it into the standard variables curl / npm /
# node consult, so HTTPS fetches trust the Nix bundle instead of failing.
# Escaped so the values resolve when the shell SOURCES this file (the
# platform env is loaded before $BASHRC), not at write time — an unescaped
# heredoc would bake in the writing shell's value and clobber an operator's.
if [ -n "\${SYSTEM_CERTIFICATE_PATH:-}" ]; then
  # Node/Python/requests need the system bundle (it trusts the Replit proxy root);
  # the Nix bundle does not. Fall back to Nix only if the system bundle is absent.
  _tls_sys_ca=/etc/ssl/certs/ca-certificates.crt
  _tls_ca="\$SYSTEM_CERTIFICATE_PATH"
  [ -r "\$_tls_sys_ca" ] && _tls_ca="\$_tls_sys_ca"
  export SSL_CERT_FILE="\$_tls_ca"
  export SSL_CERT_DIR=/etc/ssl/certs
  export NIX_SSL_CERT_FILE="\$SYSTEM_CERTIFICATE_PATH"
  export NODE_EXTRA_CA_CERTS="\$_tls_ca"
  export REQUESTS_CA_BUNDLE="\$_tls_ca"
fi

# Hermes PM stages its own x64 Node tarball AND --node installs the official
# x64 tarball: both link libatomic.so.1, which this Nix image only ships under
# garbage-collected /nix/store paths — see ensure_libatomic for the durable
# copy in $WORKSPACE/.local/lib (the dir this block prepends below).
# This is an APPEND (the platform's own nix closure dirs stay on the path);
# the \$ escapes keep the test at rc-source time — unescaped, the write-time
# heredoc expansion would bake the current value in and turn the append
# into a clobber of the platform LD_LIBRARY_PATH.
if [[ -n "\${LD_LIBRARY_PATH:-}" ]]; then
  case ":\$LD_LIBRARY_PATH:" in *":$WORKSPACE/.local/lib:"*) ;; *) export LD_LIBRARY_PATH="$WORKSPACE/.local/lib:\$LD_LIBRARY_PATH" ;; esac
else
  export LD_LIBRARY_PATH="$WORKSPACE/.local/lib"
fi

# Camofox GTK/X11 lib closure: applied inline by the .replit camofox workflow /
# any invocation (see references/camofox.md) — NOT in the rc, because the closure
# is large and only the browser binary needs it.

# Tool env vars (JAVA_HOME, NODE_DIR, OLLAMA_MODELS, ...) — the rc block is
# the single global source now. Replit workflow/agent shells reach this rc via
# the REPLIT_BASHRC shim (write_replit_bashrc), so [userenv.shared] no longer
# carries them; the .replit table keeps only REPLIT_BASHRC. Emitted guarded
# (${VAR:-value}) so a value the platform/operator set at source time wins.
EOF
  rc_tool_env_lines
  cat <<'EOF'

# Platform-level dirs. XDG_CONFIG/DATA/CACHE_HOME come from the platform by default.
# XDG_BIN_HOME is ours (the single PATH entry), so it is exported only when set.
[ -n "${XDG_BIN_HOME:-}" ] && export XDG_BIN_HOME="$XDG_BIN_HOME"

# git global config -> workspace-persisted file (tmpfs on /run is wiped)
export GIT_CONFIG_GLOBAL="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"

# PATH: prepend dirs registered by this run's installers, once per
# shell. Agent tooling spawns many nested shells that re-source this rc, so
# each entry is guarded individually (a single combined pattern can't work:
# adjacent PATH entries share one colon, which one pattern segment can't
# consume twice). rc_path_lines emits one guarded line per registered dir.
EOF
  rc_path_lines
  cat <<'EOF'

# aliases
alias l='ls --color=auto -a'
alias la='l -la'
alias c='clear'
alias q='exit'

## replit
alias off='replit shutdown'

## git
alias glo='git log --oneline'
alias gss='git status --short'

## hermes
alias hu="$XDG_BIN_HOME/hermes update --force"
alias hce="$XDG_BIN_HOME/hermes config edit"
alias ht="$XDG_BIN_HOME/hermes --tui-native"

# <<< toolchain <<<
EOF
}

# Default-mode block: PATH + tool env vars for the tools installed THIS
# run. Values are baked at write time (concrete dirs) — unlike the replit
# block which re-exports vars via env-sync to keep them live. No env-sync,
# no aliases outside Replit.
emit_minimal_block() {
  cat <<'EOF'

# >>> toolchain >>>
# Managed by setup.sh — edit setup.sh and re-run, don't hand-edit.
EOF
  # Tool env vars first, then PATH. Same no-shadowing rule as the userenv
  # block: a var the operator set to a DIFFERENT value is not re-exported
  # here (snapshot taken at startup, so our own re-fed value still
  # re-emits on re-runs).
  local var
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"}; do
    [[ -n "${!var+x}" ]] || continue   # unset var (module not sourced) — skip
    if [[ -n "${_PRESET_ENV[$var]:-}" && "${_PRESET_ENV[$var]}" != "${!var}" ]]; then
      continue
    fi
    printf 'export %s="%s"\n' "$var" "${!var}"
  done
  rc_path_lines
  printf '# <<< toolchain <<<\n'
}

write_bashrc() {
  # Migrate any legacy [userenv.shared] tool keys into this run's set BEFORE
  # the block is emitted: write_replit_env (which runs after) DELETES them
  # from .replit, so they must already be in the rc or the value would be lost.
  if [[ "$REPLIT_MODE" == true ]]; then
    rescue_userenv_keys "${REPL_HOME}/.replit"
  fi

  # Nothing registered this run (e.g. --doctor alone) — don't touch the rc at
  # all. Stripping the block here would WIPE the wiring a previous install
  # wrote, since the block would be regenerated with zero PATH lines.
  if [[ ${#_TOOL_ENV_VARS[@]} -eq 0 && ${#_TOOL_PATH_DIRS[@]} -eq 0 ]]; then
    skip "no tools installed this run — leaving $BASHRC untouched"
    return 0
  fi

  step "Configuring shell rc: $BASHRC"
  mkdir -p "$(dirname "$BASHRC")"
  [[ -f "$BASHRC" ]] || : > "$BASHRC"
  chmod u+rw "$BASHRC" 2>/dev/null || true

  # Strip any prior managed block (old or new markers) so re-runs stay clean,
  # and squeeze blank runs (see the awk below) — the block's separator line
  # would otherwise accumulate one per re-run. Read the whole file, filter in
  # memory, and write back THROUGH the path (cat >): if $BASHRC is a symlink,
  # an in-place edit happens here, so sed/awk on $BASHRC could not silently
  # replace the symlink with a plain file.
  # Lift this run's predecessors' wiring before the strip — see rescue_tool_lines.
  rescue_tool_lines "$BASHRC"

  local rc_trim
  rc_trim="$(mktemp)"
  awk '
    $0 ~ /^# >>> toolchain >>>/ { inskip=1 }
    inskip { if ($0 ~ /^# <<< toolchain <<</) { inskip=0 }; next }
    /^$/ { blank++; next }
    { if (NR>1 && blank>0) print ""; blank=0; print }
  ' "$BASHRC" > "$rc_trim"
  cat "$rc_trim" > "$BASHRC"
  rm -f "$rc_trim"

  # Verify-and-revert (the shell-rc twin of write_replit_env's TOML check):
  # snapshot the stripped file, append the new block, then bash -n the
  # RESULT. A broken emit (e.g. an unbalanced quote in rc_path_lines) used to
  # ship straight into every shell's startup — now it reverts to the
  # pre-update file instead.
  local rc_backup
  rc_backup="$(mktemp)"
  cat "$BASHRC" > "$rc_backup"

  if [[ "$REPLIT_MODE" == true ]]; then
    # Append a fresh managed block at the bottom.
    emit_managed_block >> "$BASHRC"
  else
    emit_minimal_block >> "$BASHRC"
  fi

  if ! bash -n "$BASHRC" 2>/dev/null; then
    cat "$rc_backup" > "$BASHRC"
    rm -f "$rc_backup"
    die "$BASHRC failed 'bash -n' after toolchain update — reverted to the pre-update file"
  fi
  rm -f "$rc_backup"

  if [[ "$REPLIT_MODE" == true ]]; then
    ok "shell rc updated: $BASHRC (toolchain block appended at bottom)"
  else
    ok "shell rc updated: $BASHRC (minimal PATH block appended at bottom)"
  fi

  # Hermes-only hook: mirror $HERMES_HOME/tools onto the user PATH, OUTSIDE
  # and AFTER the managed block (own markers — see the function comment).
  # Runs only when hermes was (re)installed this run; idempotent via its
  # marker grep, so repeat installs don't stack blocks.
  if $INSTALL_HERMES; then
    write_hermes_tools_block
  fi
}

# Workflow shim + REPLIT_BASHRC pin (replit mode only) ──────────────────────
# Two halves of one fix, so they live in one function:
#
#   1. $REPLIT_BASHRC_FILE — a tiny rc whose only job is `source ~/.bashrc`;
#   2. the [userenv.shared] key REPLIT_BASHRC = <absolute path to it>.
#
# Workflow tasks (shell.exec in .replit, the Run button, deploys) run bash
# non-interactively: they never read $BASHRC, and start with the platform's
# env. Their bootstrap reads $REPLIT_BASHRC instead, so between a bare
# platform shell and our toolchain env the only missing link is that one
# variable. Sourcing ~/.bashrc gets the managed block on $BASHRC sourced in
# turn, which is what makes a workflow see the same PATH/tool vars as the
# user's terminal.
#
# Runs on EVERY replit-mode setup (registered as an exit action next to
# write_replit_env) — not only when tools were installed — because the shim
# is fixed wiring, and a .replit whose userenv was rewritten by anything
# else would otherwise lose the pin silently.
write_replit_bashrc() {
  if [[ "$REPLIT_MODE" != true ]]; then
    skip "workflow bashrc shim not written in default mode (interactive rc only)"
    return 0
  fi

  # 1. The shim. Regenerated unconditionally: it is wiring, not user config,
  #    so it never accumulates edits the way $BASHRC can.
  local dir
  dir="$(dirname "$REPLIT_BASHRC_FILE")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    warn "cannot create $dir — workflow bashrc shim not written"
    return 0
  fi

  cat > "$REPLIT_BASHRC_FILE" <<'EOF'
# Workflow/agent shells run bash with REPLIT_MODE set (agent|workflow). The
# store bashrc guards `source "$BASHRC"` behind `[[ -z "${REPLIT_MODE}" ]]`
# (~line 322), so in a workflow shell that guard fails and the managed rc is
# NOT sourced. Unset it here so sourcing ~/.bashrc (which sources $BASHRC in
# turn) actually loads the toolchain, matching the interactive terminal's env.
unset REPLIT_MODE
source ~/.bashrc
EOF

  # Same verify pass as $BASHRC: a typo here would break every workflow
  # shell's startup, and the failure would be silent (workflows do not
  # print their bootstrap errors).
  if ! bash -n "$REPLIT_BASHRC_FILE" 2>/dev/null; then
    rm -f "$REPLIT_BASHRC_FILE"
    warn "$REPLIT_BASHRC_FILE failed 'bash -n' — removed; .replit pin not written"
    return 0
  fi
  ok "workflow bashrc shim written: $REPLIT_BASHRC_FILE"

  # 2. The pin. Forced: the platform PRE-SETS REPLIT_BASHRC to the read-only
  #    Nix-store bashrc, so the no-shadowing rule write_replit_env honours
  #    would classify our value as shadowing a platform choice and drop it.
  #    This key is the entire point of the function — it must land. Safe
  #    precisely because it only takes effect where nothing else does:
  #    interactive consoles keep sourcing $BASHRC.
  local replit_file="$REPL_HOME/.replit"
  if [[ ! -f "$replit_file" || ! -w "$replit_file" ]]; then
    skip ".replit missing or not writable — workflow shops keep the platform env"
    return 0
  fi

  # Absolute path, resolved now: .replit is TOML read by Replit, with no
  # shell expansion anywhere in it, so a $VAR here would be literal text.
  local target
  target="$(cd -- "$dir" && pwd)/$(basename "$REPLIT_BASHRC_FILE")"

  local -a py=()
  if ! replit_resolve_py py; then
    warn "no tomlkit-capable python (project .venv or uv) — REPLIT_BASHRC pin not written; set it by hand in $replit_file:"
    warn "  REPLIT_BASHRC = \"$target\""
    return 0
  fi

  if ! "${py[@]}" "$SCRIPT_DIR/dot_replit.py" --file "$replit_file" \
       --set "REPLIT_BASHRC=$target"; then
    warn ".replit REPLIT_BASHRC pin failed — workflow shells keep the platform env"
    return 0
  fi
  ok "workflow bashrc pinned: REPLIT_BASHRC=$target (.replit userenv)"
}

# Lift the wiring a PRIOR run's managed block wrote (both writers regenerate
# the block from what was registered THIS run, so without this every new
# install wiped the previous tools' vars and PATH dirs). Rescued keys go into
# _TOOL_ENV_VARS / _TOOL_PATH_DIRS — the emitters then re-apply the
# no-shadowing rule, rc_path_lines dedupes PATH dirs, and a var/dir this
# run re-registers appears once. Keep ALL rescued lines (even for a tool this
# run explicitly cleans) because the block is the single source for these
# vars and an unregistered var can't be verified dead anywhere else;
# `--clean all` strips the whole block, which is the removal path. Only the
# LAST block (if any) counts — earlier ones are superseded.
rescue_tool_lines() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local line in_block=0 var
  local last_block=()
  while IFS= read -r line; do
    case "$line" in
      '# >>> toolchain >>>') in_block=1; last_block=(); continue ;;
      '# <<< toolchain <<<') in_block=0; continue ;;
    esac
    (( in_block )) && last_block+=("$line")
  done < "$file"

  # Seed this run's registrations so rescue never duplicates them.
  # rc_path_lines dedupes PATH dirs; the emitters' no-shadowing rule decides
  # vars. Platform vars (WORKSPACE and the five XDG/REPL_HOME exports the
  # replit block carries) lifted via 'export NAME=' syntax are NOT
  # re-registered — [userenv.shared] must not shadow the platform env.
  local -A seen=()
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"}; do seen["$var"]=1; done

  for line in ${last_block[@]+"${last_block[@]}"}; do
    if [[ "$line" == 'case ":$PATH:" in '* ]]; then
      # rc_path_lines' guarded line — lift the dir so guards come back. The
      # pattern segment is *":/dir:"* (colons included — the guard needs
      # them); the regex keeps inner colons: capture, then strip.
      # The regex lives in a variable because escaped quotes inline mis-parse.
      local re='\*"([^"]*)"\*'
      if [[ "$line" =~ $re ]]; then
        local dir="${BASH_REMATCH[1]#:}"
        _TOOL_PATH_DIRS+=("${dir%:}")
      fi
      continue
    fi
    # Tool-var line, in either writer's grammar: 'NAME = "value"' (userenv) or
    # 'export NAME="value"' (rc).
    if [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]] \
       || [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
      var="${BASH_REMATCH[1]}"
      case "$var" in
        WORKSPACE|REPL_HOME|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|XDG_BIN_HOME|REPLIT_BASHRC)
          continue ;;
      esac
      # A var the CURRENT script no longer defines (dropped in a newer
      # version): re-emitting ${!var} would be fatal under set -u; drop it.
      if [[ -z "${!var+x}" ]]; then
        continue
      fi
      if [[ -z "${seen[$var]:-}" ]]; then
        seen["$var"]=1
        _TOOL_ENV_VARS+=("$var")
      fi
    fi
  done
}

# [userenv.shared] manager ──────────────────────────────────────────────────
# The shell rc reaches shells that reach it — interactive consoles directly,
# and Replit workflow/agent shells through the REPLIT_BASHRC shim
# (write_replit_bashrc). So the rc block is the single global source for tool
# vars; [userenv.shared] keeps ONLY the REPLIT_BASHRC pin. ALL TOML
# manipulation lives in scripts/dot_replit.py (tomlkit): keys are added,
# updated in place, or deleted by NAME inside the table — no marker comments,
# no sed/awk line surgery. Everything else in .replit (workflows, ports, the
# operator's own keys) round-trips untouched.

# Resolve a tomlkit-capable interpreter into the array named $1: the
# project .venv first, then any python3 (Replit's) that has tomlkit, then
# uv (which fetches tomlkit on demand). Returns 1 when nothing qualifies.
replit_resolve_py() {
  local -n _py="$1"
  if [[ -x "$WORKSPACE/.venv/bin/python3" ]] \
    && "$WORKSPACE/.venv/bin/python3" -c 'import tomlkit' 2>/dev/null; then
    _py=("$WORKSPACE/.venv/bin/python3")
  elif command -v python3 &>/dev/null && python3 -c 'import tomlkit' 2>/dev/null; then
    _py=(python3)
  elif command -v uv &>/dev/null; then
    _py=(uv run --no-project --with tomlkit python3)
  elif [[ -x "$XDG_BIN_HOME/uv" ]]; then
    _py=("$XDG_BIN_HOME/uv" run --no-project --with tomlkit python3)
  else
    return 1
  fi
}

# The fixed registry override NAMES. Legacy [userenv.shared] keys are deleted
# by name (strip_userenv_keys / write_replit_env); the VALUES live in the
# managed rc block (emit_managed_block), guarded so a platform/operator value
# (Replit's package-firewall mirrors) wins.
_REGISTRY_ENV_VARS=(YARN_REGISTRY YARN_NPM_REGISTRY_SERVER PIP_INDEX_URL \
  npm_config_registry NPM_CONFIG_REGISTRY GOPROXY PIP_TRUSTED_HOST)
# Vars the fixed blocks already export (registries, the npm-scripts setting and
# the workspace-persisted git config). Never re-emit them as tool vars — doing
# so duplicated the export and let a platform value shadow ours.
_FIXED_RC_ENV_VARS=("${_REGISTRY_ENV_VARS[@]}" \
  npm_config_dangerously_allow_all_scripts GIT_CONFIG_GLOBAL)

# Carry forwards tool vars a previous run left in [userenv.shared] WITHOUT
# needing their installer to re-run this time. Candidates are restricted to
# keys WITH a wire owner (seed_tool_wiring / installers) — operator keys
# (NODE_ENV, SERVER_LOG_LEVEL, ...) are never re-registered. A key the
# current script no longer defines is dropped (re-emitting ${!var} would be
# fatal under set -u; the writer's --delete-key clears it).
rescue_userenv_keys() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local -A seen=()
  local var line in_section=0
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"}; do seen["$var"]=1; done
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[ ]]; then
      [[ "$line" == "[userenv.shared]" ]] && in_section=1 || in_section=0
      continue
    fi
    ((in_section)) || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] || continue
    var="${BASH_REMATCH[1]}"
    [[ -n "$(env_var_owner "$var")" ]] || continue
    # A fixed-block var (registry / npm setting / git config) is skipped here
    # so the same export never lands twice.
    for r in "${_FIXED_RC_ENV_VARS[@]}"; do
      [[ "$var" == "$r" ]] && continue 2
    done
    [[ -n "${seen[$var]:-}" ]] && continue
    [[ -n "${!var+x}" ]] || continue
    seen["$var"]=1
    _TOOL_ENV_VARS+=("$var")
  done < "$file"
}

# Delete userenv keys owned by <labels> ('all' or space-joined wire labels)
# — the .replit twin of strip_tool_wiring (which is now rc-only). Pure
# depends on whether that key exists; an empty [userenv.shared] table is also dropped.
# [userenv.shared] table is removed by the helper.
strip_userenv_keys() {
  local labels="$1" file="$2"
  [[ -f "$file" && -w "$file" ]] || return 0
  local var owner
  # The REPLIT_BASHRC pin is owned by the shim mechanism, NOT by any single
  # tool — removing it on a per-tool clean would silently disable the
  # workflow/agent-shell toolchain fix. Only a full wipe ('all') drops it.
  local -a del=()
  [[ "$labels" == all ]] && del+=(--delete-key REPLIT_BASHRC)
  for var in "${!_WIRE_OWNER[@]}"; do
    [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue   # skip PATH dirs
    owner="$(env_var_owner "$var")"
    [[ -n "$owner" ]] || continue
    if [[ "$labels" == all ]] || owned_only_by "$owner" "$labels"; then
      del+=(--delete-key "$var")
    fi
  done
  if [[ "$labels" == all ]]; then
    for var in "${_REGISTRY_ENV_VARS[@]}"; do del+=(--delete-key "$var"); done
  fi
  ((${#del[@]})) || return 0
  local -a py=()
  replit_resolve_py py || { warn "no tomlkit-capable python (project .venv or uv) — $file userenv keys left untouched"; return 0; }
  if "${py[@]}" "$SCRIPT_DIR/dot_replit.py" --file "$file" "${del[@]}"; then
    ok "Removed $labels-owned userenv keys from $file"
  else
    warn "userenv key cleanup failed for $file — edit it by hand"
  fi
}

write_replit_env() {
  if [[ "$REPLIT_MODE" != true ]]; then
    skip ".replit userenv not written in default mode (shell rc is the only env path)"
    return 0
  fi
  # Nothing registered this run (e.g. --doctor alone) — keep the existing
  # keys. Rewriting would drop the vars a previous install wrote.
  if [[ ${#_TOOL_ENV_VARS[@]} -eq 0 ]]; then
    skip "no tools installed this run — leaving .replit userenv untouched"
    return 0
  fi
  local replit_file="$REPL_HOME/.replit"
  if [[ ! -f "$replit_file" || ! -w "$replit_file" ]]; then
    skip ".replit missing or not writable — shell rc remains the only env path"
    return 0
  fi
  step "Configuring .replit userenv: $replit_file"

  local backup
  backup="$(mktemp)"
  cp "$replit_file" "$backup"

  # Lift this run's predecessors' tool vars before the delete+set — see
  # rescue_userenv_keys.
  rescue_userenv_keys "$replit_file"

  # This function only resolves an interpreter, snapshots a backup and
  # builds the key universe. The helper (tomlkit) clears every managed key
  # (--delete-key), re-adds the ones surviving the no-shadowing rule
  # (--set), then tomllib-validates and atomically replaces the file. The
  # backup is the revert path.
  local -a py=()
  if ! replit_resolve_py py; then
    rm -f "$backup"
    warn "no tomlkit-capable python (project .venv or uv) — .replit userenv untouched; shell rc remains the only env path"
    return 0
  fi

  # [userenv.shared] now keeps ONLY the REPLIT_BASHRC pin (set by
  # write_replit_bashrc). Tool/registry vars used to be written here as the
  # "global env path"; they now live in the managed rc block
  # (emit_managed_block -> rc_tool_env_lines), which every shell reaches via
  # the REPLIT_BASHRC shim. This function therefore only DELETES legacy tool
  # keys here, cleaning up the old layout, and sets nothing.
  local var
  local -A seen=()
  # REPLIT_BASHRC is deliberately NOT in this delete list: the pin is owned
  # by write_replit_bashrc, which runs after this function and re-sets it.
  # Deleting it here would race that write on every install.
  local -a delete_args=()
  for var in ${_TOOL_ENV_VARS[@]+"${_TOOL_ENV_VARS[@]}"} "${_REGISTRY_ENV_VARS[@]}"; do
    [[ -n "${seen[$var]:-}" ]] && continue
    seen["$var"]=1
    delete_args+=(--delete-key "$var")
  done

  if ! "${py[@]}" "$SCRIPT_DIR/dot_replit.py" --file "$replit_file" \
      "${delete_args[@]}"; then
    mv -f "$backup" "$replit_file"
    die ".replit userenv update failed — reverted to backup"
  fi
  rm -f "$backup"
  ok "userenv cleaned: $replit_file (tool vars now live in the rc block; only REPLIT_BASHRC pinned)"
}
