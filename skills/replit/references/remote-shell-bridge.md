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

## Procedure (`setup.sh --remote-shell`, then `--start`)

Everything below is already in the skill — the operator runs **one** command on B,
no script to copy, no key to hardcode. `--remote-shell` alone only PREPARES (host key, config,
`authorized_keys`, dirs, binaries, `~/.ssh` symlink) and launches nothing; `--start`
is what brings the daemons up, so a preparing run never leaves a surprise listener
behind:

```bash
TAILSCALE_AUTH_KEY=tskey-auth-... bash <skill>/scripts/setup.sh --remote-shell --start
```

The auth key is read from the **environment only** (never baked into the script, so
rotating/revoking it needs no edit). On later boots the stored node identity is
enough and the key may be omitted; the `.replit` workflow runs the same command.

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

### Paths come from the rc var registry, the node name does not

`TAILSCALE_DATA_DIR`, `TAILSCALE_STATE_DIR` and `TAILSCALE_SOCKET` are registered by
`install_tailscale` (and re-registered by `--fix`), so the managed rc block exports
them: every consumer reads the socket path from the environment instead of
re-spelling it.

`TAILSCALE_NODE_NAME` stays out of the rc on purpose. Which name a machine answers to
is the operator's decision per machine, so it is pinned where the machine is described
— in-line on the workflow `args` (`TAILSCALE_NODE_NAME=<name> bash ... --remote-shell
--start --wf`) or in a Replit secret — not exported to every shell of the box.

### Why the flag says `remote-shell` and the dir still says `e2e-sshd`

`--e2e` described a test phase, but the tool is the box's inbound shell: `--remote-shell`
(alias `--e2e`, still accepted) is what it does. The state dir keeps the old name on
purpose — moving it would mint a new sshd host key, and every client's `known_hosts`
would warn on the next connect.

What `install_remote_shell` does, in order (all idempotent, re-run to repair):

1. `~/.ssh` → symlink to `$REPL_HOME/.ssh` (persistent). An existing `~/.ssh` is
   moved in first, not discarded, so the operator's own `config`/keys survive a
   restart too.
2. host key + `authorized_keys` + `sshd_config` under `$REPL_HOME/.ssh/e2e-sshd/`;
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

`--clean remote-shell` removes the sshd dir and stops it, keeps the `~/.ssh` symlink and the
workflow entry (a reboot would just bring it back).

## Surviving a restart (Replit)

`$HOME` is **wiped** on every restart (`.ssh`, `.bashrc`, `.local/bin`, `~/.ts` all go);
`$REPL_HOME` (the repl workspace) alone persists. Consequences, both already handled by
`install_remote_shell`:

- `~/.ssh` itself is a symlink into `$REPL_HOME/.ssh` (persistent, so ssh `config`
  and `known_hosts` also survive); host key, sshd config, authorized key, log →
  `$REPL_HOME/.ssh/e2e-sshd/`; tailnet node state →
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
  bash <skill-dir>/scripts/setup.sh --remote-shell --start --wf      # path relatif ke workspace
  ```

  `install_remote_shell` prints that one line and leaves `.replit` alone. The path is made
  relative to the workspace whenever the skill lives inside it, because a workflow runs
  with the workspace as cwd — moving or renaming the skill dir then cannot leave a dead
  absolute path behind; only a copy outside the workspace is printed absolute, with a
  note to move it in. A whole block is more
  than the operator needs: the UI creates the workflow, and the name and ordering stay
  theirs without touching the file (a pasted second `name` collides with a workflow they
  already have, and `[workflows]` sits in a different place on every host). Anything that
  already points at `setup.sh --remote-shell` counts as wired; an old entry is upgraded in place by
  appending `--wf` to its `args`, and one that points at a path which no longer exists is
  reported (skill dir moved) instead of being silently accepted. The `--wf` check runs only
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
  `--start` asserts it, so pin it in the workflow `args`
  (`TAILSCALE_NODE_NAME=hermesagent bash <skill>/scripts/setup.sh --remote-shell --start --wf`) rather than trusting
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
  the task for them — so `--remote-shell` prints just `bash <skill-dir>/scripts/setup.sh --remote-shell --start --wf`
  and leaves the file alone; name and ordering stay theirs.
- **Print the `args` path workspace-relative, never absolute.** Workflows run with the
  workspace as cwd, so a relative path survives the operator moving or renaming the skill
  dir; an absolute `$RS_SKILL_ROOT` breaks on the next move. Only a copy outside the
  workspace is printed absolute, with a note to move it in.
- **When an entry already points at `setup.sh --remote-shell`, check its path BEFORE the `--wf`
  check.** Order the other way and a dead path hides behind the "already wired" branch
  forever: report `skill dipindah?` and print the current line instead of skipping. Also
  grep only the line that carries `--remote-shell` (`grep -oE 'bash +[^"]*setup\.sh --remote-shell' | head -1`)
  — other workflows in the same file (`--camofox`, …) point at that very script, so a bare
  `head -1` of all `setup.sh` lines reads the wrong one and flags a healthy entry.
  Upgrading an old entry in place is additive and idempotent: `--start` is inserted
  straight after `--remote-shell` (so an existing `--wf` survives) and `--wf` is appended when
  missing, both then verified by grep. Note GNU sed rejects `|` as the delimiter on these
  patterns — use `s#…#…#`.
- **A workflow whose command exits is DEAD.** Replit reaps the job the moment the task
  command returns, taking the daemons with it, and a run whose output is redirected to a
  file shows nothing. `--wf` (implies `--remote-shell --start`) prints the steps to the terminal
  and ends with `tail -F` on the tailscaled log, so one foreground process (and visible
  output) holds the job open. Every other flag is a one-shot install: use `--remote-shell` by hand,
  `--remote-shell --start --wf` in `.replit [workflows]`.
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
- `pkill -f 'e2e-sshd/sshd_config'` kills **every** e2e listener on the box, not just
  the port you meant: the pattern is the shared config path. Restart the one you still
  need with `--remote-shell --start` (and `RS_PORT=` if it is not the default) right after.
- GNU sed here rejects `|` as the `s` delimiter on these `args`/quote patterns
  ("unknown option to `s'"); use `s#…#…#`.
- **`cmd && cmd` as the last statement of a branch returns 1 under `errexit`**, so a
  prepare that only wanted to print a note exits 1 and the runner reports the step as
  failed. Wrap it: `if _rs_cmd_external; then ok "…"; fi`.
- **Prove "nothing was launched" with the listener, not `pgrep -f` counts.** The probe
  shell's own command line contains the pattern, so pgrep reports a fresh PID on every
  run and a prepare-only run looks like it started something. Compare the banner
  (`SSH-2.0-…` on the port) before/after, or anchor the pattern so the wrapping shell
  cannot match: `pgrep -af '^[^ ]*(sshd|tailscaled) '` (the wrapper's cmdline starts
  with the bash path, so `^[^ ]*sshd` never matches it — `^[^ ]*tailscaled` likewise).

## Delivery rule (operator preference)

Do **not** paste long scripts into chat. Write the file, give the absolute path,
and let the operator copy it themselves; quote only a short hash/size for parity
(`md5sum`, line count). Ask for the **whole** script output, not "the last line"
— the terminal line is identical on every failure, only the diagnostics differ.

An absolute local path is only reachable on the SAME box. The skill therefore has
to exist on B before `--remote-shell` can run there — clone/copy the skill dir once (it is
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
  (`setup.sh --remote-shell --start`), and a hop key sits in its `authorized_keys` — which the
  prep does for you (the `hermes-e2e-hop` key is authorized by default; extend with
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
