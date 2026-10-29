# shellcheck shell=bash
# e2e entry (sshd key-only) — lets the operator's box reach this one over the
# tailnet instead of a browser canvas. Runtime story: references/e2e-sshd-bridge.md,
# proxy/port facts: references/exposing-ports.md.
# ─────────────────────────────────────────────────────────────────────────────
# Two container facts drive every path here:
#   * $HOME is WIPED on restart, $REPL_HOME is not. So ~/.ssh itself is made a
#     symlink into $REPL_HOME/.ssh — the operator's own ssh config, keys and
#     known_hosts then survive a reboot, and so do this sshd's host key and
#     authorized_keys (a new host key on every boot is an ssh warning cascade).
#   * an autostart line in a shell rc re-fires every time a terminal opens. The
#     daemon is therefore published as a `.replit` [workflows] entry, which runs
#     once per boot and is start/stop-able from the UI.
# --e2e PREPARES only (config, host key, authorized_keys, dirs, binaries). Nothing is
# launched: a preparing run stays quiet and exits. --start is what launches sshd and
# tailscaled, so the daemon side is opt-in and never a surprise.
# The tailnet auth key is NEVER baked in: export TAILSCALE_AUTH_KEY for the first
# start, afterwards the stored node identity carries the login on its own.
# ─────────────────────────────────────────────────────────────────────────────

: "${E2E_PORT:=6800}"
E2E_DIR="${E2E_DIR:-${REPL_HOME:-$HOME/workspace}/.ssh/e2e-sshd}"
E2E_SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-}")/../.." 2>/dev/null && pwd)"

_e2e_homedir() { getent passwd "$(id -un)" | cut -d: -f6; }

# The command a user pastes/runs. Relative to the workspace whenever the skill lives
# inside it: workflows run with the workspace as cwd, so moving or renaming the skill
# dir cannot leave a dead absolute path behind. Only an outside copy needs the absolute
# one, and then the caller says so.
_e2e_cmd() {
  local base="${REPL_HOME:-$HOME/workspace}" cmd="$E2E_SKILL_ROOT/scripts/setup.sh"
  [[ "$cmd" == "$base"/* ]] && cmd="${cmd#"$base"/}"
  printf '%s\n' "$cmd"
}
_e2e_cmd_external() { [[ "$(_e2e_cmd)" == /* ]]; }

# sshd/ssh live in different PATH entries per shell; probe absolute candidates.
_e2e_find() {
  local n="$1"; shift
  command -v "$n" 2>/dev/null && return 0
  local g p
  for g in "$@"; do for p in $g; do [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }; done; done
  return 1
}

_e2e_banner() {
  local h="$1" p="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/$h/$p; IFS= read -r -t 2 l <&3 && printf '%s' \"\$l\"" 2>/dev/null
}

# Client-side hop. `nc` is not portable: netcat-openbsd has -X/-x, but
# netcat-traditional and busybox nc reject -X ("invalid option -- 'X'"). Print
# every form, best first, so the operator never has to guess which nc they own.
_e2e_ssh_hint() {
  local u="$1" ip="$2" h="${2:-<ip-tailnet>}"
  echo "  dari mesin lain (pilih yang ada di klien itu):"
  echo "    tailscale (socket default): ssh -o ProxyCommand='tailscale nc %h %p' -p $E2E_PORT $u@$h"
  echo "    tailscale userspace:        ssh -o ProxyCommand='tailscale --socket=<sock tailscaled klien> nc %h %p' -p $E2E_PORT $u@$h"
  echo "    ncat:                       ssh -o ProxyCommand='ncat --proxy 127.0.0.1:1055 --proxy-type socks5 %h %p' -p $E2E_PORT $u@$h"
  echo "    netcat-openbsd:             ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:1055 %h %p' -p $E2E_PORT $u@$h"
  echo "    busybox/traditional nc tidak punya -X → pakai tailscale atau ncat"
  [ -n "$ip" ] || echo "    alamat tailnet belum ada: isi TAILSCALE_AUTH_KEY lalu jalankan ulang"
}

# ~/.ssh -> persistent. Runs before anything writes a key, so an existing
# hand-installed ~/.ssh is moved into the persistent dir instead of discarded.
_e2e_persist_ssh() {
  local home; home="$(_e2e_homedir)"
  local target="${REPL_HOME:-$home/workspace}/.ssh"
  mkdir -p "$target" && chmod 700 "$target"
  if [ -L "$home/.ssh" ]; then
    [ "$(readlink -f "$home/.ssh")" = "$(readlink -f "$target")" ] || warn "~/.ssh menunjuk $(readlink "$home/.ssh"), bukan $target"
    return 0
  fi
  if [ -d "$home/.ssh" ]; then
    cp -a "$home/.ssh/." "$target/" 2>/dev/null || warn "sebagian isi ~/.ssh gagal dipindah"
    rm -rf "$home/.ssh"
  fi
  ln -s "$target" "$home/.ssh" && ok "~/.ssh -> $target (persisten, tak hilang saat restart)"
}

# .replit workflow: REPORT ONLY, never written. A boot start belongs in .replit,
# but the file belongs to the operator: their workflow names, their tasks, their
# ordering. Appending a block steals a name (a second `name = "e2e"` collides
# with one they already use) and rewrites a file we do not own.
_e2e_workflow() {
  local rp="${REPL_HOME:-$HOME/workspace}/.replit"
  [ -f "$rp" ] || { warn ".replit tidak ada — workflow autostart dilewati"; return 0; }
  local base="${REPL_HOME:-$HOME/workspace}"

  # Already wired? Then only two things matter: does the command it points at still
  # exist, and does it carry --wf. Path first — a moved skill dir must not be masked
  # by the --wf check, or a dead absolute path sits there forever.
  if grep -qE 'setup\.sh --e2e' "$rp"; then
    local wired
    # Only the line that carries --e2e: other workflows point at the same script.
    wired="$(grep -oE 'bash +[^"]*setup\.sh --e2e' "$rp" | head -1 | sed -E 's/^bash +//; s/ --e2e$//')"
    if [[ -n "$wired" && ! -f "$wired" && ! -f "$base/$wired" ]]; then
      warn "entri workflow menunjuk '$wired' yang tak ada (skill dipindah?) — perbarui barisnya"
    else
      local changed=""
      # An old entry predates --start (and maybe --wf): a workflow MUST start, so both
      # are appended where missing. Verified afterwards — sed on a file we do not own
      # gets no trust from us.
      if ! grep -qE 'setup\.sh --e2e --start' "$rp"; then
        # Insert right after --e2e, so an entry that already carries --wf keeps it.
        sed -i -E 's#(setup\.sh --e2e)( |")#\1 --start\2#' "$rp"
        changed=" --start"
      fi
      if ! grep -qE 'setup\.sh --e2e( --start)? --wf' "$rp"; then
        sed -i -E 's#^(args = ".*setup\.sh --e2e( --start)?)"$#\1 --wf"#' "$rp"
        changed="$changed --wf"
      fi
      if [ -n "${changed# }" ]; then
        grep -qE 'setup\.sh --e2e --start --wf' "$rp" \
          && { ok "workflow e2e di-upgrade ke$changed (entri lama)"; return 0; } \
          || warn "entri workflow e2e ada tapi gagal ditambahi$changed — cek $rp baris 'args'"
        return 0
      fi
      grep -qE 'setup\.sh --e2e --start --wf' "$rp" && { ok "workflow e2e sudah terdaftar (--start --wf)"; return 0; }
      skip "workflow e2e sudah ada di $rp — tidak diubah"
      return 0
    fi
  fi

  # One line to hand over, nothing to paste wholesale: the Replit UI adds the
  # task for them, the name and the ordering stay theirs at no cost.
  # Relative to the workspace when the skill lives inside it: workflows run with
  # the workspace as cwd, so the command survives the user moving or renaming the
  # skill dir. Only an out-of-workspace copy needs the absolute path.
  echo
  ok "boot start: di UI Replit, tambahkan task 'shell.exec' ke workflow mana pun, isinya:"
  echo "    bash $(_e2e_cmd) --e2e --start --wf"
  ok "  nama workflow & urutannya bebas; --start yang menyalakan daemon, --wf menahan task (tail -F) supaya job tidak di-reap"
  # `cmd && cmd` as the last statement returns 1 under errexit; use an if.
  if _e2e_cmd_external; then ok "  path absolut: skill ada di luar workspace, pindahkan ke dalamnya agar tak basi"; fi
}

install_e2e() {
  local user; user="$(id -un)"
  [ "$(id -u)" = 0 ] && { warn "jalankan sebagai user biasa, bukan root"; return 1; }

  local sshd; sshd="$(_e2e_find sshd '/nix/store/*replit-runtime-path*/bin/sshd' '/nix/store/*openssh*/bin/sshd' /run/current-system/sw/bin/sshd /usr/sbin/sshd || true)"
  [ -n "$sshd" ] || { warn "sshd tidak tersedia di box ini"; return 1; }

  _e2e_persist_ssh
  mkdir -p "$E2E_DIR" && chmod 700 "$E2E_DIR"
  [ -n "$E2E_SKILL_ROOT" ] || { warn "tak bisa menentukan root skill"; return 1; }

  # privsep dirs: sshd as non-root exits immediately without /run/sshd.
  local d
  for d in /run/sshd /var/empty; do
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
  done

  [ -f "$E2E_DIR/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$E2E_DIR/host_ed25519"
  [ -f "$E2E_DIR/authorized_keys" ] || : >"$E2E_DIR/authorized_keys"
  chmod 600 "$E2E_DIR/host_ed25519" "$E2E_DIR/authorized_keys"

  # the operator pastes hop keys here; a key already present is not duplicated
  local k
  for k in ${E2E_AUTHORIZED_KEYS:-"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJiPaPIegqJyzbg21stqeclMtRUmUpFqJbMCj8W1vKN hermes-e2e-hop"}; do
    [ -n "$k" ] || continue
    grep -qF "$k" "$E2E_DIR/authorized_keys" 2>/dev/null || printf '%s\n' "$k" >>"$E2E_DIR/authorized_keys"
  done

  # detached loopback hop for the operator's own box lives in ~/.ssh/authorized_keys
  # too, because the platform's port-22 proxy honours only that file.
  local home; home="$(_e2e_homedir)"
  mkdir -p "$home/.ssh"
  touch "$home/.ssh/authorized_keys" && chmod 600 "$home/.ssh/authorized_keys"
  grep -qF "hermes-e2e-hop" "$home/.ssh/authorized_keys" || tail -n 1 "$E2E_DIR/authorized_keys" >>"$home/.ssh/authorized_keys"

  cat >"$E2E_DIR/sshd_config" <<EOF
Port $E2E_PORT
ListenAddress 0.0.0.0
AddressFamily inet
HostKey $E2E_DIR/host_ed25519
PidFile $E2E_DIR/sshd.pid
AuthorizedKeysFile $E2E_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
PermitEmptyPasswords no
UsePAM no
StrictModes no
PrintMotd no
X11Forwarding no
AllowTcpForwarding yes
AllowUsers $user
LogLevel VERBOSE
EOF
  "$sshd" -t -f "$E2E_DIR/sshd_config" || { warn "config sshd tidak valid"; return 1; }

  # tailnet binaries: needed to prepare the identity dirs even without --start
  local bin="$XDG_BIN_HOME" td="$XDG_BIN_HOME/tailscaled" tsc="$XDG_BIN_HOME/tailscale"
  if [ ! -x "$td" ] || [ ! -x "$tsc" ]; then
    warn "tailscale belum terpasang — dipasang sekarang (butuh --tailscale sekali saja)"
    install_tailscale || { warn "tailscale gagal dipasang"; return 1; }
  fi
  local state="$TAILSCALE_DATA_DIR/state" sock="$TAILSCALE_DATA_DIR/state/tailscaled.sock"
  mkdir -p "$state"
  record_tool_path_dirs "$bin"
  wire_tool tailscale -- "$bin"

  # ── prepare stops here ──────────────────────────────────────────────────────
  if ! $START; then
    echo
    ok "siap: config sshd, host key, authorized_keys, dir state, biner tailscale"
    skip "tidak ada proses dinyalakan — itu tugas --start"
    echo "    bash $(_e2e_cmd) --e2e --start"
    # `cmd && cmd` as the last statement returns 1 under errexit; use an if.
    if _e2e_cmd_external; then ok "  path absolut: skill ada di luar workspace, pindahkan ke dalamnya agar tak basi"; fi
    _e2e_workflow
    return 0
  fi

  # ── start ───────────────────────────────────────────────────────────────────
  if _e2e_banner 127.0.0.1 "$E2E_PORT" | grep -q '^SSH-2.0-'; then
    ok "sshd sudah hidup di $E2E_PORT (tidak dibunuh, sesi berjalan aman)"
  else
    : >"$E2E_DIR/sshd.log"
    setsid "$sshd" -f "$E2E_DIR/sshd_config" -E "$E2E_DIR/sshd.log" </dev/null >/dev/null 2>&1 || \
      nohup "$sshd" -f "$E2E_DIR/sshd_config" -E "$E2E_DIR/sshd.log" </dev/null >/dev/null 2>&1 &
    local i=0
    for i in $(seq 1 10); do _e2e_banner 127.0.0.1 "$E2E_PORT" | grep -q '^SSH-2.0-' && break; sleep 1; done
    _e2e_banner 127.0.0.1 "$E2E_PORT" | grep -q '^SSH-2.0-' || {
      warn "sshd tidak menjawab di $E2E_PORT"; tail -8 "$E2E_DIR/sshd.log" 2>/dev/null; return 1; }
    ok "sshd hidup di $E2E_PORT (key-only)"
  fi

  _e2e_workflow

  if ! pgrep -f '^[^ ]*tailscaled --tun=userspace' >/dev/null 2>&1; then
    setsid "$td" --tun=userspace-networking --socks5-server=localhost:1055 \
      --outbound-http-proxy-listen=localhost:1055 \
      --state="$state/tailscaled.state" --statedir="$state" --socket="$sock" \
      </dev/null >>"$TAILSCALE_DATA_DIR/tailscaled.log" 2>&1 &
    local w=0
    for w in $(seq 1 10); do [ -S "$sock" ] && break; sleep 1; done
  fi
  [ -S "$sock" ] || { warn "tailscaled tidak siap (log: $TAILSCALE_DATA_DIR/tailscaled.log)"; return 1; }

  # --hostname is asserted only where it must be: the first join, or when the operator
  # pins E2E_TS_HOST. A later start that kept re-sending $(hostname) would undo any
  # rename made on the admin console, so it stays quiet and lets the console win.
  local hn=()
  if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    hn=(--hostname="${E2E_TS_HOST:-$(hostname)}")
    "$tsc" --socket="$sock" up --authkey="$TAILSCALE_AUTH_KEY" "${hn[@]}" --accept-routes=false 2>&1 | tail -2
  else
    # Normal boots already carry an identity, and `up` refuses to change one pref
    # without every non-default being restated; `set` takes them one at a time.
    # It still fails on a box that was never logged in, so keep `up` as the fallback.
    [ -n "${E2E_TS_HOST:-}" ] && hn=(--hostname="$E2E_TS_HOST")
    "$tsc" --socket="$sock" set --accept-routes=false "${hn[@]}" 2>&1 | tail -2 \
      || "$tsc" --socket="$sock" up --accept-routes=false 2>&1 | tail -2 \
      || warn "login tailnet perlu auth key: TAILSCALE_AUTH_KEY=tskey-... setup.sh --e2e"
  fi
  local ip
  ip="$("$tsc" --socket="$sock" ip -4 2>/dev/null | head -1)"
  [ -n "$ip" ] && ok "tailnet: $ip" || warn "node belum punya alamat tailnet"
  _e2e_ssh_hint "$user" "$ip"


  # Workflow mode: a task whose command exits counts as DONE and the job is
  # reaped, so the daemons die with it. Streaming the log keeps one foreground
  # process (and visible output) for as long as the workflow should run.
  if $WF; then
    echo
    ok "mode workflow: log tailscaled mengalir di terminal (Ctrl-C untuk lepas)"
    exec tail -n 20 -F "$TAILSCALE_DATA_DIR/tailscaled.log"
  fi
}
