# shellcheck shell=bash
# join entry (sshd key-only) — lets the operator's box reach this one over the tailnet
# instead of a browser canvas. Runtime story: references/join-bridge.md, proxy/
# port facts: references/exposing-ports.md.
# ─────────────────────────────────────────────────────────────────────────────
# Two container facts drive every path here:
#   * $HOME is WIPED on restart, $REPL_HOME is not. So ~/.ssh itself is made a
#     symlink into $REPL_HOME/.ssh — the operator's own ssh config, keys and
#     known_hosts then survive a reboot, and so do this sshd's host key and
#     authorized_keys (a new host key on every boot is an ssh warning cascade).
#   * an autostart line in a shell rc re-fires every time a terminal opens. The
#     daemon is therefore published as a `.replit` [workflows] entry, which runs
#     once per boot and is start/stop-able from the UI.
# One mode only: join. This script always ends with sshd + tailscaled running and the
# node joined; there is no prepare-then-exit branch. `setup.sh --tailscale` (binaries
# only, no join) does not reach this file at all. `--wf` is the workflow variant: same
# thing, but the log streams and the process stays in the foreground.
# The tailnet auth key is NEVER baked in: export TAILSCALE_AUTH_KEY for the first
# start, afterwards the stored node identity carries the login on its own.
# ─────────────────────────────────────────────────────────────────────────────

: "${RS_PORT:=6800}"
RS_DIR="${RS_DIR:-${REPL_HOME:-$HOME/workspace}/.ssh/e2e-sshd}"
RS_SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-}")/../.." 2>/dev/null && pwd)"

__rs_homedir() { getent passwd "$(id -un)" | cut -d: -f6; }

# The command a user pastes/runs. Relative to the workspace whenever the skill lives
# inside it: workflows run with the workspace as cwd, so moving or renaming the skill
# dir cannot leave a dead absolute path behind. Only an outside copy needs the absolute
# one, and then the caller says so.
__rs_cmd() {
  local base="${REPL_HOME:-$HOME/workspace}" cmd="$RS_SKILL_ROOT/scripts/setup.sh"
  [[ "$cmd" == "$base"/* ]] && cmd="${cmd#"$base"/}"
  printf '%s\n' "$cmd"
}
__rs_cmd_external() { [[ "$(__rs_cmd)" == /* ]]; }

# sshd/ssh live in different PATH entries per shell; probe absolute candidates.
__rs_find() {
  local n="$1"; shift
  command -v "$n" 2>/dev/null && return 0
  local g p
  for g in "$@"; do for p in $g; do [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }; done; done
  return 1
}

__rs_banner() {
  local h="$1" p="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/$h/$p; IFS= read -r -t 2 l <&3 && printf '%s' \"\$l\"" 2>/dev/null
}

# Client-side hop. `nc` is not portable: netcat-openbsd has -X/-x, but
# netcat-traditional and busybox nc reject -X ("invalid option -- 'X'"). Print
# every form, best first, so the operator never has to guess which nc they own.
__rs_ssh_hint() {
  local u="$1" ip="$2" h="${2:-<ip-tailnet>}"
  echo "  dari mesin lain (pilih yang ada di klien itu):"
  echo "    tailscale (socket default): ssh -o ProxyCommand='tailscale nc %h %p' -p $RS_PORT $u@$h"
  echo "    tailscale userspace:        ssh -o ProxyCommand='tailscale --socket=<sock tailscaled klien> nc %h %p' -p $RS_PORT $u@$h"
  echo "    ncat:                       ssh -o ProxyCommand='ncat --proxy 127.0.0.1:1055 --proxy-type socks5 %h %p' -p $RS_PORT $u@$h"
  echo "    netcat-openbsd:             ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:1055 %h %p' -p $RS_PORT $u@$h"
  echo "    busybox/traditional nc tidak punya -X → pakai tailscale atau ncat"
  [ -n "$ip" ] || echo "    alamat tailnet belum ada: isi TAILSCALE_AUTH_KEY lalu jalankan ulang"
}

# ~/.ssh -> persistent. Runs before anything writes a key, so an existing
# hand-installed ~/.ssh is moved into the persistent dir instead of discarded.
__rs_persist_ssh() {
  local home; home="$(__rs_homedir)"
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
# ordering. Appending a block steals a name (a second `name = "join"` collides
# with one they already use) and rewrites a file we do not own.
__rs_workflow() {
  local rp="${REPL_HOME:-$HOME/workspace}/.replit"
  [ -f "$rp" ] || { warn ".replit tidak ada — workflow autostart dilewati"; return 0; }
  local base="${REPL_HOME:-$HOME/workspace}"

  # Already wired? Then only two things matter: does the command it points at still
  # exist, and does it carry --wf. Path first — a moved skill dir must not be masked
  # by the --wf check, or a dead absolute path sits there forever.
  if grep -qE 'setup\.sh --join' "$rp"; then
    local wired
    # Only the line that carries --join: other workflows point at the same script.
    wired="$(grep -oE 'bash +[^"]*setup\.sh --join' "$rp" | head -1 | sed -E 's/^bash +//; s/ --join$//')"
    if [[ -n "$wired" && ! -f "$wired" && ! -f "$base/$wired" ]]; then
      warn "entri workflow menunjuk '$wired' yang tak ada (skill dipindah?) — perbarui barisnya"
    else
      local changed=""
      # Pin the node name on the args line (and keep it in step on a rename): the
      # workflow is what rejoins the box, so the name has to travel with it. Only
      # when the operator pinned one — an unpinned box lets the console win.
      if [ -n "${TAILSCALE_NODE_NAME:-}" ]; then
        local pinned
        pinned="$(grep -oE '^args = "TAILSCALE_NODE_NAME=[^ ]+' "$rp" | head -1 | sed 's/.*=//')"
        if [ "$pinned" != "$TAILSCALE_NODE_NAME" ]; then
          if [ -n "$pinned" ]; then
            sed -i -E "s#^args = \"TAILSCALE_NODE_NAME=$pinned #args = \"TAILSCALE_NODE_NAME=$TAILSCALE_NODE_NAME #" "$rp"
            changed="$changed nama-node"
          else
            sed -i -E "s#^args = \"(bash [^\"]*setup\.sh --join)#args = \"TAILSCALE_NODE_NAME=$TAILSCALE_NODE_NAME \1#" "$rp"
            changed="$changed nama-node"
          fi
          grep -qE "^args = \"TAILSCALE_NODE_NAME=$TAILSCALE_NODE_NAME " "$rp" \
            && ok "nama node dipin di args workflow: $TAILSCALE_NODE_NAME" \
            || warn "gagal mem-pin TAILSCALE_NODE_NAME di $rp"
        fi
      fi
      # --join implies the start; only --wf can still be missing (an entry wired before
      # that modifier existed). Verified afterwards — sed on a file we do not own gets
      # no trust from us.
      if ! grep -qE 'setup\.sh --join --wf' "$rp"; then
        sed -i -E 's#^(args = ".*setup\.sh --join\b[^"]*)"$#\1 --wf"#' "$rp"
        changed="--wf"
      fi
      if [ -n "${changed# }" ]; then
        grep -qE 'setup\.sh --join --wf' "$rp" \
          && { ok "workflow join di-upgrade ke $changed (entri lama)"; return 0; } \
          || warn "entri workflow join ada tapi gagal ditambahi $changed — cek $rp baris 'args'"
        return 0
      fi
      grep -qE 'setup\.sh --join --wf' "$rp" && { ok "workflow join sudah terdaftar (--wf)"; return 0; }
      skip "workflow join sudah ada di $rp — tidak diubah"
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
  echo "    bash $(__rs_cmd) --tailscale --join --wf"
  ok "  nama workflow & urutannya bebas; --join yang menyalakan daemon, --wf menahan task (tail -F) supaya job tidak di-reap"
  # `cmd && cmd` as the last statement returns 1 under errexit; use an if.
  if __rs_cmd_external; then ok "  path absolut: skill ada di luar workspace, pindahkan ke dalamnya agar tak basi"; fi
}

install_join() {
  local user; user="$(id -un)"
  [ "$(id -u)" = 0 ] && { warn "jalankan sebagai user biasa, bukan root"; return 1; }

  local sshd; sshd="$(__rs_find sshd '/nix/store/*replit-runtime-path*/bin/sshd' '/nix/store/*openssh*/bin/sshd' /run/current-system/sw/bin/sshd /usr/sbin/sshd || true)"
  [ -n "$sshd" ] || { warn "sshd tidak tersedia di box ini"; return 1; }

  __rs_persist_ssh
  mkdir -p "$RS_DIR" && chmod 700 "$RS_DIR"
  [ -n "$RS_SKILL_ROOT" ] || { warn "tak bisa menentukan root skill"; return 1; }

  # privsep dirs: sshd as non-root exits immediately without /run/sshd.
  local d
  for d in /run/sshd /var/empty; do
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
  done

  [ -f "$RS_DIR/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$RS_DIR/host_ed25519"
  [ -f "$RS_DIR/authorized_keys" ] || : >"$RS_DIR/authorized_keys"
  chmod 600 "$RS_DIR/host_ed25519" "$RS_DIR/authorized_keys"

  # the operator pastes hop keys here; a key already present is not duplicated
  local k
  for k in ${RS_AUTHORIZED_KEYS:-"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJiPaPIegqJyzbg21stqeclMtRUmUpFqJbMCj8W1vKN hermes-e2e-hop"}; do
    [ -n "$k" ] || continue
    grep -qF "$k" "$RS_DIR/authorized_keys" 2>/dev/null || printf '%s\n' "$k" >>"$RS_DIR/authorized_keys"
  done

  # detached loopback hop for the operator's own box lives in ~/.ssh/authorized_keys
  # too, because the platform's port-22 proxy honours only that file.
  local home; home="$(__rs_homedir)"
  mkdir -p "$home/.ssh"
  touch "$home/.ssh/authorized_keys" && chmod 600 "$home/.ssh/authorized_keys"
  grep -qF "hermes-e2e-hop" "$home/.ssh/authorized_keys" || tail -n 1 "$RS_DIR/authorized_keys" >>"$home/.ssh/authorized_keys"

  cat >"$RS_DIR/sshd_config" <<EOF
Port $RS_PORT
ListenAddress 0.0.0.0
AddressFamily inet
HostKey $RS_DIR/host_ed25519
PidFile $RS_DIR/sshd.pid
AuthorizedKeysFile $RS_DIR/authorized_keys
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
  "$sshd" -t -f "$RS_DIR/sshd_config" || { warn "config sshd tidak valid"; return 1; }

  # tailnet binaries: needed to prepare the identity dirs even without joining the tailnet
  local bin="$XDG_BIN_HOME" td="$XDG_BIN_HOME/tailscaled" tsc="$XDG_BIN_HOME/tailscale"
  if [ ! -x "$td" ] || [ ! -x "$tsc" ]; then
    warn "tailscale belum terpasang — dipasang sekarang (butuh --tailscale sekali saja)"
    install_tailscale || { warn "tailscale gagal dipasang"; return 1; }
  fi
  # Paths come from the environment (registered by install_tailscale and --fix),
  # never re-spelled here: one definition, no drift, and no absolute copy in a script.
  local state="$TAILSCALE_STATE_DIR" sock="$TAILSCALE_SOCKET"
  mkdir -p "$state"
  record_tool_path_dirs "$bin"
  wire_tool tailscale -- "$bin"

  # ── start ───────────────────────────────────────────────────────────────────
  if __rs_banner 127.0.0.1 "$RS_PORT" | grep -q '^SSH-2.0-'; then
    ok "sshd sudah hidup di $RS_PORT (tidak dibunuh, sesi berjalan aman)"
  else
    : >"$RS_DIR/sshd.log"
    setsid "$sshd" -f "$RS_DIR/sshd_config" -E "$RS_DIR/sshd.log" </dev/null >/dev/null 2>&1 || \
      nohup "$sshd" -f "$RS_DIR/sshd_config" -E "$RS_DIR/sshd.log" </dev/null >/dev/null 2>&1 &
    local i=0
    for i in $(seq 1 10); do __rs_banner 127.0.0.1 "$RS_PORT" | grep -q '^SSH-2.0-' && break; sleep 1; done
    __rs_banner 127.0.0.1 "$RS_PORT" | grep -q '^SSH-2.0-' || {
      warn "sshd tidak menjawab di $RS_PORT"; tail -8 "$RS_DIR/sshd.log" 2>/dev/null; return 1; }
    ok "sshd hidup di $RS_PORT (key-only)"
  fi

  __rs_workflow

  # Liveness is the socket answering, not a pid guess: a SECOND daemon on another
  # socket (a test node, a second tailnet) matches the pattern and would otherwise
  # suppress the start and leave this socket dead.
  if ! "$tsc" --socket="$sock" status >/dev/null 2>&1; then
    setsid "$td" --tun=userspace-networking --socks5-server=localhost:1055 \
      --outbound-http-proxy-listen=localhost:1055 \
      --state="$state/tailscaled.state" --statedir="$state" --socket="$sock" \
      </dev/null >>"$TAILSCALE_DATA_DIR/tailscaled.log" 2>&1 &
    local w=0
    for w in $(seq 1 10); do [ -S "$sock" ] && break; sleep 1; done
  fi
  [ -S "$sock" ] || { warn "tailscaled tidak siap (log: $TAILSCALE_DATA_DIR/tailscaled.log)"; return 1; }

  # --hostname is asserted only where it must be: the first join, or when the operator
  # pins TAILSCALE_NODE_NAME. A later start that kept re-sending $(hostname) would undo any
  # rename made on the admin console, so it stays quiet and lets the console win.
  local hn=()
  if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    hn=(--hostname="${TAILSCALE_NODE_NAME:-$(hostname)}")
    # The key itself never needs printing twice; mask it in the echoed command line.
    "$tsc" --socket="$sock" up --authkey="$TAILSCALE_AUTH_KEY" "${hn[@]}" --accept-routes=false 2>&1 \
      | sed -E 's/(tskey-)[A-Za-z0-9_-]+/\1***/g' | tail -2
  else
    # Normal boots already carry an identity, and `up` refuses to change one pref
    # without every non-default being restated; `set` takes them one at a time.
    # It still fails on a box that was never logged in, so keep `up` as the fallback.
    [ -n "${TAILSCALE_NODE_NAME:-}" ] && hn=(--hostname="$TAILSCALE_NODE_NAME")
    "$tsc" --socket="$sock" set --accept-routes=false "${hn[@]}" 2>&1 | tail -2 \
      || "$tsc" --socket="$sock" up --accept-routes=false 2>&1 | tail -2 \
      || warn "login tailnet perlu auth key: TAILSCALE_AUTH_KEY=tskey-... setup.sh --tailscale --join"
  fi
  local ip
  ip="$("$tsc" --socket="$sock" ip -4 2>/dev/null | head -1)"
  [ -n "$ip" ] && ok "tailnet: $ip" || warn "node belum punya alamat tailnet"
  __rs_ssh_hint "$user" "$ip"


  # Workflow mode: a task whose command exits counts as DONE and the job is
  # reaped, so the daemons die with it. Streaming the log keeps one foreground
  # process (and visible output) for as long as the workflow should run.
  if $WF; then
    echo
    ok "mode workflow: log tailscaled mengalir di terminal (Ctrl-C untuk lepas)"
    exec tail -n 20 -F "$TAILSCALE_DATA_DIR/tailscaled.log"
  fi
}
