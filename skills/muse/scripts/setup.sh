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
# Usage:
#   bash setup.sh [--peer <tailnet-ip>] [--verify]
#
# Secrets never live in this repo: the operator creates <ws>/.ssh/.env
# (mode 600) with TAILSCALE_AUTH_KEY=<key for the tailnet> — setup writes
# a template and stops short of the join while the key is empty.
# The peer (default 100.106.114.30 = repl-test) is the machine that will
# hold the reverse forwards; its public key must be added to
# <ws>/.ssh/sshd-dir/authorized_keys and this VM's client pubkey
# (<ws>/.ssh/id_ed25519.pub, printed at the end) to the peer's sshd.
set -euo pipefail

PEER=100.106.114.30 VERIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer) PEER=$2; shift 2 ;;
    --verify) VERIFY=1; shift ;;
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

if [[ $VERIFY -eq 1 ]]; then
  say "verify"
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6800; IFS= read -r -t 1 l <&3; echo "sshd: $l"' 2>/dev/null || echo "sshd: DOWN"
  NODE_STATUS="$(runuser -u runner -- "${CLEANENV[@]}" "$BINDIR/tailscale" --socket="$TSDIR/tailscaled.sock" status 2>&1 | head -2)"
  [[ -n "$NODE_STATUS" ]] && printf '%s
' "$NODE_STATUS" || echo "node: DOWN"
  echo "reverse forwards (probe runs from the peer): bash $REVDIR/check-reverse.sh"
  exit 0
fi

say "layout + users"
chmod o+x "$HOME" "$WS"
mkdir -p "$SSHDIR/sshd-dir" "$SSHDIR/bin" "$REVDIR" "$BINDIR" "$TSDIR/state" "$WS/config" "$SSHDIR/home"
chmod o+x "$WS/.local" "$WS/.local/share" "$SSHDIR"
id runner >/dev/null 2>&1 || useradd -d "$SSHDIR/home" -s /bin/bash runner
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
[[ -f "$SSHDIR/sshd-dir/ssh_host_ed25519_key" ]] || \
  ssh-keygen -t ed25519 -f "$SSHDIR/sshd-dir/ssh_host_ed25519_key" -N '' >/dev/null
touch "$SSHDIR/sshd-dir/authorized_keys"; chmod 600 "$SSHDIR/sshd-dir/authorized_keys"
# Default trust: the fleet hop (mirrors the replit skill's hermes-join-hop).
# Every box stood up with this setup authorizes the muse-join-hop key —
# the operator's main Muse VM — from birth, so onboarding never needs a
# per-machine key exchange; the hop reaches every fleet box directly and
# any-to-any goes through it (star, not mesh: one distributed pubkey).
# The hop's private key never leaves the hop machine. Override by setting
# RS_AUTHORIZED_KEYS (one pubkey per line) in the .env before running.
HOP_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtOrYNU7XhUsf+6dygX5j9xdDlT7hId3NO7gwi8GhBq muse-join-hop"
seed_key() { grep -q " $2 " "$SSHDIR/sshd-dir/authorized_keys" 2>/dev/null || echo "$1" >> "$SSHDIR/sshd-dir/authorized_keys"; }
if [[ -n "${RS_AUTHORIZED_KEYS:-}" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && seed_key "$line" "$(echo "$line" | awk '{print $2}')"
  done <<< "$RS_AUTHORIZED_KEYS"
else
  seed_key "$HOP_KEY" "$(echo "$HOP_KEY" | awk '{print $2}')"
fi
cat > "$SSHDIR/sshd-dir/sshd_config" <<EOF
Port 6800
ListenAddress 0.0.0.0
Protocol 2
HostKey $SSHDIR/sshd-dir/ssh_host_ed25519_key
PidFile $SSHDIR/sshd-dir/sshd.pid
AuthorizedKeysFile $SSHDIR/sshd-dir/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
# StrictModes off is load-bearing on this platform: the idmapped home
# mount forces group/world-writable modes on the persistent tree (the
# proven live stack runs home at 777), and StrictModes would refuse
# every authorized_keys for exactly that. Key-only auth stays on.
StrictModes no
ChallengeResponseAuthentication no
PermitRootLogin no
AllowUsers runner
UsePAM no
PermitTunnel no
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 30
ClientAliveCountMax 3
Subsystem sftp $SSHDIR/rootfs/usr/lib/openssh/sftp-server
EOF
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
if [ -f "$HOME/workspace/.ssh/.env" ]; then
  set -a; . "$HOME/workspace/.ssh/.env"; set +a
fi
EOF
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
#RS_AUTHORIZED_KEYS= (optional override: pubkeys to authorize instead of the muse-join-hop default)
#RS_REVERSE_PEER= (HOP ONLY: peer IP that receives this box's reverse forward. Leaves leave
#  this unset — a leaf runs NO reverse loop; only the fleet hop opens one, to the repl hop.)
#RS_REVERSE_PORT=16801 (forward port on the peer when RS_REVERSE_PEER is set)
EOF
  chmod 600 "$SSHDIR/.env"
  echo "created $SSHDIR/.env — fill TAILSCALE_AUTH_KEY (600, never commit it), then re-run this script"
fi

say "launcher: start-sshd.sh"
cat > "$SSHDIR/start-sshd.sh" <<'EOS'
#!/usr/bin/env bash
# (Re)start the join sshd as `runner` on 6800. Run as root after a redeploy:
# /etc/passwd + /run + /root/.ssh are ephemeral; everything else persists.
set -euo pipefail
SSHDIR="$HOME/workspace/.ssh"
if [[ "$(readlink /root/.ssh 2>/dev/null)" != "$SSHDIR" ]]; then rm -rf /root/.ssh; ln -s "$SSHDIR" /root/.ssh; fi
chmod o+x "$HOME" "$HOME/workspace"
id runner >/dev/null 2>&1 || useradd -d "$SSHDIR/home" -s /bin/bash runner
getent passwd sshd >/dev/null 2>&1 || useradd -r -d /run/sshd -s /usr/sbin/nologin sshd
mkdir -p /run/sshd && chmod 755 /run/sshd
if [[ -f "$SSHDIR/sshd-dir/sshd.pid" ]] && kill -0 "$(cat "$SSHDIR/sshd-dir/sshd.pid")" 2>/dev/null; then
  echo "sshd already running"; exit 0
fi
runuser -u runner -- bash -c \
  "setsid $SSHDIR/rootfs/usr/sbin/sshd -f $SSHDIR/sshd-dir/sshd_config -E $SSHDIR/sshd-dir/sshd.log </dev/null >/dev/null 2>&1 & disown"
for _ in $(seq 1 10); do
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6800; IFS= read -r -t 1 l <&3; echo "$l"' 2>/dev/null && break
  sleep 1
done
EOS
chmod +x "$SSHDIR/start-sshd.sh"

say "tailscale binaries (pinned $TSVER, checksum verified)"
if [[ ! -x "$BINDIR/tailscaled" ]]; then
  TGZ="tailscale_${TSVER}_amd64.tgz"
  curl -fsSL -o "/tmp/$TGZ" "https://pkgs.tailscale.com/stable/$TGZ"
  curl -fsSL -o "/tmp/$TGZ.sha256" "https://pkgs.tailscale.com/stable/$TGZ.sha256"
  (cd /tmp && sha256sum -c "$TGZ.sha256")
  tar -xzf "/tmp/$TGZ" -C /tmp
  install -m755 "/tmp/tailscale_${TSVER}_amd64/tailscale" "/tmp/tailscale_${TSVER}_amd64/tailscaled" "$BINDIR/"
  rm -rf "/tmp/$TGZ" "/tmp/$TGZ.sha256" "/tmp/tailscale_${TSVER}_amd64"
fi
chown runner:runner "$TSDIR" 2>/dev/null || true

say "launcher: start-tailscale.sh (userspace node — the proven recipe)"
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
chmod o+x "$HOME" "$HOME/workspace" "$HOME/workspace/.local" "$HOME/workspace/.local/share"
id runner >/dev/null 2>&1 || useradd -d "$STACK/home" -s /bin/bash runner
mkdir -p "$TS/state"
[[ -f "$STACK/.env" ]] && { set -a; source "$STACK/.env"; set +a; }
# dig's anycast answers rotate, and most endpoints are unreachable
# through this gateway at any given time (observed: one of four probed
# answered; a dead pick = "fetch control key: context deadline exceeded"
# and a node stuck Logged out). Probe the candidates and pin the first
# that actually answers; .102 is the known-good fallback.
IP=""
for cand in $(dig +short +time=4 +tries=1 @8.8.8.8 controlplane.tailscale.com A 2>/dev/null | grep -E '^[0-9.]+$'); do
  if timeout 8 curl -s -o /dev/null --noproxy '*' --resolve "controlplane.tailscale.com:443:$cand" --max-time 6 "https://controlplane.tailscale.com/key?v=148"; then IP="$cand"; break; fi
done
[[ -n "$IP" ]] || IP="192.200.0.102"
cp /etc/hosts "$TS/hosts"
printf '%s controlplane.tailscale.com\n%s login.tailscale.com\n' "$IP" "$IP" >> "$TS/hosts"
if ! runuser -u runner -- "${CLEANENV[@]}" $TSCTL status >/dev/null 2>&1 \
   && ! runuser -u runner -- "${CLEANENV[@]}" $TSCTL status 2>&1 | grep -q "Logged out"; then
  for p in $(pgrep tailscaled 2>/dev/null); do
    tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q ".local/share/tailscale" && kill "$p"
  done
  sleep 1; rm -f "$SOCK"
  unshare -m bash -c '
    mount --bind '"$TS"'/hosts /etc/hosts || exit 1
    runuser -u runner -- env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy -u NO_PROXY -u no_proxy \
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
  STATE="$(runuser -u runner -- "${CLEANENV[@]}" $TSCTL status 2>&1 | head -1)"
  [[ "$STATE" != "# Health check:" ]] && break
  sleep 1
done
echo "status: $STATE"
if [[ "$STATE" == "Logged out." ]]; then
  if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    runuser -u runner -- "${CLEANENV[@]}" $TSCTL up \
      --authkey "$TAILSCALE_AUTH_KEY" --hostname "${TAILSCALE_NODE_NAME:-muse-join}" --accept-routes=false 2>&1 \
      | sed -E 's/(tskey-)[A-Za-z0-9_-]+/\1***/g'
  else
    echo "logged out and no TAILSCALE_AUTH_KEY in $STACK/.env"; exit 1
  fi
fi
runuser -u runner -- "${CLEANENV[@]}" $TSCTL status 2>&1 | head -3
runuser -u runner -- "${CLEANENV[@]}" $TSCTL ip -4 2>/dev/null
EOS
chmod +x "$SSHDIR/start-tailscale.sh"

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
delay=5
while true; do
  start=\$(date +%s)
  echo "[\$(basename $file)] dialing \$(date -Is)" >>"$log"
  ${CLEANENV[@]@Q} ssh -N \\
    -R 127.0.0.1:$port:127.0.0.1:6800 \\
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
REVPORT="$(grep -E '^RS_REVERSE_PORT=' "$SSHDIR/.env" 2>/dev/null | tail -1 | cut -d= -f2)"; REVPORT="${REVPORT:-16801}"
gen_loop "$REVDIR/start-reverse-node.sh" "$REVDIR/reverse-node.log" "$REVPORT" \
  "-o ProxyCommand=\"$BINDIR/tailscale --socket=$TSDIR/tailscaled.sock nc %h %p\""
# The node-carried loop must run as root (runner cannot read the client key).
cat > "$REVDIR/check-reverse.sh" <<'EOS'
#!/usr/bin/env bash
# Probe both reverse forwards FROM the peer: OK / ZOMBIE / DOWN per port.
set -u
SOCK="$HOME/workspace/.local/share/tailscale/tailscaled.sock"
ssh -F "$HOME/workspace/.ssh/reverse/ssh_config_ts" -o "ProxyCommand=$HOME/workspace/.local/bin/tailscale --socket=$SOCK nc %h %p" repl-test '
probe() {
  local port=$1 name=$2 out
  out=$(timeout 20 ssh -p "$port" -i ~/.ssh/id_muse_vm -o IdentitiesOnly=yes \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        runner@127.0.0.1 "hostname" 2>&1)
  if [[ "$out" == *"htch-runtime"* ]]; then echo "$name ($port): OK"
  elif [[ "$out" == *"Connection refused"* ]]; then echo "$name ($port): DOWN"
  else echo "$name ($port): ZOMBIE — $(echo "$out" | tail -1 | cut -c1-80)"; fi
}
probe 16800 connector
probe 16801 node
' 2>&1 | grep -v "Warning: Permanently"
EOS
sed -i "s/^probe 16801 node/probe $REVPORT node/" "$REVDIR/check-reverse.sh"
chmod +x "$REVDIR/check-reverse.sh"

say "start the stack"
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
echo "authorized_keys already trusts the muse-join-hop key (seeded above) — nothing else belongs there by default"
echo "redeploy restore order: start-sshd.sh -> start-tailscale.sh (foreground) -> reverse loop (hop boxes only)"
