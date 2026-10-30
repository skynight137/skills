# SSH bridge sandbox→sandbox (no public IP)

Goal: get a real shell from workspace A (where the agent runs) into workspace B
(another box the operator owns), so the agent stops depending on a browser.

## Lane choice

- `sshx` link: **not a CLI channel.** `sshx` only *creates* sessions; joining an
existing link is browser-only (xterm canvas, no attach subcommand). Driving the
canvas works but is slow — use it only as a fallback, and never promise it as
the transport.
- Preferred: real `sshd` on B, key-only, plus a reachability path. Then the agent
works from its own terminal.

## Procedure (`setup.sh --tailscale --join`)

Everything below is already in the skill — the operator runs **one** command on B,
no script to copy, no key to hardcode. Satu perintah, tanpa dua fase: `--tailscale`
memasang biner, `--join` menyiapkan sshd (host key, config, `authorized_keys`, dirs,
symlink `~/.ssh`), menyalakan sshd + tailscaled dan join tailnet. Tanpa `--join`,
`--tailscale` cuma memasang dan tak menyalakan apa pun:

```bash
TAILSCALE_AUTH_KEY=tskey-auth-... bash <skill>/scripts/setup.sh --tailscale --join
```

The auth key is read from the **environment only** (never baked into the script, so
rotating/revoking it needs no edit). On later boots the stored node identity is
enough and the key may be omitted; the `.replit` workflow runs the same command.

### Machines missing from the admin console

- **Revoking an auth key does not remove machines.** The key only authorises a join; every
  node then holds its own node key and stays listed until you delete it. A box that never
  appears was not "blocked by the revoked key".
- **A re-join reuses the identity already on disk.** If the state dir carries a node key,
  `up` short-circuits: the box stays exactly as it was and no new machine entry is created.
  Wipe `$TAILSCALE_STATE_DIR` first when the point of the join is a fresh machine.
- **Ephemeral nodes are deleted seconds after the daemon stops** — they exist only while the
  box lives, so they are the wrong choice for anything you must find in the console later.
  Disable Ephemeral on every machine you need to keep.
- **A tagged key without a tag owner that auto-approves** leaves the node unauthorized: it
  never reaches the machine list. Check for an `AuthURL` in `status --json`.

### Reading the auth key from a Secret without a restart

Replit Secrets reach only processes started AFTER they were set — the agent's own shell
predates the change and sees nothing, and grepping `.replit` finds nothing either (Secrets
are a different store from `[userenv.shared]`). Recover the value from a live process
environment instead of asking the operator to paste it:

```bash
for f in /proc/*/environ; do
  tr '\0' '\n' <"$f" 2>/dev/null | grep -q '^TAILSCALE_AUTH_KEY=.' && { tr '\0' '\n' <"$f"; break; }
done
```

`/proc/1/environ` is often denied; same-uid processes are readable. Restarting the workflow
is the alternative, not a prerequisite.

### Syncing a changed skill to the far box

`rsync` is usually absent there (`bash: rsync: command not found`). Use tar over ssh, with
`--strip-components=1` so the archive's own `skills/` prefix does not nest (`skills/skills/
replit`) — the failure is silent and the far copy keeps the OLD scripts:

```bash
tar cz skills/replit | ssh "$host" 'tar xzf - -C ~/workspace/.agents/skills --strip-components=1'
```

Then prove the copy landed by grepping a string only the new version has, and only then run
`--join` there. Delete the stale sibling dir if a bad extract already nested one.

- **`scp` is usually absent on the far box too** (`exit 127`). Ship a single file with the
  ssh side doing the write: `ssh "$host" 'cat > /tmp/gate.sh' < local.sh`. It also skips the
  quoting that a remote `bash -c` would need.
- **`ssh` exiting 255 with only `Warning: Permanently added '[host]:PORT'` is not a failure** —
  that is the known_hosts notice on a first connect. Judge by the real output (a body, a diff,
  an exit from the remote command), never by the code alone, or healthy steps read as dead.


- **Wrong tailnet outranks every other cause when a fresh join shows nothing in the console you are watching.** An auth key minted in another account joins an EMPTY tailnet: the node reports `Running`, gets a fresh 100.x address, and has `peers: 0`, while every machine you expected is absent. Compare `MagicDNSSuffix` from `tailscale --socket=<sock> status --json` on the joining box with the one on the box you watch from — a different `tailXXXXXX.ts.net` proves an account mismatch, not a broken key. A correct join sees neighbours within seconds, so `peers: 0` is the tell. Only a key from the account that owns the machines fixes it; rejoining never does.

### Try a join without disturbing the live node

Second daemon, own state dir, own socket, a different SOCKS port — the live node keeps its identity and nothing must be re-added afterwards:

```bash
D=$WORKSPACE/.local/share/tsjoin; mkdir -p "$D/state"
$WORKSPACE/.local/bin/tailscaled --tun=userspace-networking \
  --socks5-server=localhost:1056 --outbound-http-proxy-listen=localhost:1056 \
  --state="$D/state/tailscaled.state" --statedir="$D/state" --socket="$D/state/tailscaled.sock" &
$WORKSPACE/.local/bin/tailscale --socket="$D/state/tailscaled.sock" up \
  --authkey="$TAILSCALE_AUTH_KEY" --hostname=<probe> --accept-routes=false
```

Read `Self.HostName`, `Self.Online`, `BackendState`, `AuthURL` and the peer count back from that same socket; tear down with `down` then `rm -rf "$D"`. Two daemons cannot share the default SOCKS port, hence 1056.

Replit Secrets reach app processes only, never a shell started later: to exercise a key already configured, lift it out of a running process — `tr '\0' '\n' < /proc/<pid>/environ | sed -n 's/^NAME=//p'`, looping the pids and skipping `/proc/1` (permission denied) — rather than asking the operator to retype a secret.

- Revoking an auth key closes the *join* path only. A node that is already joined has its
  own node key and stays authorized (and listed) until that key expires or is removed —
  so a vanished machine has another cause and revoking again fixes nothing.
- Check, in this order: the node is ephemeral (removed seconds after its daemon stops);
  the box rejoined on an existing tailscaled state, so `up` short-circuits and no new
  machine entry is created; the key is tagged and no tag owner auto-approves, which leaves
  the node sitting unauthorized; the box is logged into a different tailnet.
- A clean new machine entry means stopping the daemon on the box, deleting the state
  (`$TAILSCALE_DATA_DIR`), then `--join` with a key. That regenerates the NODE identity
  only — the sshd host key lives in the remote-shell dir and `known_hosts` stays valid.

### Auth key lifecycle: reusable + ephemeral together

- **Reusable** is what makes one key serve many boxes: it stays valid until it expires
  or is revoked, so every fresh disposable box can join without a new key per box.
- **Ephemeral** removes the node from the tailnet on its own shortly after the daemon
  stops. For disposable Replit boxes that is the whole point: a wiped box leaves no
  ghost node, no `-1`/`-2` suffix chain, and nothing to prune by hand.
- So for dev targets: keep BOTH on. Set an explicit `--expiry` on the reusable key and
  revoke it when the cycle ends; if the key is tag-scoped, ephemeral cleanup relies on
  the node being tagged, so tag it (`--tags tag:repl-test`) and never leave ephemeral
  nodes untagged.
- Ephemeral is the wrong choice only where the box must keep a stable identity across
  restarts (the machine you remote FROM, or one with DNS/MagicDNS entries pinned):
  there, join with a non-ephemeral key and let the state dir carry the identity.

### The node name rides in the workflow args

An existing workflow entry is upgraded, never blindly rewritten, so the node name has to
be carried explicitly: with `TAILSCALE_NODE_NAME` set the task line is pinned to
`TAILSCALE_NODE_NAME=<name> bash … --tailscale --join --workflow`, and a rename rewrites
the pin instead of appending a second one. Unpinned, the console keeps the last say —
which is what a box whose name you rename on the dashboard wants.

To rename a joined box use `tailscale set --hostname=<name>`; it takes effect at once and
the MagicDNS name follows. Deleting a machine is console-only (`tailscale` has no local
delete), so a wiped identity leaves an offline ghost for you to remove there.

### Moving a box to another tailnet

The auth key decides which tailnet a join lands in, and a box already joined keeps its
old identity no matter what key you hand it. To move: stop the daemon, wipe the state
dir (`$TAILSCALE_STATE_DIR`, host key included), then `--join` with a key from the
target tailnet. The node reappears as a new machine there and disappears from the old
one only after you delete it in that console. `tailscale status` prints the tailnet
suffix (`.MagicDNSSuffix` in `--json`): if two boxes show different suffixes they are
not in the same tailnet and will never ping each other, whatever the dashboard says.

Daemon liveness is decided by the socket answering, never by a pid pattern: a second
daemon on another socket (a test node, a second tailnet) matches any pattern and would
otherwise suppress the start, leaving the real socket dead.

### Paths come from the rc var registry, the node name does not

`TAILSCALE_DATA_DIR`, `TAILSCALE_STATE_DIR` and `TAILSCALE_SOCKET` are registered by
`install_tailscale` (and re-registered by `--fix`), so the managed rc block exports
them: every consumer reads the socket path from the environment instead of
re-spelling it.

`TAILSCALE_NODE_NAME` stays out of the rc on purpose. Which name a machine answers to
is the operator's decision per machine, so it is pinned where the machine is described
— in-line on the workflow `args` (`TAILSCALE_NODE_NAME=<name> bash ... --tailscale --join --workflow`) or in a Replit secret — not exported to every shell of the box.

### Why the flag says `join` and the clean target says `tailscale`

`--tailscale` is the binary install; `--join` is the machine entering the tailnet —
until it joins, no other machine can reach it, so `join` names the act. The state dir
keeps `join-sshd` on purpose: moving it would mint a new sshd host key and every
client's `known_hosts` would warn.

What `install_join` does, in order (all idempotent, re-run to repair):

1. `~/.ssh` → symlink to `$REPL_HOME/.ssh` (persistent). An existing `~/.ssh` is
   moved in first, not discarded, so the operator's own `config`/keys survive a
   restart too.
2. host key + `authorized_keys` + `sshd_config` under `$REPL_HOME/.ssh/join-sshd/`;
   the hop key is added once, duplicates are grepped out.
3. `sshd -t`, start detached, then **verify the banner and loopback auth**; a live
   `sshd` is skipped rather than killed (killing it cuts the current session).
4. absolute privsep dirs (`/run/sshd`, `/var/empty`) so a non-root sshd
   can start.
5. tailscaled userspace + SOCKS5 on `localhost:1055`, state in
   `$TAILSCALE_DATA_DIR/state` — `tailscale up` runs only after the socket answers.
6. ONE command line for the operator to add as a Replit-UI workflow task, PRINTED not
   written, path relative to the workspace (see below).
7. prints the client-side hop in every form, best first: `tailscale nc %h %p`,
   `tailscale --socket=<sock> nc`, `ncat --proxy … --proxy-type socks5`, and only
   then `nc -X 5 -x`. `nc` is not portable: netcat-openbsd has `-X`, netcat-traditional
   and busybox `nc` answer `invalid option -- 'X'`, so never print that form alone.

Verify from A with `-o BatchMode=yes -o ConnectTimeout=8`. `SSH-2.0-` banner on
loopback but timeout from A = the tailnet leg, not sshd; `Connection closed` = a
proxy answered and the port is not published.

`--clean tailscale` stops both daemons (sshd via its pid file, tailscaled matched by OUR
socket only), deletes `$RS_DIR` and the tailnet state dir, drops the `hermes-join-hop` line
from `~/.ssh/authorized_keys`, and sweeps exactly the ssh surface join created: `~/.ssh/config`
blocks whose body names `$RS_PORT` plus a tailnet hop, and `[host]:$RS_PORT` lines in
`known_hosts`. Foreign config blocks, the `~/.ssh` symlink and the `.replit` workflow entry are
left alone — a reboot brings the daemon back, and the entry is one line to delete.

Run it **detached** (`setsid bash setup.sh --clean tailscale >& clean.log &`) when the shell
itself arrives over that sshd: killing tailscaled takes the tailnet leg down and the
session with it, so the client times out before the sweep finishes. A fresh `--join` after
that needs `TAILSCALE_AUTH_KEY` again (the wiped state dir held the node identity).

## Surviving a restart (Replit)

`$HOME` is **wiped** on every restart (`.ssh`, `.bashrc`, `.local/bin`, `~/.ts` all go);
`$REPL_HOME` (the repl workspace) alone persists. Consequences, both already handled by
`install_join`:

- `~/.ssh` itself is a symlink into `$REPL_HOME/.ssh` (persistent, so ssh `config`
  and `known_hosts` also survive); host key, sshd config, authorized key, log →
  `$REPL_HOME/.ssh/join-sshd/`; tailnet node state →
  `$REPL_HOME/.local/share/tailscale/state/`; managed `tailscale`/`tailscaled` binaries →
  `$REPL_HOME/.local/bin/`. Nothing a reboot needs may live in `$HOME`.
- a node whose key sits in `$HOME` re-registers from scratch on every boot: new `100.x`
  address, new node name, and every saved URL / `.ssh/config` entry rots. Reusing the
  persistent key keeps the address.
- **autostart belongs to `.replit`, never to a shell rc.** A daemon started from `.bashrc`
  or `.profile` re-fires every time the operator opens a terminal, and the guard for it has
  to be re-derived in each of those shells. Add it in the Replit UI instead — new task,
  type `shell.exec`, command:

  ```
  bash <skill-dir>/scripts/setup.sh --tailscale --join --workflow      # path relatif ke workspace
  ```

  `install_join` prints that one line and leaves `.replit` alone. The path is made
  relative to the workspace whenever the skill lives inside it, because a workflow runs
  with the workspace as cwd — moving or renaming the skill dir then cannot leave a dead
  absolute path behind; only a copy outside the workspace is printed absolute, with a
  note to move it in. A whole block is more
  than the operator needs: the UI creates the workflow, and the name and ordering stay
  theirs without touching the file (a pasted second `name` collides with a workflow they
  already have, and `[workflows]` sits in a different place on every host). Anything that
  already points at `setup.sh --join` counts as wired; an old entry is upgraded in place by
  appending `--workflow` to its `args`, and one that points at a path which no longer exists is
  reported (skill dir moved) instead of being silently accepted. The `--workflow` check runs only
  after the path check, or a dead path hides behind the "already wired" branch. The skill dir is persistent, which is why the command
  points at `setup.sh` instead of a copied script — no duplicate to drift.
- **Renaming the node is safe, but only if the skill does not re-assert the OS hostname.**
  `tailscale up --hostname=$(hostname)` on every start silently undoes a rename made in the
  admin console, so `--hostname` is now sent only on the first join (authkey path) or when
  `TAILSCALE_NODE_NAME` is set. The `100.x` address is keyed to the node identity, not its name, so
  `~/.ssh/config` entries written against the IP survive a rename untouched. Change the name
  with `tailscale set --hostname=<name>` or the console; `up` refuses to change one pref
  without every non-default being restated (`--ssh`, `--exit-node-allow-lan-access`), which
  is why the start path uses `set` and keeps `up` only as the not-yet-logged-in fallback.
  Setting `TAILSCALE_NODE_NAME` is how the skill side makes a name stick: when exported, every
  `--join` asserts it, so pin it in the workflow `args`
  (`TAILSCALE_NODE_NAME=hermes-agent bash <skill>/scripts/setup.sh --join --workflow`) rather than trusting
  the OS hostname — and not in an rc, which re-fires per terminal. A retired name can linger
  in `tailscale status` until removed in the console; the live node is the one under `self`.
  `tailscale set --hostname=` returns before the control plane has applied it, so POLL the
  JSON `Self.HostName` (a few seconds) instead of reading once — a single read right after the
  call still shows the old name and looks like the call failed.
- **Restarting a daemon that carries your own tunnel severs it.** `tailscaled` backs the
  SOCKS path your `ssh` runs over, so a restart issued inline dies with the command still in
  flight. Write the restart to a file on B and launch it detached
  (`setsid bash /path/restart.sh >/path/out 2>&1 &`), then re-probe from A after a pause and
  read the log file over a fresh connection. Same for anything the bridge depends on.
- **A re-registered node gets a `-1` / `-2` suffix** (`server2-1`, `server2-2`) and a NEW
  `100.x` address; the old name stays listed as offline long after it is dead. Match by the
  live suffix, then rewrite the local `ProxyCommand`/`HostName`, never the stale entry.
- **The `.replit` workflow is report-only, and one line is the whole notice.** Writing the
  file means owning something that is not ours: a second `name = "remote-shell"` collides with a
  workflow the operator already uses, and `[workflows]` sits in a different place on every
  host. But a full `[[workflows.workflow]]` block is also more than needed — the UI creates
  the task for them — so `--join` prints just `bash <skill-dir>/scripts/setup.sh --tailscale --join --workflow`
  and leaves the file alone; name and ordering stay theirs.
- **Print the `args` path workspace-relative, never absolute.** Workflows run with the
  workspace as cwd, so a relative path survives the operator moving or renaming the skill
  dir; an absolute `$RS_SKILL_ROOT` breaks on the next move. Only a copy outside the
  workspace is printed absolute, with a note to move it in.
- **When an entry already points at `setup.sh --join`, check its path BEFORE the `--workflow`
  check.** Order the other way and a dead path hides behind the "already wired" branch
  forever: report `skill dipindah?` and print the current line instead of skipping. Also
  grep only the line that carries `--join` (`grep -oE 'bash +[^"]*setup\.sh --join' | head -1`)
  — other workflows in the same file (`--camofox`, …) point at that very script, so a bare
  `head -1` of all `setup.sh` lines reads the wrong one and flags a healthy entry.
  Upgrading an old entry in place is additive and idempotent: `--join` is inserted
  straight after `--join` (so an existing `--workflow` survives) and `--workflow` is appended when
  missing, both then verified by grep. Note GNU sed rejects `|` as the delimiter on these
  patterns — use `s#…#…#`.
- **A workflow whose command exits is DEAD.** Replit reaps the job the moment the task
  command returns, taking the daemons with it, and a run whose output is redirected to a
  file shows nothing. `--workflow` (implies `--join`) prints the steps to the terminal
  and ends with `tail -F` on the tailscaled log, so one foreground process (and visible
  output) holds the job open. Every other flag is a one-shot install: use `--join` by hand,
  `--join --workflow` in `.replit [workflows]`.
- **The SOCKS relay fails intermittently** (`General SOCKS server failure` while the same
  probe answered a minute earlier). Retry the probe 2–3× before declaring the port dead, and
  judge reachability by the SSH banner (`SSH-2.0-…`) instead of `nc -z`, which returns success
  on connect and says nothing about the listener behind the relay.

## Pitfalls (each cost a round trip)

- **Test the workflow notice against throwaway copies, not the live workspace.**
  `cp -a <skill> /tmp/ws/replit` with `REPL_HOME=/tmp/ws` and a hand-written `.replit`
  gives all four paths in one pass — inside the workspace (relative), outside
  (absolute + note), stale entry (warning), valid entry (silent skip) — and leaves the
  live `.replit` untouched (assert it with an `md5sum` before/after). Also override
  `RS_PORT`, `XDG_BIN_HOME` and `TAILSCALE_DATA_DIR` per case, or the run installs
  tailscale and binds the operator's real port from a test copy. Every upgrade case is
  run **twice**: the second pass must answer "already registered" byte-identically,
  which is the only proof the rewrite is a fixed point. A shared helper script in the
  scratch dir beats pasting the loop, and quote `$args` inside it — an unescaped `"`
  from the sample `args` line ends the outer string.
- **Print the log before dying.** A `die()` that exits before `tail -n 8 $LOG`
  hides the cause and the operator can only quote the last line back.
  Order: dump tail → then exit.
- **Never resolve binaries with `command -v` alone.** PATH differs per shell on
  these boxes, so `command -v sshd` can return nothing in one call and a store
  path in the next. Probe absolute candidates (`/nix/store/*openssh*/bin/sshd`,
  `/nix/store/*replit-runtime-path*/bin/sshd`, `/run/current-system/sw/bin/sshd`,
  `/usr/sbin/sshd`) and keep `nix build nixpkgs#openssh` / `apt-get` as fallbacks.
- **`sshd` as non-root needs `/run/sshd`.** Without it the daemon exits
  immediately with "Missing privilege separation directory". Also create
  `/var/empty`, both `755`.
- **Do not truncate the config with `>` on `authorized_keys` only.** Rewriting it
  each run and inserting the local verify key only when the key file is absent
  means the second run has no verify key and auth fails. Always
  `grep -qF … || printf … >>` it back.
- **Bind `[IP_REDACTED]`, not `[IP_REDACTED]`.** With loopback-only, port 6800 is
  not reachable through the platform proxy even though it answers on localhost.
  Keep `AddressFamily inet` (IPv4 only) so probes cannot land on `[IP_REDACTED]`.
- **Banner probe: read a line, not `head -c 24`.** The banner is 22 bytes, so
  `head -c 24` blocks until the timeout kills it and returns empty — the probe
  reports "no banner" on a perfectly healthy daemon. Use
  `exec 3<>/dev/tcp/$H/$P; IFS= read -r -t 2 l <&3`, retry ~10×, and try
  `[IP_REDACTED]` too.
- **Kill the previous instance before a `-ddd` debug run**, otherwise it loses
  the bind race and you debug the bind failure instead of the real error.
- `pkill -f "sshd -f …"` also matches the wrapper of the very command you are
  running and kills it; use `pkill -x sshd`.
- `pkill -f 'join-sshd/sshd_config'` kills **every** join listener on the box, not just
  the port you meant: the pattern is the shared config path. Restart the one you still
  need with `--join` (and `RS_PORT=` if it is not the default) right after.
- GNU sed here rejects `|` as the `s` delimiter on these `args`/quote patterns
  ("unknown option to `s'"); use `s#…#…#`.
- **`cmd && cmd` as the last statement of a branch returns 1 under `errexit`**, so a
  branch that only wanted to print a note exits 1 and the runner reports the step as
  failed. Wrap it: `if _rs_cmd_external; then ok "…"; fi`.
- **Prove "nothing was launched" with the listener, not `pgrep -f` counts.** The probe
  shell's own command line contains the pattern, so pgrep reports a fresh PID on every
  run and a `--tailscale`-only run looks like it started something. Compare the banner
  (`SSH-2.0-…` on the port) before/after, or anchor the pattern so the wrapping shell
  cannot match: `pgrep -af '^[^ ]*(sshd|tailscaled) '` (the wrapper's cmdline starts
  with the bash path, so `^[^ ]*sshd` never matches it — `^[^ ]*tailscaled` likewise).

## Delivery rule (operator preference)

Do **not** paste long scripts into chat. Write the file, give the absolute path,
and let the operator copy it themselves; quote only a short hash/size for parity
(`md5sum`, line count). Ask for the **whole** script output, not "the last line"
— the terminal line is identical on every failure, only the diagnostics differ.

An absolute local path is only reachable on the SAME box. The skill therefore has
to exist on B before `--join` can run there — clone/copy the skill dir once (it is
persistent), then the whole setup is one command and stays re-runnable. If a file on
B must be delivered by URL, pin it at the commit SHA
(`.../<sha>/skills/replit/scripts/setup.sh`): a branch name drifts, a SHA cannot.
Verify the raw URL answers 200 first, and never put a token in the URL when the
repo is already public.

## Reachability facts on Replit-style boxes

- `[IP_REDACTED]` in `/etc/hosts` maps each repl to its own domain; ports are
  proxied per-domain, so a random high port is usually closed by the proxy
  (`Connection closed by <proxy-ip>`) until it is published.
- Domain port 22 answers `SSH-2.0-Replit-SSH-Proxy`: the platform already fronts
  an SSH proxy on 22, so `authorized_keys` in the *default* `~/.ssh` (not the
  isolated `AuthorizedKeysFile`) is what it honours.
- Outbound-only boxes can never be reached by dialling in; when no port is
  published the fallback is a reverse tunnel or the sshx canvas.
- **A listed peer is not a reachable machine.** Three things are required, in order:
  the peer is online in `tailscale status`, sshd was prepared *on that box*
  (`setup.sh --join`), and a hop key sits in its `authorized_keys` — which the
  prep does for you (the `hermes-join-hop` key is authorized by default; extend with
  `RS_AUTHORIZED_KEYS`). Onboarding a machine is therefore: join it with the auth key,
  run the prep there, then add a `Host` block here. Answer "can we reach every
  machine?" as "every machine that has done this", never as "any host on the tailnet".
- **Probe through the local SOCKS relay, never by hostname.** The tailnet userspace
  relay listens on `localhost:1055`; `nc -X 5 -x 127.0.0.1:1055 -z <ip> <port>` is the
  reachability test, and `scripts/probe-tailnet-peers.sh [port]` walks every real peer.
  `General SOCKS server failure` means the peer is offline or the port is closed — read
  the `offline` marker in `tailscale status` before editing the ssh config.
- **A re-registering node changes its `100.x` address**, so a saved `HostName` rots
  silently and `ssh` fails with `Connection closed by UNKNOWN port 65535` while the
  config still looks right. Rewrite `HostName` from live `tailscale status` output, and
  when the relay port changes, fix every `ProxyCommand` with it.
- **Resolve "which node is this machine" from the JSON `Self`, never from the status table.**
  `tailscale status` prints an unlabelled IP/name/owner/os table — the box's own row looks
  exactly like a peer's, so a name remembered from chat gets pinned onto the wrong machine
  (`hermes-syad` reads like "the box", and is a stranger peer that has been offline for
  hours). `tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["HostName"])'`
  answers it, and `scripts/probe-tailnet-peers.sh` prints that row as `self` first.
- **Prove a rename by the address, not by the name.** Compare the self `100.x` from
  `status --json` before and after, then run `ssh -o BatchMode=yes <host> 'echo OK'` against
  a peer you already hold a `Host` block for. The address is keyed to the node identity, so
  an unchanged IP plus a working session is the evidence; a changed or renamed node in the
  table proves nothing on its own.
- `funnel-ingress-node` entries in `tailscale status` are Tailscale's own IPv6-only
  relay infra, not operator machines — never count them as targets.
