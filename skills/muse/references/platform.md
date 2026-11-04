# Muse VM — platform & persistence

Verified 2026-11-01 (restart test with hash-matched markers) and 2026-11-02
(live mount/process inspection). Re-verify before quoting:
`systemd-detect-virt`, `grep -E ' / | /home/hatch | /opt' /proc/mounts`,
`ps -p 1 -o comm=`, `printenv`.

## What the box actually is

- A **systemd-nspawn machine container** (`systemd-detect-virt` says so;
  PID 1 is real systemd; kernel is the host's). Not Docker (no
  `/.dockerenv`), not a full VM.
- A **redeploy** = the platform boots a fresh instance from the base image:
  new writable overlay, fresh platform layers, same home volume attached.
  It happens on runtime updates/maintenance, unannounced.

## Filesystem anatomy

| Mount | Backing | Survives redeploy? |
|---|---|---|
| `/` | overlay, lowerdir `/sysroot`, upperdir under `/run/hatch/overlay` | No — upper layer resets |
| `/opt/hatch`, `/opt/muse` | squashfs, read-only | Replaced with current platform version |
| `/home/hatch` (`~`) | btrfs volume (`/dev/mapper/rv`, ~150G) | **Yes** — files, modes, symlinks |
| `/tmp`, `/run` | tmpfs | No |
| `~/.stagged-uploads`, `~/.pki/nssdb` | tmpfs exceptions *inside* `~` | No |

Rule for an unknown path: if it is not under `/home/hatch`, assume it is
wiped. Check `findmnt -T <path>` before trusting it.

Consequences that bite:

- `/etc` resets → locally created users (`useradd`) vanish. Recreate them
  in the bootstrap script, idempotently.
- Packages installed into the root overlay vanish. Stage binaries/tools
  under `~/workspace/` or `~/<project>/` and put them on PATH from there.
- `~/workspace` is a normal directory inside `~` (same volume), seeded at
  bootstrap with platform scaffold (`custom-skills/`, `goals/`, `system/`…).
  Scaffold recreation after deletion is **inferred, not tested**; user
  content inside would not come back either way. Never delete it as cleanup.

## Memory accounting (do not trust `free`)

Verified 2026-11-03 (process census + allocation balloon test).

- `/proc/meminfo` is **host-scoped**: MemTotal (~8 GB) is the shared
  nspawn host's RAM, and "used" includes other tenants whose processes
  are invisible in this PID namespace. Summing RSS over every visible
  process gives the box's real userspace footprint (~0.5 GB typical).
- `free`'s used/available therefore say nothing about this container:
  `MemAvailable` read ~430 MB while a test process allocated and
  page-touched 4 GB without OOM (its own VmRSS confirmed the pages
  resident). Do not gate builds, and do not report "low memory", from
  `free` output here.
- No swap (`SwapTotal: 0`). The container's cgroup sits at the root of
  the visible v2 hierarchy with no readable `memory.max` /
  `memory.current`, so the real cap cannot be read from inside; measure
  headroom empirically if it matters.
- One real non-process consumer: platform tmpfs state under
  `/run/hatch/` (the resume dir, ~0.9 GB observed).

## Environment model

- `HOME=/home/hatch`; `$MUSE_HOME` and all `XDG_*` are **unset** in
  the agent shell's stock environment. The platform DOES define XDG
  for its own processes, in `/opt/hatch/runtime-cell/guest.env`:
  `XDG_CONFIG_HOME=~/.config`, `XDG_CACHE_HOME=~/.cache`,
  `XDG_STATE_HOME=~/.local/state` — all under the persistent HOME.
  Platform daemons and tool subprocesses composed from that file get
  them; agent/SSH shells don't unless something sets them. Fleet
  rule: generated env files (the stack's `config/env.sh`, the sshd
  session environment) mirror the guest.env values instead of
  inventing a workspace XDG tree; pointing XDG into the workspace
  instead is only a contingency if the guest values ever cause
  problems. Muse itself uses explicit HOME-based paths and ignores
  XDG either way.
- Agent shell commands run as `bash --norc --noprofile`: rc files are never
  auto-sourced. There is **no Replit-style `SHELL_ENV` injection point** —
  the runtime injects its env (proxy vars, CA bundles, `JARVIS_*`) at
  process spawn and it cannot be extended.
- Working pattern for shared env + secrets: one non-secret `env.sh` in a
  persistent dir that also sources a single mode-600 `.env` holding the
  secrets; every runtime verb sources it explicitly. The Secure Vault cannot
  inject values into env vars (browser logins only) — a 600 `.env` in the
  persistent tree is the Replit-Secrets equivalent here.
- Toolchain convention: the operator's own scripts export
  `MUSE_HOME=$HOME/workspace` from that `env.sh` — the persistent target path,
  playing the role `REPL_HOME` plays on Replit. Muse itself ignores the
  variable; it exists so shared tooling (the per-skill setup scripts)
  can resolve anchor/bin/state dirs from one profile instead of literals.

## Users & the shell

- The agent shell runs as **root** (uid 0), but root's *passwd* home is
  `/root` (ephemeral overlay) while `HOME=/home/hatch`. Anything that
  resolves `~` via passwd (notably **ssh**) looks in `/root`; anything
  using `$HOME` looks in `/home/hatch`. This mismatch is the root cause of
  most "my config disappeared" bugs here.
- Daemons should run as a created non-root user (e.g. `runner`, uid 1000)
  whose passwd home points into the persistent tree. A non-root user needs
  traversal on the home path: `chmod o+x /home/hatch ~/workspace` (the
  home mount is idmapped; `chown` inside it is denied).

## The ssh store pattern (borrowed from the Replit layout)

- Canonical store in the persistent tree: `~/workspace/.ssh/` holds the
  client config, keypair, and the whole remote-access project (sshd rootfs,
  daemon state, start scripts).
- `~/.ssh` is a symlink → `~/workspace/.ssh` (persists by itself, home is
  btrfs). `/root/.ssh` is a symlink → `~/workspace/.ssh` too, but `/root`
  is ephemeral, so the post-redeploy bootstrap recreates just that link.
- Result: every lookup path (`$HOME/.ssh`, passwd-home `.ssh`, explicit
  workspace path) converges on one store that never moves.

## Workspace layout (fleet layout over the system layout)

- Tool binaries the agent installs **by hand** go in
  `~/workspace/tools/` — **FLAT, no `bin/` subdir**; tool configs go
  in `~/workspace/config/` (rclone.conf-style files live there,
  beside the shared `env.sh`). The same instinct as Hermes keeping
  its tools under HERMES_HOME: our tooling lives in our tree, away
  from the platform's own directories.
- Which layout governs what (probed 2026-11-04): the system's own
  answers point at the **XDG home layout** — `systemd-path` reports
  user-binaries `~/.local/bin`, user-shared `~/.local/share`,
  user-configuration `~/.config`, and installer user schemes agree;
  system python is PEP 668 externally-managed (`pip --user` refused
  without `--break-system-packages`). No platform skill prescribes
  an install dir. So: what installers manage follows the system
  layout; what we install by hand follows the fleet layout above —
  the pattern from the user's other Muse VM's TOOLS.md. The fleet
  dirs are a chosen home (persistent, approval-path-stable), **not**
  a system mandate, and `tools/` is flat because that is where the
  fleet actually puts binaries.
- The join stack's layout follows from that split, it is not legacy
  debt: its tailscale state dir stays pinned at
  `~/workspace/.local/share/tailscale/` — `.local/share` is the
  system-standard user-shared location (the `systemd-path` answer),
  kept as an explicit path rather than derived from XDG_DATA_HOME —
  and its binary dir follows the stickiness rule (see join.md)
  because egress approvals are keyed by binary path.
- XDG follows the platform's `guest.env` values (see Environment
  model above), not a workspace tree.

## Skill registration (Muse-specific)

- A custom skill is auto-discovered only at
  `~/workspace/custom-skills/<name>/SKILL.md` (real folder or symlink to a
  folder elsewhere under `~`). A skill left only in `~/skills/` or a repo
  is invisible until registered. Verify with a skill search, not `ls`.
- `~/config/skills.yaml` is the connector/service registry, **not** a skill
  index. Do not edit it to register skills.
