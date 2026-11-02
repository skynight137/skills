#!/usr/bin/env bash
# setup.sh — shared installer entry for this repo (CLONE workflow).
#
# Two ways to consume this repo, two entry points — same implementations:
#
#   1. Full clone (the operator's way): run THIS script from the repo root
#      and name the target machine explicitly:
#          ./setup.sh --machine muse [--peer <ip>] [--verify]
#          ./setup.sh --machine repl [--tailscale] [-j] [--sshd] ...
#      --machine selects one row of the profile table below: which skill's
#      installer runs. Every remaining argument is passed through verbatim.
#
#   2. Per-skill install (`npx skills add <owner>/<repo> --skill <name>`):
#      only the skill folder is copied to the target box, so each skill
#      keeps its own self-contained scripts/setup.sh and SKILL.md points
#      there. This root script is NOT part of any skill and is never
#      copied by that flow — nothing here replaces the per-skill scripts.
#
# Why a dispatcher and not one merged installer: the two machines differ
# in almost everything below the surface (root resolution, user model,
# egress, join transport). What is genuinely shared is the ENTRY — one
# command, an explicit target, identical flag conventions — so that is
# what lives here. Forcing the implementations into one file would just
# rebuild the branch-soup the profile table exists to avoid.
#
# --dry-run prints the resolved command instead of executing it.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
usage: ./setup.sh --machine <muse|repl> [--dry-run] [target args...]

  --machine muse   Muse VM (anchor: MUSE_HOME=\$HOME/workspace)
                   target args: [--peer <tailnet-ip>] [--verify]
  --machine repl   Replit repl (anchor: REPL_HOME=<workspace>)
                   target args: the replit setup's own flags, verbatim
  --dry-run        print the resolved command, do not execute
EOF
}

MACHINE="" DRY=0 ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine)   MACHINE=${2:?--machine needs a value}; shift 2 ;;
    --machine=*) MACHINE=${1#*=}; shift ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done

# Profile table: machine -> that skill's own installer. Add a row when a
# new target VM gets a skill; the per-skill script stays the only
# implementation (see the header for why).
case "$MACHINE" in
  muse)        TARGET="$ROOT/skills/muse/scripts/setup.sh" ;;
  repl|replit) TARGET="$ROOT/skills/replit/scripts/setup.sh" ;;
  "")          usage >&2; exit 2 ;;
  *) echo "unknown --machine: $MACHINE (expected muse|repl)" >&2; exit 2 ;;
esac
[[ -f "$TARGET" ]] || { echo "target installer not found: $TARGET" >&2; exit 2; }

if [[ $DRY -eq 1 ]]; then
  printf 'would run: bash %q' "$TARGET"
  printf ' %q' ${ARGS[@]+"${ARGS[@]}"}
  printf '\n'
  exit 0
fi

echo "machine: $MACHINE -> $TARGET"
exec bash "$TARGET" ${ARGS[@]+"${ARGS[@]}"}
