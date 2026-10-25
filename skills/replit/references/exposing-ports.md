# Exposing a service on a Replit workspace

Getting a server inside the sandbox reachable from a browser — and the one thing
that cannot be reached that way. Pairs with the `[[ports]]` and TLS bullets in
SKILL.md.

## Declared ports only, and the port stays in the URL

Replit's dev domain proxies ONLY the ports listed in `.replit` `[[ports]]` (each
needs matching `localPort`/`externalPort`), and the URL always carries the port:
`https://$REPLIT_DEV_DOMAIN:<port>/`. A service on an undeclared port is
reachable on `127.0.0.1` inside the sandbox and nowhere else.

Why the port is mandatory: only one port can be the default. A bare
`https://$REPLIT_DEV_DOMAIN/` hits port 80 and returns `502` when nothing listens
there, so a perfectly working service on 3002 "looks broken" at the bare URL.
Tell the user to keep `:3002` in the address.

Verify a service the moment it starts — three separate questions:

```bash
curl -sS  http://127.0.0.1:<port>/health                                   # alive locally?
curl -skS -o /dev/null -w '%{http_code}\n' "https://$REPLIT_DEV_DOMAIN:<port>/"   # proxied?
```

- `000` = nothing reachable; `502` = proxy up but nothing on that port; `200` = good.
- `-k` is needed here only because this box's curl lacks the Replit proxy root in
  its trust store (SKILL.md "Camofox public access", `references/tls-trust.md`).
  A `-k` pass proves reachability, not trust — never report it as an auth or tool
  pass. Run the verified call before naming a cause.
- Pick `localPort == externalPort` unless you have a reason not to, so the URL
  uses that same number.
- Check a port is actually free before assigning it:
  `awk 'NR>1 && $4=="0A" {split($2,a,":"); print strtonum("0x" a[2])}' /proc/net/tcp /proc/net/tcp6`

## The router is HTTP(S)-only — no public raw TCP

A port that serves HTTP fine is NOT a general TCP listener through the router: a
raw socket handshake to `$REPLIT_DEV_DOMAIN:<declared-port>` does not connect,
including for a port whose HTTPS request returns 200. So `sshd`, a database port,
or any other non-HTTP protocol cannot be exposed on a public port.

Consequence: sandbox-to-sandbox SSH over a public port is not possible. Reach a
second sandbox with an overlay/tunnel instead (Tailscale below, or a Cloudflare
tunnel), or move data through a git remote.

`sshd` itself is present (`/nix/store/*/replit-runtime-path/bin/sshd`) and
something does answer on `127.0.0.1:22` (`SSH-2.0-Go`), but that is loopback only:
the dev domain is HTTP, and 22 is not a declared port.

## Tailscale in a Replit sandbox (userspace mode)

**Pass `--statedir`, not just `--state`.** `--state` names the state *file*;
without a `--statedir` directory tailscaled has nowhere to write the ACME
certificate, so every HTTPS handshake for a `funnel`/`serve` hostname fails —
`no TailscaleVarRoot` in `tailscaled.log`, and the client sees `unexpected eof`
from `curl`. Run the daemon with both, plus the socket:

```bash
--state=$BASE/state/tailscaled.state --statedir=$BASE/state --socket=$BASE/state/tailscaled.sock
```


`/dev/net/tun` is `crw------- nobody nogroup`, so it cannot be opened and the
kernel TUN device is unusable. Run Tailscale with userspace networking: it needs
no TUN and still accepts INBOUND connections, so a second sandbox's sshd is
reachable over the tailnet.

```bash
BASE=$REPL_HOME/.local/share/tailscale; mkdir -p "$BASE/state"
VER=$(curl -sS "https://pkgs.tailscale.com/stable/?mode=json" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['TarballsVersion'])")
curl -sSL -o "$BASE/ts.tgz" "https://pkgs.tailscale.com/stable/tailscale_${VER}_amd64.tgz"
tar xzf "$BASE/ts.tgz" -C "$BASE" --strip-components=1

$BASE/tailscaled --tun=userspace-networking \
  --state=$BASE/state/tailscaled.state --socket=$BASE/state/tailscaled.sock \
  --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055

$BASE/tailscale --socket=$BASE/state/tailscaled.sock up --hostname=<name>
```

`?mode=json` returns `TarballsVersion` as a plain string — a naive
`['Tarballs']['amd64']['Version']` lookup yields an empty version and a 10-byte
tarball that `tar` rejects as `not in gzip format`.

`up` prints `Logged out. Log in at: https://login.tailscale.com/a/<id>` when no
node key exists; that login is one browser click and is the user's to do. A
reusable auth key (admin console → Settings → Keys) joins the second box with no
browser step, which matters because each sandbox otherwise needs its own login.

**The userspace catch:** a process inside this sandbox cannot dial the tailnet
directly — it must go through the SOCKS5 proxy on `localhost:1055`. Any client you
point at a tailnet address (an SSH/Termix host entry, a DB client) needs that
proxy set on it, and inbound is unaffected. Check whether the client can even
accept a SOCKS5 setting: a CLI that lacks the flags forces the UI/API path.

## Public access with Funnel

`tailscale funnel --bg <port>` publishes a local port at
`https://<node>.<tailnet>.ts.net/` with a real certificate — a public HTTPS URL
needing no public IP and no port forwarding. Funnel is off per-tailnet by
default: the first attempt prints a one-time
`https://login.tailscale.com/f/funnel?node=...` the user has to click. Cert
issuance then takes about a minute of `tls-cert-pending` in `tailscale status`,
and until it lands every request fails the TLS handshake. Funnel is HTTP(S)
only and unauthenticated — put the app's own login in front, or use
`tailscale serve` for tailnet-only.

## This sandbox cannot BE an exit node

Do not try to make the box an exit node. Exit-node routing needs a kernel TUN
device plus `CAP_NET_ADMIN`, `net.ipv4.ip_forward=1` and NAT; here none exist
(`/dev/net/tun` unopenable, `CapEff` is `cap_kill` only, `ip_forward` read-only,
`nft`/`iptables` absent). `tailscale set --advertise-exit-node` still
*succeeds* — the control plane records the route and other devices can select
it — but nothing is ever forwarded, so selecting it silently kills that peer's
internet. Never leave the advertisement set on a userspace node; clear it with
`--advertise-exit-node=false`.

## Using someone else's exit node from the sandbox

This does work, subject to the userspace catch above: the exit node only affects
traffic that goes through the SOCKS5 proxy. A plain `curl`/`ssh` exits directly
and the public IP is unchanged — which looks exactly like "the exit node is
ignored". Prove it through the proxy and watch the egress IP change:

```bash
curl -sS https://api.ipify.org                                  # direct
curl -sS --socks5-hostname localhost:1055 https://api.ipify.org # via exit node
```

## Cloudflare Tunnel — public access that does not need the tailnet

`cloudflared` (static binary from `github.com/cloudflare/cloudflared/releases`)
runs unprivileged here and needs no TUN. A *quick* tunnel needs no account at
all and is the fastest proof: `cloudflared tunnel --url http://localhost:<port>`
prints a random `https://<words>.trycloudflare.com`.

For your own hostname use a *named* tunnel. Prefer the dashboard flow plus a
tunnel token (`cloudflared tunnel run --token "$TOKEN"`; also honoured from
`$TUNNEL_TOKEN` / `$TUNNEL_TOKEN_FILE`) — that token can run exactly one tunnel
and cannot touch DNS or the rest of the account, unlike an account API token.
Two preconditions to state out loud: the public hostname must be a proxied
(orange-cloud) CNAME to `<tunnel-id>.cfargotunnel.com` for *that* tunnel, and
the dashboard Service URL must be the **app's** port — pointing it at
cloudflared's own metrics port (`20241`) merely proxies the metrics endpoint.

Verify public reachability from a fetcher genuinely off the box. A local `curl`
can pass or fail for reasons unrelated to the public path (DNS hairpin, local
trust store), so a local 200 is weak evidence and a local failure is not
evidence of an outage.

## Keys for reaching the other box (GitHub's model, roles swapped)

Generating the keypair on the TARGET is backwards: the initiator must hold the
private key, the target only needs the public half in `~/.ssh/authorized_keys`
(`chmod 700 ~/.ssh`, `chmod 600` the file). So the SSH client running inside the
sandbox generates the pair and the public key is pasted onto the target —
identical to GitHub, just the other direction. `ssh-keygen -t ed25519 -N ""
-C "<client-name>" -f <path>`; keep the private key on the box that dials.

## Serving a third-party app that hardcodes its bind

An app with a literal listen address (`const PORT = 30001;`,
`listen(PORT, "127.0.0.1")`) is unreachable no matter what `.replit` declares, and
no env var fixes it while the value is a literal. Patch the two lines to read
`process.env.<APP>_PORT` / `_HOST`, rebuild, and start with them set. Confirm the
patch reached the compiled output, not just the source, before believing a start
succeeded.

## Cloudflare edge gotchas when publishing a hostname

- **Zone "Under Attack" (`security_level: under_attack`) challenges every
  request.** A real browser clears it; automation does not — neither headless
  Chromium nor Camoufox (challenge script loads, `window._cf_chl_opt` stays
  undefined, Turnstile never renders, no clearance cookie). When a published
  hostname returns `403` with `Just a moment...`, read
  `GET /zones/{id}/settings/security_level` before blaming the tunnel or the
  browser lane.
- **A rejected `/user/tokens/verify` does not mean the token is dead.**
  Account-owned tokens answer `Invalid API Token` there while working fine for
  account-scoped calls — judge with a real call (`GET /zones`), not `verify`.
- **A tunnel token is base64 JSON** `{"a":account,"t":tunnelId,"s":secret}`.
  Decoding just `t` settles "is this hostname served by this tunnel?": compare
  it with the tunnel id the DNS CNAME points at. Two tunnels in one zone with
  the hostname attached to the wrong one fails silently and looks plausible.
- An account API token may hold `Zone:Read`/`DNS:Edit` yet lack
  `Cloudflare Tunnel:Edit`; tunnel *configuration* then has to be set in the
  dashboard.

## Rotating a credential: reading it vs. it being ambient

`replit secrets` supports `list`, `get` and `exec` — there is no `set`, so
updates happen in the Replit Secrets UI. `replit secrets exec --keys NAME --
cmd` reads the **live** store, so a rotated secret is verifiable the moment it
changes; the ambient environment only refreshes when the process tree restarts,
so a stale `$NAME` means "stale process", not "the update failed". Verify
without printing the value — length and prefix are enough:

```bash
replit secrets exec --keys NAME -- python3 -c 'import os;v=os.environ["NAME"];print(len(v), v[:5])'
```

## Make the box SSH-able without root

`sshd` runs unprivileged on a high port with your own config — no `/etc/ssh`, no
root. That is what turns a sandbox into a valid SSH target for something like a
Termix host entry:

```bash
mkdir -p ~/.sshd
ssh-keygen -q -t ed25519 -N "" -f ~/.sshd/host_ed25519
printf 'Port 2222\nListenAddress 127.0.0.1\nHostKey %s/.sshd/host_ed25519\nAuthorizedKeysFile %s/.ssh/authorized_keys\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\n' "$HOME" "$HOME" > ~/.sshd/config
nohup sshd -f ~/.sshd/config -D -e >> ~/.sshd/sshd.log 2>&1 &
grep 'Server listening' ~/.sshd/sshd.log
```

`UsePAM no` with key-only auth is what lets it start as an ordinary user; with PAM
enabled it refuses. Bind `127.0.0.1` when the only consumer is a userspace-Tailscale
peer (userspace forwards inbound to localhost, so loopback is enough); bind
`0.0.0.0` only when a real public IP must dial in.

Keep ONE stable host key. Clients that pin host-key fingerprints remember the
server's key, so regenerating `host_ed25519` (a throwaway test sshd, then the real
one) makes the client refuse the host with `denied (verification failed)` on every
later attempt — while a plain `ssh` from a shell still succeeds, which sends you
debugging the key instead of the pin. Reuse the same key file across restarts, and
when a client has already pinned an old one, clear the pin (or recreate the host
entry) rather than touching the key.

Diagnose "cannot connect" from the process list before the config: a workspace
restart kills every process started by hand, so a host that worked yesterday
answers `connection refused` today with nothing actually misconfigured. Check
uptime and `pgrep` first, then look at configuration.

## Secrets: no literal fallback, no stale identifier

- Read credentials from the environment (`replit secrets exec --keys NAME -- cmd`)
  and **fail hard when one is missing**. Never ship a real value as an
  `os.environ.get(NAME, "<literal>")` fallback: the literal becomes the thing that
  authenticates, it lands in the repo, and it hides the misconfiguration you need
  to see.
- Resolve *identifiers* (account, zone, tunnel id) from the API — not from an
  ambient env var, which goes stale silently. A stale ambient account id returns
  `403` on every call and looks exactly like a dead token.
- `replit secrets exec` accepts one `--keys` value; a second value is parsed as the
  command to run.
- `secrets` has `list`/`get`/`exec` but **no `set`** — rotations happen in the
  Secrets UI. `exec` reads the live store, so a rotated value can be verified the
  second it is saved; the ambient copy stays stale until the process tree restarts.
- `exec` can answer `PermissionDenied: secret access unavailable: not authorized`
  for the first moments after a workspace restart. That is not a broken or
  unshared secret — retry once before changing anything.

## Never print a credential-bearing response body

Create-token endpoints often answer **201**, not 200. A guard written as
`if status != 200: print(response)` therefore dumps the fresh token into the
transcript. Treat any 2xx as success, pull the single field you need, and print
only a length or a prefix. The same discipline kills the other leak shape: an
endpoint that echoes back the credential it was handed.

## Don't infer success from a 200 — read the handler

An endpoint whose name suggests "test"/"connect" may only assemble an object and
return it without dialling anything. Confirm the handler opens a connection, or
verify at the transport level yourself (`ssh -i <key> -p <port> user@host 'echo OK; id -un'`).
A 200 from a request that never connects proves nothing.

Related: list/detail APIs commonly **redact** stored secrets, so a `key` field that
comes back empty is not evidence the key is absent — check the create response or
the transport instead.

## Keep one port per service

A tunnel or ingress names a local port, so renumbering the app obliges you to
change the ingress in the same breath. Pick one port and keep the pair in sync:
behind a tunnel the local port is invisible from outside, so renumbering buys
nothing and only adds a place for the two to drift.

## Stopping these services

`pkill -f "<pattern>"` kills the command that ran it: the agent's shell wrapper
carries the whole command line, pattern included, so it matches itself and the
call returns `exit -15`. Kill by pid instead, and write the pattern so it cannot
match its own text (`[t]ailscaled`, never `tailscaled`), if `-f` is needed:

```bash
for p in $(pgrep -f "[t]ailscaled --tun"); do kill "$p"; done
```

## Persistence: .replit workflow + gitignore

- A service started by hand dies with the sandbox. To make it startable from the
  Run panel, add a `[[workflows.workflow]]` (task `shell.exec`, `args` = absolute
  launcher path) with `waitForPort = <port>` and `[workflows.workflow.metadata]
  outputType = "webview"` (or `"console"`). That is one-click, NOT boot-time:
  `runButton = "Project"` decides what the Run button fires, and
  `deploymentTarget = "autoscale"` idles to zero with no run command — an
  always-on service needs a Reserved VM.
- Give the new workflow its own port. Two workflows on the same `waitForPort`
  cannot both bind; whichever starts second never satisfies its wait.
- A workflow launcher runs in a bare shell: unset `NODE_ENV` inside the script
  (`NODE_ENV=production` is exported here and npm then omits devDependencies →
  `tsc: command not found`) and export app vars there, not in your interactive
  shell.
- Installing a third-party app under `$REPL_HOME/<app>` puts it in a tracked
  path. `.gitignore` it — a bare `node_modules` rule does NOT cover it, because
  the app's deps nest at `<app>/node_modules`. Confirm with
  `git check-ignore -v <app>/` and `git status` before reporting it done.
- Do not edit a gitignored install tree and present it as stock upstream. Say
  which files you patched, and why an env var alone could not do it.
