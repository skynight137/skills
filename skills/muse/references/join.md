# Muse VM — Tailscale joins & remote access

Verified end-to-end 2026-11-02 against a Replit peer (`repl-test`,
100.106.114.30, sshd on 6800). The mental model: this VM can hold **two
unrelated tailnet identities at once**, and they are not interchangeable.

## Route A/C — the built-in connector (same enrollment)

> Standing decision (2026-11-02): the operator DISCONNECTED the connector
> after validating that the manual userspace route covers everything —
> node join, outbound SSH, and the reverse-SSH inbound door all pass with
> the connector gone. The connector route below is dormant background,
> kept for the day a box has no auth key. The standing stack is Route B
> only, with the node-carried reverse forward (16801) as the inbound door.

- A Tailscale client run by the **platform, outside the container**. The
  device requests the name `muse`; repeat enrollments take suffixed names
  (`muse-2`, …) and stale records linger in the admin console as deletable
  ghosts.
- **Outbound only.** There is no tailscaled, no tailnet interface, and no
  100.x address inside the container. Traffic exits via the connector's
  tunnel proxy: the runtime proxy URL with the port swapped to **3130**,
  HTTP CONNECT per destination. The first request to an exact tailnet IP
  needs its own approval; after that it's transparent.
- It can never accept inbound or host a service — there is nothing inside
  the VM for traffic to terminate on. Do not design around it for inbound.

## Route B — userspace node via auth key

A real `tailscaled` inside the container (`--tun=userspace-networking`),
run as a non-root user, state in the persistent tree. Joining needed
External DNS + Other TCP (Ask) — **not** Other UDP — plus three sandbox
fixes, all required:

1. **Real control IPs via hosts override**: get `controlplane.tailscale.com`
   from `dig @8.8.8.8`, append it to a copy of `/etc/hosts`, and bind-mount
   that copy over `/etc/hosts` inside a private mount namespace
   (`unshare -m`) that only the daemon lives in. `/etc/hosts` is a
   read-only bind mount; the namespace is the way around it.
2. **Scrub the proxy env** from the daemon: with `*_PROXY` present its
   control fetch via the proxy is reset repeatedly (while curl's identical
   fetch returns 200). Scrubbed + real IPs, its direct dials succeed.
3. **Bind listeners to `127.0.0.1`**, never `localhost` (the daemon
   resolves that through the fake-IP resolver and fails to bind).

Result when it works: `tailscale up` exits 0 in seconds, node registered
(same 100.x IP across rejoins; name may gain a `-1` suffix from a stale
record holding the base name), DERP-connected. Node identity persists in
the state dir, so later redeploys only restart the daemon — unless it
comes up `Logged out.`, in which case re-run `up` with the auth key from
the 600 `.env`. Gotcha: right after daemon start, `tailscale status`
prints a `# Health check: Tailscale is starting` block whose first line
hides `Logged out.` from naive `head -1` checks — wait for a definitive
status line before deciding no join is needed.

## Inbound to the node: what the evidence says

- The node has no discoverable endpoint (no UDP → no STUN), so all paths
  are DERP relays; the admin console shows Client Connectivity all-No and
  no advertised services.
- Raw inbound TCP arrives at the netstack but is dropped as
  `packet was not handled` — userspace mode forwards nothing by default.
- `tailscale serve --bg --tcp=<port> tcp://localhost:<port>` registers a
  forward and a test connection demonstrably reached the local sshd — but
  the stream died during SSH banner exchange over the double-userspace
  DERP path, repeatedly. **Verdict: inbound via the node IP is not a
  working SSH path from that Replit peer.** (A wedged `foreground listener
  already exists` serve state, left by a killed foreground `serve` run,
  clears only on daemon restart.)
- **Refinement (2026-11-02, muse-test e2e): the failure is peer-specific,
  not a property of the node.** From a second Muse VM's userspace node,
  ssh to the first node's IP:6800 (ProxyCommand = the local daemon's
  `tailscale nc`) completed the full SSH transport — banner, kex, auth
  methods — and failed only at pubkey authorization, exactly as expected
  with an unexchanged key. Node-to-node between Muse VMs is a working
  direct path once `authorized_keys` are exchanged; the reverse-forward
  pattern remains the answer for peers whose own access path mangles the
  stream (the Replit SOCKS/`nc` hop), and as belt-and-braces generally.

## Fleet hop: one distributed pubkey per side

Key exchange does not scale as a mesh. Both skills use a star instead:
one **hop** identity per fleet side, whose pubkey is authorized by
default on every box the setup touches — Replit side: `hermes-join-hop`
(the `RS_AUTHORIZED_KEYS` default in the replit join setup); Muse side:
**`muse-join-hop`** — the operator's main Muse VM (node
`muse-join-hop`, 100.113.127.73; the node itself carries the hop name) — seeded by `scripts/setup.sh` into the new box's
`sshd-dir/authorized_keys` unless `RS_AUTHORIZED_KEYS` overrides it.
Onboarding a Muse VM is then: run setup, fill the auth key, done — the
hop can already log in; no per-machine pubkey ping-pong. A box's own
client key needs distributing only if that box must initiate somewhere
specific. Any-to-any traffic goes through the side's hop; cross-side
(muse ↔ repl) uses the hop-to-hop links that already exist.

`repl-test` is NOT the muse hop: it stays the Replit-side e2e target and
the landing peer for this box's legacy reverse forward (16801). Boxes
that still reverse into a shared peer must take distinct forward ports
per box — the port, not the peer, is the contended resource.

## Topology: leaves are silent, the hop carries the tunnels

A leaf Muse VM runs **no reverse loop** and registers its client key
**nowhere by default**. The only reverse tunnel on the Muse side is the
hop's: `muse-join-hop` → the repl hop (today `repl-test`, port 16801).
Setup enforces this: the reverse scripts are generated on every box but
launched only when `RS_REVERSE_PEER` is set in the box's `.env` (hop
boxes), with `RS_REVERSE_PORT` choosing the forward port. Consequences:

- **hop → leaf**: direct node-to-node ssh; the leaf trusts the hop key
  from setup. No per-leaf anything.
- **leaf → leaf**: never direct, never cross-registered. Two-stage via
  the hop: ssh into the hop, then from the hop into the target leaf
  (the second leg uses the hop's own key). If a leaf must *initiate* to
  the hop, its client pubkey is registered at exactly one place: the
  hop's `authorized_keys`.
- **repl side → leaf**: repl hop → the hop's reverse forward (16801)
  → muse-join-hop → direct to the leaf. Hermes reaches every Muse VM
  through that single door; no leaf keys exist on the repl side.

This removes the two failure modes of the per-box design: pubkey
ping-pong for every new box, and several boxes contending for one
forward port on a shared peer.

## The pattern that works: reverse SSH

The VM dials OUT to the peer and leaves `-R 127.0.0.1:<rport>:127.0.0.1:6800`
(the local join sshd). Both carriers are proven:

| Carrier | Forward on peer | Transport of the outbound leg |
|---|---|---|
| Connector | 16800 | ssh via a `Host` block whose ProxyCommand runs the tunnel-proxy helper |
| Userspace node | 16801 | ssh whose ProxyCommand is the node's own `tailscale --socket=<ts2 sock> nc %h %p` (run as root — the non-root daemon user cannot read the client key) |

Non-obvious failure that cost hours: **stale forwards**. If the peer's
sshd never probes client liveness, a half-dead reverse client's forward
registration lingers and every re-registration fails with
`remote port forwarding failed for listen port` — while an unguarded 5s
redial loop happily logs thousands of attempts. Defenses, all applied:

- Client: `ExitOnForwardFailure=yes`, `ServerAliveInterval=30`,
  `ServerAliveCountMax=3`.
- Server (both sshd configs): `ClientAliveInterval 30`,
  `ClientAliveCountMax 3` so dead clients get reaped and ports free up.
- Redial loop: exponential backoff 5s → 300s cap; a connection that lived
  > 120s resets the delay to 5s.

## Layout & restore order (post-redeploy)

Canonical project root: `~/workspace/.ssh/` (see platform.md for the
symlink pattern). Scripts: `start-sshd.sh` (recreates users, `/run/sshd`,
the `/root/.ssh` symlink; starts sshd as the service user on 6800),
`start-tailscale.sh` (daemon + join), `reverse/start-reverse.sh` /
`reverse/start-reverse-node.sh` (the two reverse loops) and
`reverse/check-reverse.sh` (OK/ZOMBIE/DOWN probe run from the peer).
The tailscale binaries follow XDG like the Replit layout:
`~/workspace/.local/bin/`, daemon state/socket/log in
`~/workspace/.local/share/tailscale/`. A fresh VM gets all of this from
`scripts/setup.sh` in this skill.

Restore order after a redeploy:

1. `bash ~/workspace/.ssh/start-sshd.sh`
2. `bash ~/workspace/.ssh/start-tailscale.sh` — **from a foreground agent
   turn**; its direct dials may need a fresh egress approval that
   background runs cannot get.
3. Launch both reverse scripts detached (each under its own `flock`).

Verify from the peer: `ssh muse-vm` (16800) and the 16801 alias both land
in the VM as the service user on the VM's hostname.
