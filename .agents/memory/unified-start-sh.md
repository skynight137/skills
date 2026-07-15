---
name: Unified start.sh entrypoint
description: All workflows route through bash start.sh [--mode]; single root start.sh uses .venv everywhere except when a prebuilt /venv (Docker/starter branch image) is detected.
---

# Unified start.sh entrypoint

All workflows route through `bash start.sh [--mode]`. Modes: prod/dev/build/lint/test/init/clean.

## Single-file venv strategy (root start.sh)

There is only one `start.sh` (root) — it is also the copy shipped to the `starter` branch (kept in sync by `release-please.yml`'s `sync-to-starter` job). It auto-detects its environment instead of branching per-copy:

- **Docker/starter-branch image** (`/venv` pre-exists from the `Dockerfile` build): `setup_venv()` detects `/venv`, adds it to `PATH`, returns immediately — no venv creation. `sync_deps()` detects `/venv` via `[ -d /venv ]` and skips dependency sync (deps are already pinned by the image build).
- **Replit/local/bare-metal** (no `/venv`, since `/` is read-only on Replit and `/venv` can't be created there): `setup_venv()` installs `uv` if needed, creates `.venv`, and `source`s it. `sync_deps()` uses hash-based dep sync writing to `.venv/.dep_hash`.

**Why one file instead of two:** the previous design kept a Docker-only `heroku/start.sh` copy that always assumed `/venv`, manually kept in sync with root `start.sh`. That directory was removed (2026-07-14); the single root `start.sh` now handles both cases via the `/venv` existence check, so there is nothing to keep in sync by hand — `sync-to-starter` just copies the one file verbatim.

## UV env vars

UV env vars are in `.replit [userenv.shared]` (not start.sh). `setup_venv()` runs `uv python install 3.14.6` before `uv venv`.
