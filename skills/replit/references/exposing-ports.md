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
