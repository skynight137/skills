# SSH e2e hop into a second box (key-only sshd on a high port)

> **Which file?** `references/e2e-sshd-bridge.md` is the current lane: `setup.sh --e2e --start`
> does all of this itself (persistent `~/.ssh` symlink, tailnet hop, workflow notice). Read this
> one for the manual-bootstrap variant and the raw non-root sshd config, then follow the bridge
> file for anything that has to survive a restart.

Goal: give the agent a real terminal on a **second** box (a fresh sandbox for
testing a skill) so it can run setup there, instead of driving a browser xterm
by mouse-simulated keystrokes. Works on a fresh Replit/Nix box as a normal
user, no root, no port 22.

`sshx`/`tmate`-style web terminals do **not** give the agent a shell: the CLI
only *creates* a session, the session lives in a browser page, and typed
keystrokes into a canvas pane have no text channel back. Use sshx only to hand
the user a place to paste a bootstrap script, then leave it.

## Shape

1. Agent box (server 1): make a dedicated keypair, never reuse a GitHub key.
   `ssh-keygen -q -t ed25519 -N '' -f <keys>/e2e-hop -C hermes-e2e-hop`
   The public key is safe to embed and to print; the private key stays put.
2. Write one bootstrap script for the second box and deliver it as a **file
   path** the user opens and pastes (a gzip+base64 single line only if the
   path is not reachable from their side). The script does everything itself
   and prints machine-checkable markers, so the run needs no eyes on it.
3. The script, in order: resolve `sshd`, prepare privsep dirs, write host key +
   `authorized_keys`, write a private config, start it, then verify with a
   banner probe **and** a real loopback key login. Fail loudly with the log.
4. User returns the success line plus the public host/port. Agent connects,
   does the work, and configures Hermes `terminal.backend=ssh` on server 1.

The bootstrap must be self-contained and correct the first time: the user runs
it by hand, so every silent failure costs a full round trip.

## Non-root sshd config that actually starts

```
Port 6800
ListenAddress 127.0.0.1
HostKey $D/host_ed25519
PidFile $D/sshd.pid
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers $USER
UsePAM no
StrictModes no
LogLevel VERBOSE
```

Keep it under `~/.ssh/e2e-sshd/` so the user's own `authorized_keys` and
`sshd_config` are untouched.

- **Allocate a free high port (6800-family) and check the owner first.** On a
  Replit box 8000 and 8080 are commonly taken (noVNC, the Hermes dashboard); a
  collision makes sshd exit with `Cannot bind any address` while a *different*
  port in the same config still reports `Server listening`.
- Bind one address only, `127.0.0.1`. With two `ListenAddress` lines a single
  occupied address kills the whole daemon. Add `0.0.0.0` as an opt-in
  (`${LISTEN_ALL:+ListenAddress 0.0.0.0}`) and let the platform proxy reach
  localhost.
- **`sshd` must be launched by absolute path.** A relative/PATH-resolved call
  dies with `sshd requires execution with an absolute path`.
- **`command -v sshd` is unreliable on this box** — PATH differs per shell, so
  it returns nothing in one call and a `/nix/store/...` path in the next.
  Resolve against explicit candidates instead
  (`/nix/store/*replit-runtime-path*/bin/sshd`, `/nix/store/*openssh*/bin/sshd`,
  `/run/current-system/sw/bin/sshd`, `/usr/sbin/sshd`), then fall back to
  `nix build --no-link --print-out-paths nixpkgs#openssh`, then the distro
  package manager. Same for `ssh`.
- **Non-root sshd needs a privsep dir**: create `/run/sshd` (and `/var/empty`)
  with `mkdir -p … || sudo mkdir -p …`, `chmod 755`. Without it the daemon
  refuses to start.
- `setsid` may be absent; fall back to `nohup … &`. Keep the PID file and kill
  the old PID before restarting.

## Verification that means something

Probe the banner and require `SSH-2.0-*`, retrying for ~10s while the daemon
boots. **Read a line, do not `head -c N`**: the banner is 22 bytes, so
`head -c 24` blocks until the timeout kills the reader and returns nothing.

```bash
timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT; IFS= read -r -t 2 l <&3 && printf '%s' \"\$l\""
```

Then prove auth, not just reachability: generate a local throwaway key, append
it to `authorized_keys`, and `ssh -p $PORT -i thatkey -o BatchMode=yes \
-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $USER@127.0.0.1
'echo AUTH_OK; uname -sm'`. Only `AUTH_OK` plus an echoed architecture is a
pass.

## Failure-reporting rules for a hand-run script

- **Print the log BEFORE exiting.** A `die "reason"` that exits and *then* tails
  the log shows the reason only: the log lines never run. Put the tail inside
  the `die` function.
- On banner failure: kill the background daemon, then run the daemon once in
  the foreground with `-ddd` for a few seconds and dump the tail. The debug
  run collides with the live daemon if you do not kill it first (`Address
  already in use`).
- Echo the resolved `sshd` path and its version, and a `privsep : ok` line, so a
  failure names its own step.

## Iterating on the script

- Always `bash -n` the file, then **run it for real on the local box on a
  scratch port** before handing it over — syntax-clean is not working. Then
  kill the instance (`pkill -x sshd`) so the next run is clean.
- `pkill -f "sshd -f <path>"` also matches the wrapping `bash -c` of the agent
  shell and kills the caller mid-command (exit `-15`); `pkill -x sshd` does not.
- Overwriting the delivery file in place is refused after edits; `rm` it and
  write again, or `patch` it. Do not paste the whole script into the chat —
  rewrite the file.
- Keep the embedded public key byte-identical to the key on disk: compare the
  base64 field with `cmp` after writing, never retype it from memory.

## After the hop works

- Connect with the dedicated key and a `Host e2e` block in `~/.ssh/config`
  (HostName 127.0.0.1, the forwarded/Publish port, the user, IdentityFile).
- Point Hermes at it with `TERMINAL_SSH_*` in the profile `.env` and
  `hermes config set terminal.backend ssh`, then prove it: the `terminal` tool's
  `uname -a` must report the *second* box's hostname.
- Hermes does not read `~/.ssh/config` aliases for its backend: set host/port/
  user explicitly rather than relying on the alias.
- Kill the sshx session and the bootstrap daemon when done, and say which ports
  are still open.
