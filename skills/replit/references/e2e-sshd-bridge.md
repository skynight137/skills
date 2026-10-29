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

## Procedure (`setup.sh --e2e`)

Everything below is already in the skill — the operator runs **one** command on B,
no script to copy, no key to hardcode:

```bash
TAILSCALE_AUTH_KEY=tskey-auth-... bash <skill>/scripts/setup.sh --e2e
```

The auth key is read from the **environment only** (never baked into the script, so
rotating/revoking it needs no edit). On later boots the stored node identity is
enough and the key may be omitted; the `.replit` workflow runs the same command.

What `install_e2e` does, in order (all idempotent, re-run to repair):

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
6. a ready-to-paste `[[workflows.workflow]]` block, PRINTED not written (see below),
   with a suggested name that does not collide (`e2e-wf`, `e2e-wf1`, ...).
7. prints the client-side hop in every form, best first: `tailscale nc %h %p`,
   `tailscale --socket=<sock> nc`, `ncat --proxy … --proxy-type socks5`, and only
   then `nc -X 5 -x`. `nc` is not portable: netcat-openbsd has `-X`, netcat-traditional
   and busybox `nc` answer `invalid option -- 'X'`, so never print that form alone.

Verify from A with `-o BatchMode=yes -o ConnectTimeout=8`. `SSH-2.0-` banner on
loopback but timeout from A = the tailnet leg, not sshd; `Connection closed` = a
proxy answered and the port is not published.

`--clean e2e` removes the sshd dir and stops it, keeps the `~/.ssh` symlink and the
workflow entry (a reboot would just bring it back).

## Surviving a restart (Replit)

`$HOME` is **wiped** on every restart (`.ssh`, `.bashrc`, `.local/bin`, `~/.ts` all go);
`$REPL_HOME` (the repl workspace) alone persists. Consequences, both already handled by
`install_e2e`:

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
  to be re-derived in each of those shells. Use a `.replit` workflow instead:

  ```toml
  [workflows]

  [[workflows.workflow]]
  name = "e2e-wf"   # bebas, pakai yang belum dipakai
  author = "runner"
  mode = "sequential"

  [[workflows.workflow.tasks]]
  task = "shell.exec"
  args = "bash /home/runner/workspace/skills/replit/scripts/setup.sh --e2e --wf"
  ```

  `install_e2e` PRINTS that block and leaves `.replit` alone: the file is the operator's,
  and a second `name` collides with a workflow they already have. Nama, urutan, dan task
  milik mereka; yang sudah menunjuk `setup.sh --e2e` dianggap beres. The skill dir is
  persistent too, which is why the workflow points at `setup.sh` instead of a copied
  script — no duplicate to drift.
- **Restarting a daemon that carries your own tunnel severs it.** `tailscaled` backs the
  SOCKS path your `ssh` runs over, so a restart issued inline dies with the command still in
  flight. Write the restart to a file on B and launch it detached
  (`setsid bash /path/restart.sh >/path/out 2>&1 &`), then re-probe from A after a pause and
  read the log file over a fresh connection. Same for anything the bridge depends on.
- **A re-registered node gets a `-1` / `-2` suffix** (`server2-1`, `server2-2`) and a NEW
  `100.x` address; the old name stays listed as offline long after it is dead. Match by the
  live suffix, then rewrite the local `ProxyCommand`/`HostName`, never the stale entry.
- **The `.replit` workflow is report-only.** Appending a block means owning a file that is
  not ours: a second `name = "e2e"` collides with a workflow the operator already uses, and
  every host differs in where `[workflows]` sits. So `--e2e` prints the block and leaves the
  file alone; the operator names it and decides the ordering. Anything already pointing at
  `setup.sh --e2e` counts as wired (no nagging), and an old entry is upgraded in place by
  appending `--wf` to its `args` line.
- **A workflow whose command exits is DEAD.** Replit reaps the job the moment the task
  command returns, taking the daemons with it, and a run whose output is redirected to a
  file shows nothing. `--wf` (= `--e2e` in workflow mode) prints the steps to the terminal
  and ends with `tail -F` on the tailscaled log, so one foreground process (and visible
  output) holds the job open. Every other flag is a one-shot install: use `--e2e` by hand,
  `--e2e --wf` in `.replit [workflows]`.
- **The SOCKS relay fails intermittently** (`General SOCKS server failure` while the same
  probe answered a minute earlier). Retry the probe 2–3× before declaring the port dead, and
  judge reachability by the SSH banner (`SSH-2.0-…`) instead of `nc -z`, which returns success
  on connect and says nothing about the listener behind the relay.

## Pitfalls (each cost a round trip)

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

## Delivery rule (operator preference)

Do **not** paste long scripts into chat. Write the file, give the absolute path,
and let the operator copy it themselves; quote only a short hash/size for parity
(`md5sum`, line count). Ask for the **whole** script output, not "the last line"
— the terminal line is identical on every failure, only the diagnostics differ.

An absolute local path is only reachable on the SAME box. The skill therefore has
to exist on B before `--e2e` can run there — clone/copy the skill dir once (it is
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
