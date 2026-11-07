# shellcheck shell=bash
# join.sh — the shared join engine for BOTH setups (muse + replit).
# Sourced, never executed. Stage S3 of the shared-setup refactor:
# the steps both join implementations share live here exactly once,
# parameterized by the calling profile (tree dir, port, service user,
# binary paths). Profile-specific wiring (workflow entries, reverse
# loop, session-env content) stays in the profiles.
#
# S3a: sshd render + validate + start. The repl profile adopts it
# here; the muse profile adopts it when its profile is built (S4).

# engine_banner <host> <port> — read one banner line over raw TCP.
engine_banner() {
  local h="$1" p="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/$h/$p; IFS= read -r -t 2 l <&3 && printf '%s' \"\$l\"" 2>/dev/null
}

# engine_sshd_render <dir> <port> <user> — write <dir>/sshd_config.
# The fleet's settled sshd shape: key-only on the join port, sshd-
# injected session environment, no root, liveness probes on.
engine_sshd_render() {
  local dir="$1" port="$2" user="$3"
  cat >"$dir/sshd_config" <<EOF
Port $port
ListenAddress 0.0.0.0
AddressFamily inet
HostKey $dir/host_ed25519
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
PermitEmptyPasswords no
UsePAM no
# Environment sesi disuntik sshd sendiri (~/.ssh/environment), bukan
# lewat rc: sesi login/non-login/`ssh host cmd` membaca rc yang
# berbeda-beda, dan [userenv.shared] hanya sampai ke proses platform.
PermitUserEnvironment yes
StrictModes no
PrintMotd no
X11Forwarding no
AllowTcpForwarding yes
AllowUsers $user
ClientAliveInterval 30
ClientAliveCountMax 3
LogLevel VERBOSE
EOF
}

# engine_sshd_validate <sshd-bin> <dir>
engine_sshd_validate() {
  "$1" -t -f "$2/sshd_config" || { warn "config sshd tidak valid"; return 1; }
}

# engine_sshd_start <sshd-bin> <dir> <port> — start only if the port
# is not already answering with an SSH banner; a live sshd is never
# killed (running sessions are safe).
engine_sshd_start() {
  local sshd="$1" dir="$2" port="$3"
  if engine_banner 127.0.0.1 "$port" | grep -q '^SSH-2.0-'; then
    ok "sshd sudah hidup di $port (tidak dibunuh, sesi berjalan aman)"
    return 0
  fi
  : >"$dir/sshd.log"
  setsid "$sshd" -f "$dir/sshd_config" -E "$dir/sshd.log" </dev/null >/dev/null 2>&1 || \
    nohup "$sshd" -f "$dir/sshd_config" -E "$dir/sshd.log" </dev/null >/dev/null 2>&1 &
  local i=0
  for i in $(seq 1 10); do engine_banner 127.0.0.1 "$port" | grep -q '^SSH-2.0-' && break; sleep 1; done
  engine_banner 127.0.0.1 "$port" | grep -q '^SSH-2.0-' || {
    warn "sshd tidak menjawab di $port"; tail -8 "$dir/sshd.log" 2>/dev/null; return 1; }
  ok "sshd hidup di $port (key-only)"
}
