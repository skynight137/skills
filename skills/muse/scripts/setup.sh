#!/usr/bin/env bash
# setup.sh — stand up the remote-access stack on a FRESH Muse VM
# (the muse-test pattern: a second Muse instance you can redeploy freely
# and use as an end-to-end join target, the way repl-test serves Replit).
#
# What it installs (all inside the persistent tree, Replit-shaped layout):
#   <ws>/.ssh/                  canonical ssh store + sshd stack + scripts
#   <ws>/.ssh/reverse/          reverse-tunnel loops + health probe
#   <ws>/.local/bin/            tailscale / tailscaled (XDG bin)
#   <ws>/.local/share/tailscale daemon state/socket/log (XDG data)
#   <ws>/config/env.sh          shared env (XDG vars, MUSE_HOME, secrets)
#   ~/.ssh, /root/.ssh          symlinks -> <ws>/.ssh
#
# Usage (mirrors the replit setup's shape: phase flags + an interactive
# menu, instead of one monolith that beelines to the join):
#   bash setup.sh                     full setup; on a TTY, opens the menu
#   bash setup.sh --menu              interactive phase picker (arrow keys)
#   bash setup.sh --sshd              sshd stack only (users, openssh, keys,
#                                     launchers, reverse scripts)
#   bash setup.sh --tailscale         tailscale binaries + node launcher only
#   bash setup.sh -j | --join         start the stack and join the tailnet
#                                     (implies --sshd/--tailscale when their
#                                     outputs are missing)
#   bash setup.sh --verify            read-only status
#   bash setup.sh [--peer <ip>] ...   peer = reverse-forward holder
#   bash setup.sh [--user <name>] ... stack service user: the user the join
#                                     sshd runs as and accepts logins for,
#                                     and the tailscaled run-user. Env
#                                     RS_SSH_USER sets it too; the flag
#                                     wins. Default: root (setup prints a
#                                     warning — root sessions can read the
#                                     stack .env and client key). The
#                                     fleet-proven isolated choice is
#                                     --user runner. The choice is baked
#                                     into the generated launchers, so
#                                     restores keep it with no env vars.
#
# Secrets never live in this repo: the operator creates <ws>/.ssh/.env
# (mode 600) with TAILSCALE_AUTH_KEY=<key for the tailnet> — setup writes
# a template and stops short of the join while the key is empty.
# The peer (default 100.106.114.30 = repl-test) is the machine that will
# hold the reverse forwards; its public key must be added to
# <ws>/.ssh/join-tailnet/authorized_keys and this VM's client pubkey
# (<ws>/.ssh/id_ed25519.pub, printed at the end) to the peer's sshd.
set -euo pipefail

PEER=100.106.114.30 VERIFY=0
SSH_USER="${RS_SSH_USER:-root}"
DO_SSHD=0 DO_TAILSCALE=0 DO_JOIN=0 DO_MENU=0 SELECTED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer) PEER=$2; shift 2 ;;
    --user) SSH_USER=$2; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    --sshd) DO_SSHD=1; SELECTED=1; shift ;;
    --tailscale) DO_TAILSCALE=1; SELECTED=1; shift ;;
    -j|--join) DO_JOIN=1; SELECTED=1; shift ;;
    --menu) DO_MENU=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
WS="$HOME/workspace"
SSHDIR="$WS/.ssh"
BINDIR="$WS/.local/bin"
TSDIR="$WS/.local/share/tailscale"
REVDIR="$SSHDIR/reverse"
TSVER=1.104.4
CLEANENV=(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy)

say() { printf '\n== %s ==\n' "$*"; }

# ── Stack service user (--user / RS_SSH_USER; flag wins; default root) ──
# Governs THIS box's stack identity only: the join sshd's run/login user,
# the service home, the tailscaled run-user, and where the sshd-injected
# session-environment file lives. Peer-side literals (runner@<peer>,
# User runner in the peer configs) are the PEER's platform user and are
# deliberately NOT parameterized.
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "invalid --user value: $SSH_USER" >&2; exit 2; }
if [[ "$SSH_USER" == root ]]; then
  SVC_HOME=/root
  SVC_PERMIT_ROOT_LOGIN=prohibit-password
  # Root's passwd home is /root (ephemeral), but /root/.ssh is a symlink
  # into $SSHDIR, so the environment file sshd reads for root physically
  # persists at $SSHDIR/environment.
  SVC_ENV_FILE="$SSHDIR/environment"
else
  SVC_HOME="$SSHDIR/home"
  SVC_PERMIT_ROOT_LOGIN=no
  SVC_ENV_FILE="$SVC_HOME/.ssh/environment"
fi
# Run a command as the service user (directly when it is root: setup and
# the generated launchers already run as root).
svc_run() {
  if [[ "$SSH_USER" == root ]]; then "$@"; else runuser -u "$SSH_USER" -- "$@"; fi
}

say "stack service user: $SSH_USER (service home: $SVC_HOME)"
if [[ "$SSH_USER" == root ]]; then
  cat <<'WARN'
WARNING: the stack service user is root. SSH sessions will land as root
and can read the stack .env (the tailnet auth key) and the client
private key in the ssh store. The fleet-proven isolated setup is
--user runner; choose root only when you accept that exposure.
WARN
fi

if [[ $VERIFY -eq 1 ]]; then
  say "verify"
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6800; IFS= read -r -t 1 l <&3; echo "sshd: $l"' 2>/dev/null || echo "sshd: DOWN"
  NODE_STATUS="$(svc_run "${CLEANENV[@]}" "$BINDIR/tailscale" --socket="$TSDIR/tailscaled.sock" status 2>&1 | head -2)"
  [[ -n "$NODE_STATUS" ]] && printf '%s
' "$NODE_STATUS" || echo "node: DOWN"
  echo "reverse forwards (probe runs from the peer): bash $REVDIR/check-reverse.sh"
  exit 0
fi

phase_sshd() {
say "layout + users"
chmod o+x "$HOME" "$WS"
mkdir -p "$SSHDIR/join-tailnet" "$SSHDIR/bin" "$REVDIR" "$BINDIR" "$TSDIR/state" "$WS/config"
chmod o+x "$WS/.local" "$WS/.local/share" "$SSHDIR"
# sshd runs as the service user and must write its log + pid inside
# join-tailnet, read its host key and authorized_keys, and land in a
# home it owns. Pin the end state here AND in start-sshd.sh (below):
# without this, both test boxes needed manual permission surgery before
# sshd would start.
chmod 777 "$SSHDIR/join-tailnet"
if [[ "$SSH_USER" != root ]]; then
  mkdir -p "$SVC_HOME"
  chown "$SSH_USER:$SSH_USER" "$SVC_HOME" 2>/dev/null || true; chmod 755 "$SVC_HOME"
  id "$SSH_USER" >/dev/null 2>&1 || useradd -d "$SVC_HOME" -s /bin/bash "$SSH_USER"
fi
getent passwd sshd >/dev/null 2>&1 || useradd -r -d /run/sshd -s /usr/sbin/nologin sshd
mkdir -p /run/sshd && chmod 755 /run/sshd

say "openssh (extracted .deb — no package install, nothing in /usr/bin)"
if ! command -v sshd >/dev/null && [[ ! -x "$SSHDIR/rootfs/usr/sbin/sshd" ]]; then
  DEB=/tmp/openssh-server.deb
  curl -fsSL -o "$DEB" "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/openssh-server_9.6p1-3ubuntu13.20_amd64.deb"
  mkdir -p "$SSHDIR/rootfs"
  dpkg -x "$DEB" "$SSHDIR/rootfs"
  rm -f "$DEB"
fi
[[ -x "$SSHDIR/rootfs/usr/sbin/sshd" ]] && ln -sf "$SSHDIR/rootfs/usr/sbin/sshd" "$SSHDIR/bin/sshd"

say "sshd stack"
[[ -f "$SSHDIR/join-tailnet/ssh_host_ed25519_key" ]] || \
  ssh-keygen -t ed25519 -f "$SSHDIR/join-tailnet/ssh_host_ed25519_key" -N '' >/dev/null
if [[ "$SSH_USER" == root ]]; then
  chown root:root "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true
  chmod 600 "$SSHDIR/join-tailnet/ssh_host_ed25519_key"
else
  # Group read lets the non-root sshd (running as the service user) open it.
  chown "root:$SSH_USER" "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true
  chmod 640 "$SSHDIR/join-tailnet/ssh_host_ed25519_key"
fi
touch "$SSHDIR/join-tailnet/authorized_keys"; chmod 600 "$SSHDIR/join-tailnet/authorized_keys"
# Default trust: the fleet hop (mirrors the replit skill's hermes-join-hop).
# Every box stood up with this setup authorizes the muse-hop key —
# the operator's main Muse VM — from birth, so onboarding never needs a
# per-machine key exchange; the hop reaches every fleet box directly and
# any-to-any goes through it (star, not mesh: one distributed pubkey).
# The hop's private key never leaves the hop machine. Override by setting
# RS_AUTHORIZED_KEYS (one pubkey per line) in the .env before running.
HOP_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtOrYNU7XhUsf+6dygX5j9xdDlT7hId3NO7gwi8GhBq muse-hop"
seed_key() { grep -q " $2 " "$SSHDIR/join-tailnet/authorized_keys" 2>/dev/null || echo "$1" >> "$SSHDIR/join-tailnet/authorized_keys"; }
if [[ -n "${RS_AUTHORIZED_KEYS:-}" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && seed_key "$line" "$(echo "$line" | awk '{print $2}')"
  done <<< "$RS_AUTHORIZED_KEYS"
else
  seed_key "$HOP_KEY" "$(echo "$HOP_KEY" | awk '{print $2}')"
fi
chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/authorized_keys" 2>/dev/null || true
chmod 600 "$SSHDIR/join-tailnet/authorized_keys"
cat > "$SSHDIR/join-tailnet/sshd_config" <<EOF
Port 6800
ListenAddress 0.0.0.0
Protocol 2
HostKey $SSHDIR/join-tailnet/ssh_host_ed25519_key
PidFile $SSHDIR/join-tailnet/sshd.pid
AuthorizedKeysFile $SSHDIR/join-tailnet/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
# StrictModes off is load-bearing on this platform: the idmapped home
# mount forces group/world-writable modes on the persistent tree (the
# proven live stack runs home at 777), and StrictModes would refuse
# every authorized_keys for exactly that. Key-only auth stays on.
StrictModes no
ChallengeResponseAuthentication no
PermitRootLogin $SVC_PERMIT_ROOT_LOGIN
AllowUsers $SSH_USER
UsePAM no
# Session environment comes from sshd itself (~/.ssh/environment in the
# service home), not from shell rc: login, non-login and `ssh host cmd`
# sessions each source different rc files (or none), which is why the
# shared-env vars kept vanishing in ssh sessions.
PermitUserEnvironment yes
PermitTunnel no
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 30
ClientAliveCountMax 3
Subsystem sftp $SSHDIR/rootfs/usr/lib/openssh/sftp-server
EOF
chown "$SSH_USER:$SSH_USER" "$SSHDIR/join-tailnet/sshd_config" 2>/dev/null || true; chmod 600 "$SSHDIR/join-tailnet/sshd_config" 2>/dev/null || true
[[ -f "$SSHDIR/id_ed25519" ]] || ssh-keygen -t ed25519 -f "$SSHDIR/id_ed25519" -N '' >/dev/null
[[ -e "$HOME/.ssh" ]] || ln -s "$SSHDIR" "$HOME/.ssh"
if [[ "$(readlink /root/.ssh 2>/dev/null)" != "$SSHDIR" ]]; then rm -rf /root/.ssh; ln -s "$SSHDIR" /root/.ssh; fi

say "shared env (config/env.sh) + .env template"
cat > "$WS/config/env.sh" <<'EOF'
# Shared environment for this VM — non-secret config only.
export XDG_DATA_HOME="$HOME/workspace/.local/share"
export XDG_CONFIG_HOME="$HOME/workspace/.config"
export XDG_CACHE_HOME="$HOME/workspace/.cache"
export XDG_STATE_HOME="$HOME/workspace/.local/state"
# Toolchain anchor: the persistent target path (parity with REPL_HOME).
export MUSE_HOME="$HOME/workspace"
case ":$PATH:" in
  *":$HOME/workspace/.local/bin:"*) ;;
  *) export PATH="$HOME/workspace/.local/bin:$HOME/workspace/.ssh/bin:$PATH" ;;
esac
if [ -r "$HOME/workspace/.ssh/.env" ]; then
  set -a; . "$HOME/workspace/.ssh/.env"; set +a
fi
EOF
chmod 644 "$WS/config/env.sh"
if ! grep -q "muse shared env" "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# >>> muse shared env >>>
[ -f "$HOME/workspace/config/env.sh" ] && . "$HOME/workspace/config/env.sh"
# <<< muse shared env <<<
EOF
fi
if [[ ! -f "$SSHDIR/.env" ]]; then
  cat > "$SSHDIR/.env" <<EOF
TAILSCALE_AUTH_KEY=
TAILSCALE_NODE_NAME=muse-join
RS_SSH_USER=$SSH_USER
# (the stack service user chosen at install time; setup's --user flag overrides it)
#RS_AUTHORIZED_KEYS= (optional override: pubkeys to authorize instead of the muse-hop default)
#RS_REVERSE_PEER= (HOP ONLY: peer IP that receives this box's reverse forward. Leaves leave
#  this unset — a leaf runs NO reverse loop; only the fleet hop opens one, to the repl hop.)
#RS_REVERSE_PORT=16801 (forward port on the peer when RS_REVERSE_PEER is set;
# "auto" = claim the first free port in 16801-16899 on the peer at first run and pin it here)
EOF
  chmod 600 "$SSHDIR/.env"
  echo "created $SSHDIR/.env — fill TAILSCALE_AUTH_KEY (600, never commit it), then re-run this script"
fi

say "session environment (sshd-injected, not rc)"
# sshd reads ~/.ssh/environment under the service user's passwd home:
# $SVC_HOME/.ssh/environment — which for root is the file $SVC_ENV_FILE
# ($SSHDIR/environment, reached through the /root/.ssh symlink).
if [[ "$SSH_USER" != root ]]; then mkdir -p "$SVC_HOME/.ssh"; fi
cat > "$SVC_ENV_FILE" <<EOF
MUSE_HOME=$WS
XDG_DATA_HOME=$WS/.local/share
XDG_CONFIG_HOME=$WS/.config
XDG_CACHE_HOME=$WS/.cache
XDG_STATE_HOME=$WS/.local/state
PATH=$WS/.local/bin:$WS/.ssh/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BASH_ENV=$WS/config/env.sh
EOF
if [[ "$SSH_USER" != root ]]; then
  chown -R "$SSH_USER:$SSH_USER" "$SVC_HOME/.ssh" 2>/dev/null || true
  chmod 700 "$SVC_HOME/.ssh"
fi
chmod 600 "$SVC_ENV_FILE"
# Landing: interactive sessions start in the workspace. The working
# directory is a shell concern (sshd cannot set it); the vars above no
# longer depend on rc at all — this block only handles the landing.
if ! grep -q "muse landing" "$SVC_HOME/.bashrc" 2>/dev/null; then
  cat >> "$SVC_HOME/.bashrc" <<'RCEOF'

# >>> muse landing >>>
case $- in *i*) [[ "$PWD" == "$HOME" ]] && cd "${MUSE_HOME:-$HOME/workspace}" ;; esac
# <<< muse landing <<<
RCEOF
fi
cat > "$SVC_HOME/.bash_profile" <<'EOF'
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
chown "$SSH_USER:$SSH_USER" "$SVC_HOME/.bashrc" "$SVC_HOME/.bash_profile" 2>/dev/null || true

say "launcher: start-sshd.sh (service user $SSH_USER baked in)"
# Generated in chunks so the service user is baked in at generation
# time: restores keep the install-time choice with no env vars, and
# root mode gets a file with no runuser wrappers and no service-user
# useradd at all. In runner mode the output is byte-identical to the
# historical single-heredoc version.
cat > "$SSHDIR/start-sshd.sh" <<EOS
#!/usr/bin/env bash
# (Re)start the join sshd as \`$SSH_USER\` on 6800. Run as root after a redeploy:
# /etc/passwd + /run + /root/.ssh are ephemeral; everything else persists.
set -euo pipefail
SSHDIR="\$HOME/workspace/.ssh"
if [[ "\$(readlink /root/.ssh 2>/dev/null)" != "\$SSHDIR" ]]; then rm -rf /root/.ssh; ln -s "\$SSHDIR" /root/.ssh; fi
chmod o+x "\$HOME" "\$HOME/workspace"
EOS
if [[ "$SSH_USER" != root ]]; then
  cat >> "$SSHDIR/start-sshd.sh" <<EOS
id $SSH_USER >/dev/null 2>&1 || useradd -d "\$SSHDIR/home" -s /bin/bash $SSH_USER
EOS
fi
cat >> "$SSHDIR/start-sshd.sh" <<'EOS'
getent passwd sshd >/dev/null 2>&1 || useradd -r -d /run/sshd -s /usr/sbin/nologin sshd
mkdir -p /run/sshd && chmod 755 /run/sshd
chmod 777 "$SSHDIR/join-tailnet"
EOS
if [[ "$SSH_USER" != root ]]; then
  cat >> "$SSHDIR/start-sshd.sh" <<EOS
chown $SSH_USER:$SSH_USER "\$SSHDIR/home" 2>/dev/null || true; chmod 755 "\$SSHDIR/home"
chown root:$SSH_USER "\$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true; chmod 640 "\$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true
EOS
else
  cat >> "$SSHDIR/start-sshd.sh" <<'EOS'
chown root:root "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true; chmod 600 "$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || true
EOS
fi
cat >> "$SSHDIR/start-sshd.sh" <<EOS
chown $SSH_USER:$SSH_USER "\$SSHDIR/join-tailnet/authorized_keys" 2>/dev/null || true; chmod 600 "\$SSHDIR/join-tailnet/authorized_keys" 2>/dev/null || true
chown $SSH_USER:$SSH_USER "\$SSHDIR/join-tailnet/sshd_config" 2>/dev/null || true; chmod 600 "\$SSHDIR/join-tailnet/sshd_config" 2>/dev/null || true
EOS
if [[ "$SSH_USER" != root ]]; then
  cat >> "$SSHDIR/start-sshd.sh" <<EOS
chown $SSH_USER:$SSH_USER "\$SSHDIR/home/.ssh/environment" 2>/dev/null || true; chmod 600 "\$SSHDIR/home/.ssh/environment" 2>/dev/null || true
runuser -u $SSH_USER -- test -r "\$SSHDIR/join-tailnet/ssh_host_ed25519_key" 2>/dev/null || { chown $SSH_USER:$SSH_USER "\$SSHDIR/join-tailnet/ssh_host_ed25519_key"; chmod 600 "\$SSHDIR/join-tailnet/ssh_host_ed25519_key"; }
EOS
else
  cat >> "$SSHDIR/start-sshd.sh" <<'EOS'
chown root:root "$SSHDIR/environment" 2>/dev/null || true; chmod 600 "$SSHDIR/environment" 2>/dev/null || true
EOS
fi
cat >> "$SSHDIR/start-sshd.sh" <<'EOS'
if [[ -f "$SSHDIR/join-tailnet/sshd.pid" ]] && kill -0 "$(cat "$SSHDIR/join-tailnet/sshd.pid")" 2>/dev/null; then
  echo "sshd already running"; exit 0
fi
EOS
if [[ "$SSH_USER" != root ]]; then
  cat >> "$SSHDIR/start-sshd.sh" <<EOS
runuser -u $SSH_USER -- bash -c \\
  "setsid \$SSHDIR/rootfs/usr/sbin/sshd -f \$SSHDIR/join-tailnet/sshd_config -E \$SSHDIR/join-tailnet/sshd.log </dev/null >/dev/null 2>&1 & disown"
EOS
else
  cat >> "$SSHDIR/start-sshd.sh" <<'EOS'
bash -c \
  "setsid $SSHDIR/rootfs/usr/sbin/sshd -f $SSHDIR/join-tailnet/sshd_config -E $SSHDIR/join-tailnet/sshd.log </dev/null >/dev/null 2>&1 & disown"
EOS
fi
cat >> "$SSHDIR/start-sshd.sh" <<'EOS'
for _ in $(seq 1 10); do
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6800; IFS= read -r -t 1 l <&3; echo "$l"' 2>/dev/null && break
  sleep 1
done
EOS
chmod +x "$SSHDIR/start-sshd.sh"

say "launchers: reverse loops + probe (peer $PEER)"
cat > "$REVDIR/ts_proxy_connect.py" <<'EOF'
#!/usr/bin/env python3
"""ProxyCommand helper: CONNECT through the runtime tunnel proxy (port 3130).

Usage: ts_proxy_connect.py <host> <port>
Reads HTTPS_PROXY from the environment, swaps its port to 3130, issues an
HTTP CONNECT for host:port, then shuttles bytes between the tunnel socket
and stdin/stdout (the ssh ProxyCommand contract).
"""
import base64
import os
import select
import socket
import sys
from urllib.parse import urlparse


def main() -> int:
    host, port = sys.argv[1], int(sys.argv[2])
    proxy = urlparse(os.environ["HTTPS_PROXY"])
    tunnel = f"{proxy.scheme}://{proxy.hostname}:3130"
    p = urlparse(tunnel)
    auth = ""
    if proxy.username:
        creds = proxy.username + ((":" + proxy.password) if proxy.password else "")
        auth = "Proxy-Authorization: Basic " + base64.b64encode(creds.encode()).decode() + "\r\n"
    s = socket.create_connection((p.hostname, 3130), timeout=30)
    target = f"{host}:{port}"
    s.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n{auth}\r\n".encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            sys.stderr.write(f"proxy closed before CONNECT reply for {target}\n")
            return 1
        resp += chunk
    status = resp.split(b"\r\n", 1)[0].decode(errors="replace")
    if " 200 " not in status:
        sys.stderr.write(f"CONNECT {target} -> {status}\n")
        return 1
    # Any bytes after the header belong to the tunnel stream.
    head, _, rest = resp.partition(b"\r\n\r\n")
    s.setblocking(False)
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    fds = [s, stdin]
    pending = rest
    while True:
        if pending:
            stdout.write(pending)
            stdout.flush()
            pending = b""
        r, _, _ = select.select(fds, [], [], 60)
        if not r:
            return 0
        for fd in r:
            if fd is s:
                data = s.recv(65536)
                if not data:
                    return 0
                stdout.write(data)
                stdout.flush()
            else:
                data = stdin.read1(65536) if hasattr(stdin, "read1") else stdin.read(65536)
                if not data:
                    try:
                        s.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    fds.remove(stdin)
                else:
                    s.sendall(data)


if __name__ == "__main__":
    sys.exit(main())
EOF
chmod +x "$REVDIR/ts_proxy_connect.py"
cat > "$REVDIR/ssh_config_ts" <<EOF
Host repl-test
  HostName $PEER
  Port 6800
  User runner
  IdentityFile $SSHDIR/id_ed25519
  IdentitiesOnly yes
  ProxyCommand python3 $REVDIR/ts_proxy_connect.py %h %p
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
cat > "$SSHDIR/config" <<EOF
Host repl-test
  HostName $PEER
  Port 6800
  User runner
  IdentityFile $SSHDIR/id_ed25519
  IdentitiesOnly yes
  ProxyCommand python3 $REVDIR/ts_proxy_connect.py %h %p
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
# Both loops share the guard: ExitOnForwardFailure + ServerAlive on the
# client, exponential backoff 5s -> 300s (reset after >120s uptime).
gen_loop() {
  local file=$1 log=$2 port=$3 extra=$4
  cat > "$file" <<EOS
#!/usr/bin/env bash
set -u
exec 9>"$REVDIR/\$(basename $log .log).lock"; flock -n 9 || exit 0
PORT=$port
if [ "\$PORT" = auto ]; then
  . "$REVDIR/reverse-alloc.sh"
  PORT=\$(alloc_claim_port "$SSHDIR" "$PEER" "$log" $extra) || { echo "[alloc] no port claimed in 16801-16899" >>"$log"; exit 1; }
  if grep -q "^RS_REVERSE_PORT=" "$SSHDIR/.env" 2>/dev/null; then sed -i "s/^RS_REVERSE_PORT=.*/RS_REVERSE_PORT=\$PORT/" "$SSHDIR/.env"; else echo "RS_REVERSE_PORT=\$PORT" >>"$SSHDIR/.env"; fi
  echo "[alloc] claimed peer port \$PORT (pinned to .env RS_REVERSE_PORT)" >>"$log"
fi
delay=5
while true; do
  start=\$(date +%s)
  echo "[\$(basename $file)] dialing \$(date -Is)" >>"$log"
  ${CLEANENV[@]@Q} ssh -N \\
    -R 127.0.0.1:\$PORT:127.0.0.1:6800 \\
    -p 6800 -i "$SSHDIR/id_ed25519" -o IdentitiesOnly=yes \\
    -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\
    -o ExitOnForwardFailure=yes \\
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
    $extra \\
    runner@$PEER >>"$log" 2>&1
  lived=\$(( \$(date +%s) - start ))
  echo "[\$(basename $file)] ended, lived \${lived}s, redial in \${delay}s" >>"$log"
  sleep "\$delay"
  if (( lived > 120 )); then delay=5; else delay=\$(( delay * 2 )); (( delay > 300 )) && delay=300; fi
done
EOS
  chmod +x "$file"
}
gen_loop "$REVDIR/start-reverse.sh" "$REVDIR/reverse.log" 16800 \
  "-F $REVDIR/ssh_config_ts"
REVPORT="$(grep -E '^RS_REVERSE_PORT=' "$SSHDIR/.env" 2>/dev/null | tail -1 | cut -d= -f2 || true)"; REVPORT="${REVPORT:-16801}"
gen_loop "$REVDIR/start-reverse-node.sh" "$REVDIR/reverse-node.log" "$REVPORT" \
  "-o ProxyCommand=\"$BINDIR/tailscale --socket=$TSDIR/tailscaled.sock nc %h %p\""
cat > "$REVDIR/reverse-alloc.sh" <<'EOS'
#!/usr/bin/env bash
# reverse-alloc.sh — claim a reverse-forward port on the peer for a
# generated start-reverse loop whose port is "auto" (RS_REVERSE_PORT=auto).
# The claim IS the bind: the probe ssh registers the forward with
# ExitOnForwardFailure and runs `true`; exit 0 means the port was ours
# for that session. A passive "is it free?" check would race — two
# claimants can both SEE a port free, they cannot both BIND it; the
# peer's sshd is the arbiter. "forwarding failed" advances to the
# next candidate; any other failure retries the SAME candidate (peer
# or network not ready — burning the range would help nobody).
# Args: $1=SSHDIR $2=PEER $3=LOG; transport ssh args follow as $4.. (word-split by the caller's source-level expansion, like the loop's own ssh line)
# Prints the claimed port on stdout; the caller pins it into .env.
alloc_claim_port() {
  local sshdir=$1 peer=$2 log=$3; shift 3
  local cand=16801 out rc
  while [ $cand -le 16899 ]; do
    out=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
      ssh -R 127.0.0.1:$cand:127.0.0.1:6800 \
      -p 6800 -i "$sshdir/id_ed25519" -o IdentitiesOnly=yes \
      -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ExitOnForwardFailure=yes -o ConnectTimeout=20 \
      "$@" \
      runner@$peer true 2>&1); rc=$?
    if [ $rc -eq 0 ]; then echo $cand; return 0; fi
    case "$out" in
      *"forwarding failed"*) cand=$((cand+1));;
      *) echo "[alloc] candidate $cand transient failure (rc=$rc), retrying same port" >>"$log"; sleep 15;;
    esac
  done
  return 1
}
EOS
chmod +x "$REVDIR/reverse-alloc.sh"
# The node-carried loop must run as root (a non-root service user cannot read the client key).
cat > "$REVDIR/check-reverse.sh" <<'EOS'
#!/usr/bin/env bash
# Probe both reverse forwards FROM the peer: OK / ZOMBIE / DOWN per port.
set -u
SOCK="$HOME/workspace/.local/share/tailscale/tailscaled.sock"
ssh -F "$HOME/workspace/.ssh/reverse/ssh_config_ts" -o "ProxyCommand=$HOME/workspace/.local/bin/tailscale --socket=$SOCK nc %h %p" repl-test '
SSH=$(command -v ssh 2>/dev/null || ls /nix/store/*-replit-runtime-path/bin/ssh 2>/dev/null | head -1)
KEYF=$HOME/.ssh/join-tailnet/host_ed25519; [ -f \"$KEYF\" ] || KEYF=$HOME/.ssh/id_muse_vm
probe() {
  local port=$1 name=$2 out
  out=$(timeout 20 \"$SSH\" -p \"$port\" -i \"$KEYF\" -o IdentitiesOnly=yes \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        runner@127.0.0.1 "hostname" 2>&1)
  if [[ "$out" == *"htch-runtime"* ]]; then echo "$name ($port): OK"
  elif [[ "$out" == *"Connection refused"* ]]; then echo "$name ($port): DOWN"
  else echo "$name ($port): ZOMBIE — $(echo "$out" | tail -1 | cut -c1-80)"; fi
}
probe 16800 connector
probe 16801 node
echo \"peer listeners 16800-16899:\"
while read sl la ra st rest; do
  if [ \"$st\" = 0A ]; then
    ph=${la##*:}
    case $ph in 41[ABCDEF][0-9A-F]|420[0-3]) echo \"  $((16#$ph))\";; esac
  fi
done < /proc/net/tcp
' 2>&1 | grep -v "Warning: Permanently"
EOS
case "$REVPORT" in *[!0-9]*|'') : ;; *) sed -i "s/^probe 16801 node/probe $REVPORT node/" "$REVDIR/check-reverse.sh";; esac
# The probe logs into THIS box's sshd through the forward, so its login
# user is the baked service user. (The User runner in ssh_config_ts is
# the PEER's own user — a connection TO the peer — and stays as-is.)
# This substitution is a no-op when the service user is runner.
sed -i "s/runner@127.0.0.1/$SSH_USER@127.0.0.1/" "$REVDIR/check-reverse.sh"
chmod +x "$REVDIR/check-reverse.sh"

}
phase_tailscale() {
say "tailscale binaries (pinned $TSVER, checksum verified)"
if [[ ! -x "$BINDIR/tailscaled" ]]; then
  TGZ="tailscale_${TSVER}_amd64.tgz"
  curl -fsSL -o "/tmp/$TGZ" "https://pkgs.tailscale.com/stable/$TGZ"
  curl -fsSL -o "/tmp/$TGZ.sha256" "https://pkgs.tailscale.com/stable/$TGZ.sha256"
  # Upstream's .sha256 is now a bare hash with no filename, which makes
  # `sha256sum -c` fail ("no properly formatted checksum lines") — compare
  # the first field manually; robust to both formats.
  EXPECTED="$(awk '{print $1}' "/tmp/$TGZ.sha256")"
  ACTUAL="$(sha256sum "/tmp/$TGZ" | awk '{print $1}')"
  [[ "$EXPECTED" == "$ACTUAL" ]] || { echo "checksum mismatch for $TGZ: expected $EXPECTED got $ACTUAL" >&2; exit 1; }
  tar -xzf "/tmp/$TGZ" -C /tmp
  install -m755 "/tmp/tailscale_${TSVER}_amd64/tailscale" "/tmp/tailscale_${TSVER}_amd64/tailscaled" "$BINDIR/"
  rm -rf "/tmp/$TGZ" "/tmp/$TGZ.sha256" "/tmp/tailscale_${TSVER}_amd64"
fi
chown "$SSH_USER:$SSH_USER" "$TSDIR" 2>/dev/null || true

say "launcher: start-tailscale.sh (userspace node; service user $SSH_USER baked in)"
cat > "$SSHDIR/start-tailscale.sh" <<'EOS'
#!/usr/bin/env bash
# Userspace tailscale node for a Muse VM. Three sandbox fixes, all required:
#  1. real control-plane IPs via an /etc/hosts override bind-mounted in a
#     private mount namespace (stock resolver is fake-IP);
#  2. daemon runs with the *_PROXY env scrubbed (proxied control fetches
#     get reset by the gateway; direct dials to real IPs succeed);
#  3. listeners on 127.0.0.1, never "localhost".
# Run as root from a FOREGROUND agent turn (its first direct dials may need
# an egress approval a background run cannot mint).
set -uo pipefail
STACK="$HOME/workspace/.ssh"
BIN="$HOME/workspace/.local/bin"
TS="$HOME/workspace/.local/share/tailscale"
SOCK="$TS/tailscaled.sock"
TSCTL="$BIN/tailscale --socket=$SOCK"
CLEANENV=(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy -u NO_PROXY -u no_proxy)
EOS
# Baked by setup.sh: how this launcher runs tailscale commands as the
# stack service user — a runuser prefix for a non-root user, direct
# execution when the service user is root.
if [[ "$SSH_USER" != root ]]; then
  cat >> "$SSHDIR/start-tailscale.sh" <<EOS
RUNAS=(runuser -u $SSH_USER --)
DAEMON_RUNAS="runuser -u $SSH_USER -- "
EOS
else
  cat >> "$SSHDIR/start-tailscale.sh" <<'EOS'
RUNAS=()
DAEMON_RUNAS=""
EOS
fi
cat >> "$SSHDIR/start-tailscale.sh" <<'EOS'
chmod o+x "$HOME" "$HOME/workspace" "$HOME/workspace/.local" "$HOME/workspace/.local/share"
EOS
if [[ "$SSH_USER" != root ]]; then
  cat >> "$SSHDIR/start-tailscale.sh" <<EOS
id $SSH_USER >/dev/null 2>&1 || useradd -d "\$STACK/home" -s /bin/bash $SSH_USER
EOS
fi
cat >> "$SSHDIR/start-tailscale.sh" <<'EOS'
mkdir -p "$TS/state"
[[ -f "$STACK/.env" ]] && { set -a; source "$STACK/.env"; set +a; }
# dig's anycast answers rotate, and most endpoints are unreachable
# through this gateway at any given time (observed: one of four probed
# answered; a dead pick = "fetch control key: context deadline exceeded"
# and a node stuck Logged out). Probe the candidates and pin the first
# that actually answers; .102 is the known-good fallback.
IP=""
# Fixed preference order first: the egress approvals are keyed per
# destination IP, so re-pinning the SAME control IP every boot reuses the
# existing approval instead of minting a new prompt. dig's rotating order
# is only a fallback source of fresh candidates.
for cand in $(printf '%s
' 192.200.0.102 192.200.0.107 192.200.0.110 192.200.0.104 192.200.0.106 192.200.0.112 $(dig +short +time=4 +tries=1 @8.8.8.8 controlplane.tailscale.com A 2>/dev/null | grep -E '^[0-9.]+$') | awk '!seen[$0]++'); do
  if timeout 8 curl -s -o /dev/null --noproxy '*' --resolve "controlplane.tailscale.com:443:$cand" --max-time 6 "https://controlplane.tailscale.com/key?v=148"; then IP="$cand"; break; fi
done
[[ -n "$IP" ]] || IP="192.200.0.102"
cp /etc/hosts "$TS/hosts"
printf '%s controlplane.tailscale.com\n%s login.tailscale.com\n' "$IP" "$IP" >> "$TS/hosts"
if ! "${RUNAS[@]}" "${CLEANENV[@]}" $TSCTL status >/dev/null 2>&1 \
   && ! "${RUNAS[@]}" "${CLEANENV[@]}" $TSCTL status 2>&1 | grep -q "Logged out"; then
  for p in $(pgrep tailscaled 2>/dev/null); do
    tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q ".local/share/tailscale" && kill "$p"
  done
  sleep 1; rm -f "$SOCK"
  unshare -m bash -c '
    mount --bind '"$TS"'/hosts /etc/hosts || exit 1
    '"$DAEMON_RUNAS"'env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy -u NO_PROXY -u no_proxy \
      setsid '"$BIN"'/tailscaled --tun=userspace-networking \
        --socks5-server=127.0.0.1:1056 --outbound-http-proxy-listen=127.0.0.1:1056 \
        --state='"$TS"'/state/tailscaled.state --statedir='"$TS"'/state --socket='"$SOCK"' \
        </dev/null >>'"$TS"'/tailscaled.log 2>&1 &
  '
  for _ in $(seq 1 12); do [[ -S "$SOCK" ]] && break; sleep 1; done
fi
[[ -S "$SOCK" ]] || { echo "tailscaled socket not ready — see $TS/tailscaled.log"; exit 1; }
# Wait for a definitive status line: the "Tailscale is starting" health
# block can hide a "Logged out." first line and skip the join below.
STATE=""
for _ in $(seq 1 15); do
  STATE="$("${RUNAS[@]}" "${CLEANENV[@]}" $TSCTL status 2>&1 | head -1)"
  [[ "$STATE" != "# Health check:" ]] && break
  sleep 1
done
echo "status: $STATE"
if [[ "$STATE" == "Logged out." ]]; then
  if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    "${RUNAS[@]}" "${CLEANENV[@]}" $TSCTL up \
      --authkey "$TAILSCALE_AUTH_KEY" --hostname "${TAILSCALE_NODE_NAME:-muse-join}" --accept-routes=false 2>&1 \
      | sed -E 's/(tskey-)[A-Za-z0-9_-]+/\1***/g'
  else
    echo "logged out and no TAILSCALE_AUTH_KEY in $STACK/.env"; exit 1
  fi
fi
"${RUNAS[@]}" "${CLEANENV[@]}" $TSCTL status 2>&1 | head -3
"${RUNAS[@]}" "${CLEANENV[@]}" $TSCTL ip -4 2>/dev/null
EOS
chmod +x "$SSHDIR/start-tailscale.sh"

}
phase_join() {
say "start the stack"
# REVPORT is set by phase_sshd's render — but -j skips that phase when
# the launchers already exist (the normal re-run), leaving it unbound:
# the hop-mode echo below then dies under set -u BEFORE the reverse
# loop launches. Derive it here when unset, same source as line ~499.
if [[ -z "${REVPORT:-}" ]]; then
  REVPORT="$(grep -E '^RS_REVERSE_PORT=' "$SSHDIR/.env" 2>/dev/null | tail -1 | cut -d= -f2 || true)"; REVPORT="${REVPORT:-16801}"
fi
bash "$SSHDIR/start-sshd.sh" || true
if grep -q "^TAILSCALE_AUTH_KEY=.\+" "$SSHDIR/.env"; then
  bash "$SSHDIR/start-tailscale.sh" || true
  if grep -qE "^RS_REVERSE_PEER=.+" "$SSHDIR/.env"; then
    (setsid bash "$REVDIR/start-reverse-node.sh" >>"$REVDIR/reverse-node.outer.log" 2>&1 &)
    echo "hop mode (RS_REVERSE_PEER set): node-carried reverse loop launched on port $REVPORT; verify shortly: bash $REVDIR/check-reverse.sh"
    echo "the connector-carried loop (start-reverse.sh) is generated but NOT launched — it needs the built-in connector, which the standing setup does not use"
  else
    echo "leaf mode (RS_REVERSE_PEER unset): reverse loops generated but NOT launched — only the fleet hop runs one. This box is reachable through the hop; it opens no tunnels and registers its key nowhere."
  fi
else
  echo "TAILSCALE_AUTH_KEY still empty in $SSHDIR/.env — sshd is up; fill the key and re-run to join (+ launch the reverse loop if this box is a hop)"
fi

say "handoff"
echo "client pubkey (register it ONLY at the fleet hop, and only if this box must initiate ssh to the hop):"
cat "$SSHDIR/id_ed25519.pub"
echo "authorized_keys already trusts the muse-hop key (seeded above) — nothing else belongs there by default"
echo "redeploy restore order: start-sshd.sh -> start-tailscale.sh (foreground) -> reverse loop (hop boxes only)"

}

# ── Interactive phase menu (arrow keys; pattern after the replit
#    setup's ui_menu.sh, scaled to this skill's three phases) ──────────
_MENU_ITEMS=(
  "sshd|sshd stack — users, openssh, keys, launchers, reverse scripts"
  "tailscale|tailscale — pinned binaries + userspace node launcher"
  "join|join — start the stack, join the tailnet, launch the hop's loop"
)
_MENU_CURSOR=0
_MENU_TOGGLE=(0 0 0)

_menu_status() {
  local b n
  b="$(timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6800; IFS= read -r -t 1 l <&3; echo "$l"' 2>/dev/null || true)"
  [[ -n "$b" ]] && echo "sshd: $b" || echo "sshd: DOWN"
  [[ -x "$BINDIR/tailscaled" ]] && echo "tailscale binaries: installed ($TSVER)" || echo "tailscale binaries: not installed"
  n="$(svc_run "${CLEANENV[@]}" "$BINDIR/tailscale" --socket="$TSDIR/tailscaled.sock" status 2>/dev/null | head -1 || true)"
  [[ -n "$n" ]] && echo "node: $n" || echo "node: DOWN"
}

_menu_draw() {
  clear
  echo "Muse VM — remote-access setup"
  echo "↑/↓ move · space toggle · enter confirm · q quit"
  echo ""
  echo "Current status"
  _menu_status
  echo ""
  local i desc mark prefix
  for i in "${!_MENU_ITEMS[@]}"; do
    IFS='|' read -r _ desc <<< "${_MENU_ITEMS[$i]}"
    [[ "${_MENU_TOGGLE[$i]}" -eq 1 ]] && mark="[✓]" || mark="[ ]"
    [[ "$i" -eq "$_MENU_CURSOR" ]] && prefix=">" || prefix=" "
    echo " $prefix $mark $desc"
  done
}

_menu_read_key() {
  local key
  if ! IFS= read -rsn1 key; then echo quit; return 0; fi
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 key || true
    case "$key" in '[A') echo up ;; '[B') echo down ;; esac
  elif [[ "$key" == " " ]]; then echo space
  elif [[ -z "$key" ]]; then echo enter
  elif [[ "$key" == "q" || "$key" == "Q" ]]; then echo quit; fi
}

interactive_menu() {
  printf '\033[?25l'; trap 'printf "\033[?25h\n"; exit 130' INT
  set +e
  while true; do
    _menu_draw
    case "$(_menu_read_key)" in
      up)   _MENU_CURSOR=$(( (_MENU_CURSOR + ${#_MENU_ITEMS[@]} - 1) % ${#_MENU_ITEMS[@]} )) ;;
      down) _MENU_CURSOR=$(( (_MENU_CURSOR + 1) % ${#_MENU_ITEMS[@]} )) ;;
      space) _MENU_TOGGLE[$_MENU_CURSOR]=$(( 1 - _MENU_TOGGLE[$_MENU_CURSOR] )) ;;
      enter) break ;;
      quit)  printf '\033[?25h'; trap - INT; echo "Aborted."; exit 130 ;;
    esac
  done
  printf '\033[?25h'; trap - INT
  set -e
  [[ "${_MENU_TOGGLE[0]}" -eq 1 ]] && { DO_SSHD=1; SELECTED=1; }
  [[ "${_MENU_TOGGLE[1]}" -eq 1 ]] && { DO_TAILSCALE=1; SELECTED=1; }
  [[ "${_MENU_TOGGLE[2]}" -eq 1 ]] && { DO_JOIN=1; SELECTED=1; }
}


# ── dispatch ──────────────────────────────────────────────────────────
if [[ $DO_MENU -eq 1 ]] || { [[ $SELECTED -eq 0 ]] && [[ -t 0 ]]; }; then
  interactive_menu
fi
if [[ $SELECTED -eq 0 ]]; then
  # Bare run without a TTY (agent exec): the full setup, as before —
  # the menu must never deadlock a non-interactive shell.
  DO_SSHD=1 DO_TAILSCALE=1 DO_JOIN=1
fi
if [[ $DO_JOIN -eq 1 ]]; then
  # -j implies the phases whose outputs it starts, when they are missing.
  [[ -x "$SSHDIR/start-sshd.sh" ]] || DO_SSHD=1
  [[ -x "$SSHDIR/start-tailscale.sh" ]] || DO_TAILSCALE=1
fi
[[ $DO_SSHD -eq 1 ]] && phase_sshd
[[ $DO_TAILSCALE -eq 1 ]] && phase_tailscale
[[ $DO_JOIN -eq 1 ]] && phase_join
