# Muse VM — automation: systemd vs cron vs hooks

Three different mechanisms get confused because all three "run things
automatically". They live on different layers and survive redeploys
differently (see platform.md for why).

## systemd services — process supervision, inside the box

- PID 1 is real systemd (`systemctl is-system-running` → `running`), so
  units are fully real: `Restart=`, dependencies, `journalctl -u <unit>`.
- But `/etc/systemd/system` sits on the ephemeral overlay: **units and
  their enable-symlinks vanish on every redeploy.**
- Durable pattern: keep canonical unit files in the persistent tree
  (e.g. `~/workspace/<project>/systemd/`), and let the post-redeploy
  bootstrap copy/link them into `/etc/systemd/system`, `daemon-reload`,
  `enable --now`. Enabling a unit alone proves nothing about the next
  boot — verify a start after an actual redeploy before trusting it.
- Use for: daemons that must stay alive (sshd, tailscaled, tunnel
  clients), where crash-restart and boot-order matter and no judgment is
  needed.

## Runtime cron — the agent, on a clock

- Muse cron jobs are managed by the **runtime**, not the container's
  crontab: their definitions live outside the overlay and survive
  redeploys; each run wakes an agent with instructions.
- Use for: periodic checks, briefings, restores that need judgment or an
  approval-capable context — remembering that even cron runs are
  background runs for egress-approval purposes (see egress.md rule 4).

## Hooks (`~/hooks`) — the agent, on a condition

- A hook = a bash polling script in `~/hooks/scripts/` (+ state in
  `~/hooks/state/`) that the runtime executes on an interval. Each run
  ends in exactly one verdict: `silent "reason"` or `wake "reason"`; a
  wake launches a worker agent with the hook's instruction and payload.
- Hook scripts run **without secrets or connector credentials** by
  design — public endpoints and local data only.
- Definitions live in `~` (persistent) and are runtime-managed, so hooks
  keep working across redeploys with no bootstrap.
- Use for: "tell me / act when X changes" — watch a price, a peer's
  presence, a file, a queue — where an agent's judgment is the point.

## The doctor pattern (verified in production, 2026-11-05)

Keeping a fleet of self-added services alive across patternless
redeploys settled into a three-layer shape:

1. **systemd** auto-starts the processes *within* one boot
   (`Restart=on-failure`); unit templates live in the persistent tree.
2. **Hook watchdogs are the primary doctor.** A bash script polls the
   health check every ~90 s — free, no agent involved — and wakes an
   agent only on failure (with a ~15 min re-wake cooldown while
   continuously down). The woken agent re-seeds the systemd units from
   their templates, runs the bootstrap/foreground restore, re-checks,
   and reports once. One hook per service keeps scopes clean (a stack
   hook never touches the app, and vice versa), and cross-service
   ordering gates belong in the woken agent's instructions (e.g.
   "start the app backend only once the network stack answers" — a
   backend started into a down stack died silently within minutes).
3. **Agent cron is demoted to a sparse backstop** (every ~6 h) whose
   only remaining job is catching a dead hook.

Why not cron-first: every cron run burns a full agent turn even when
everything is healthy. Measured on muse-hop before the switch: a
30 min app keeper + an hourly stack check ≈ **72 scheduled agent
turns/day** of baseline burn, against ~8 actual redeploys/day of real
work. The hook-first shape costs ~4 backstop turns/day plus only the
restore wakes that do real work — same readiness, detection latency
even drops from ≤30 min to ~90 s.

## Choosing

| Need | Mechanism |
|---|---|
| Keep this process alive, restart it if it dies | systemd unit (+ bootstrap install) |
| Do X every morning / every N hours | Runtime cron |
| Watch a condition; involve the agent only when it fires | Hook |
| Restore the box's daemons after a redeploy | The doctor pattern above: hook watchdog detects (~90 s), the woken agent runs the bootstrap restore in the foreground; sparse cron as backstop |
