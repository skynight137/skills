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

## Environment model

- `HOME=/home/hatch`; `$MUSE_HOME` and all `XDG_*` are **unset** in the
  stock environment. Muse uses explicit HOME-based paths; setting XDG
  variables does nothing for Muse itself (third-party tools may honor
  them — the operator's `~/workspace/config/env.sh` points XDG at
  `~/workspace/.xdg/*` for those).
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

## Skill registration (Muse-specific)

- A custom skill is auto-discovered only at
  `~/workspace/custom-skills/<name>/SKILL.md` (real folder or symlink to a
  folder elsewhere under `~`). A skill left only in `~/skills/` or a repo
  is invisible until registered. Verify with a skill search, not `ls`.
- `~/config/skills.yaml` is the connector/service registry, **not** a skill
  index. Do not edit it to register skills.
