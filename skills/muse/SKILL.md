---
name: muse
description: "Muse sandbox toolkit: platform facts for the Muse personal-agent VM (systemd-nspawn container, btrfs home vs ephemeral overlay root, fake-IP DNS + CONNECT-proxy egress and its permission categories, no SHELL_ENV injection, the runtime cell's spawnd renders and which platform policy is shipped in the guest vs host-side-only), the two Tailscale join routes (built-in connector vs userspace auth-key node) and why inbound only works as reverse SSH, and the automation trio (systemd units vs runtime cron vs hooks). Use for anything running ON a Muse VM."
version: 1.3.1
license: MIT
platforms: [linux]
compatibility: "Muse VM (hostname htch-runtime, HOME=/home/hatch, shell runs as root). Facts verified live 2026-11-01/02; re-verify with the commands in references/platform.md before quoting numbers."
metadata:
  hermes:
    tags: [Muse, sandbox, nspawn, systemd, persistence, overlay, btrfs, egress, proxy, dns, tailscale, reverse-ssh, hooks, cron]
---

# Muse toolkit — one skill, four lanes

Everything here is specific to running **on a Muse VM**. The platform breaks
normal Linux assumptions (the box is a container that gets replaced, DNS lies,
egress is gated per category), and each lane below is a verified playbook for
one job. Facts are dated 2026-11-02; this machine's own records beat this file
when they disagree — re-run the probes instead of trusting stale text.

## Payloads live outside this bundle

This bundle is curated memory only (`SKILL.md` + `references/`). The executable
payloads are NOT in the bundle. They live at the repo root in
`skynight137/skills` (public): `ts_proxy_connect.py` under `scripts/muse/`,
and the setup itself under `scripts/setup/` — the ONE entry is
`scripts/setup.sh` (`--machine muse` selects this machine kind; the
profile is `scripts/setup/profile-muse.sh`, sharing `scripts/setup/core.sh`
with the repl profile).

**Path rule.** `scripts/…` in this file and its references denotes a file
in those payload locations. **When a task needs the payload, ask the
operator first**, then fetch: clone `https://github.com/skynight137/skills`
(recommended — the setup needs its sibling files: the entry, the
profile and core.sh all live in `scripts/setup/`).
Note: `profile-muse.sh` sources the shared library `core.sh` from its
own directory and refuses to run without it — the clone route always
has it.
On a Muse VM the canonical working copy is the clone
(`~/skynight137/skills/scripts/setup.sh`); `~/workspace/custom-skills/muse`
symlinks to this slim bundle and no longer carries the payload.

| You want to… | Read |
|---|---|
| know what survives a redeploy, where to store things, how env/users/ssh config really resolve | `references/platform.md` |
| reach the internet or another machine, understand a blocked/reset connection, pick a permission to ask for | `references/egress.md` |
| join a tailnet, accept or originate SSH, build remote access into this box | `references/join.md` |
| follow a complete, worked join (fresh box -> verified fleet member) step by step | `references/example-fresh-box.md` |
| keep a daemon alive, schedule work, or react to a condition — systemd vs cron vs hooks | `references/automation.md` |
| know where platform policy actually lives — what the runtime cell renders into the guest (guest.env, scope maps, /etc renders), which lists are shipped as guest files (MASE, connector gatekeeper flags, Chromium managed policy), and which policy is host-side-only with no file to hunt for | `references/policy.md` |
| stand up a FRESH Muse VM as a join/e2e target (the muse-test pattern) | `scripts/setup.sh` (self-contained installer; secrets via a 600 `.env` it templates for you). Call it by full path — the skill folder names the target; there is no dispatcher. Phased like the replit setup: `--sshd`, `--tailscale`, `-j`/`--join`, `--verify`, `--user <name>` (stack service user; env `RS_SSH_USER`, flag wins, default `root` — setup prints a warning for root; `--user runner` is the fleet-proven isolated mode), and an interactive arrow-key menu (bare run on a TTY, or `--menu`); a bare run without a TTY does the full setup |

## Hard rules (the ones that cost a night when forgotten)

1. **Only `/home/hatch` persists.** The root filesystem is an overlay whose
   writable layer lives in `/run`; a redeploy boots a fresh container from
   the base image and re-attaches the home volume. Processes, `/etc`
   (including users), and `/root` all reset. Anything that must survive
   lives under `~`, and anything that must *run* needs a bootstrap that
   reinstalls it after each redeploy.
2. **DNS lies by design.** The built-in resolver answers every name with a
   fake 198.18.x address. Real answers come from `dig @8.8.8.8` (only that
   resolver answers) once External DNS is permitted. Never debug a
   connection against a name resolved by the stock resolver.
3. **Egress is TCP-through-gates, UDP is absent.** The gateway proxy
   (`198.19.0.1:3128`, HTTP CONNECT) or an approved direct-TCP dial are the
   only ways out. UDP has no plumbing at all — a permission toggle for it
   changes nothing on the wire (verified: netcheck UDP false, raw `sendto`
   EPERM). Design everything as outbound-initiated TCP.
4. **Approvals attach to foreground runs.** Work that needs an egress
   approval (a daemon's first direct dials, a first tunnel-proxy request to
   a new address) must be launched from a foreground agent turn; background
   jobs hit the same walls with no one to approve them and report phantom
   "service down" failures.
5. **Inbound does not exist; reverse does.** Neither Tailscale route accepts
   inbound connections in this sandbox (connector by design, userspace node
   by transport). Remote access into this box = the box dials out and
   leaves a reverse SSH forward. Guard the redial loop with exponential
   backoff or it will spam thousands of attempts against a stale port.
6. **ssh reads the passwd home, not `$HOME`.** The shell runs as root
   (passwd home `/root`, ephemeral) while `HOME=/home/hatch` (persistent).
   Keep the canonical ssh store in the persistent tree and symlink the
   lookup locations to it, or `ssh` silently ignores your config after
   every redeploy.
