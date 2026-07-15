---
name: base-image dependency sync (RESOLVED — directory removed)
description: base-image/ directory removed; Dockerfile now lives at repo root; build-base-image.yml context is '.'.
---

# Dockerfile moved to root

The `base-image/` directory was removed. The single `Dockerfile` now lives at the repo root.

**Why:** Eliminated the duplicate `pyproject.toml` + `uv.lock` copies that had to be kept in sync manually.

**Trigger paths in build-base-image.yml:**
```yaml
paths:
  - "Dockerfile"
  - "pyproject.toml"
  - "uv.lock"
```

**Build context:** `context: .` (root).

**Pre-built marker:** Stage 2 of `Dockerfile` runs `RUN touch /venv/.prebuilt`. `start.sh`'s `sync_deps()` checks for `/venv` (not the marker file — see `unified-start-sh.md`) to skip dep sync in Docker containers. Do not remove it.

## `heroku/` directory removed — deployment moved to the `starter` branch

The `heroku/` directory (previously living inside `dev`) was deleted entirely (2026-07-14). Deployment now lives on a dedicated **`starter`** branch at the repo root — `Dockerfile`, `heroku.yml`, `.dockerignore`, `.gitignore`, `README.md`, plus copies of `pyproject.toml`, `uv.lock`, `update.py`, `start.sh`.

`starter/Dockerfile` still uses `FROM ketela/vevex:${BASE_TAG}` — no change needed there.

`deploy-heroku.yml` now triggers on push to the `starter` branch (not a path filter on `dev`) and builds with `context: .` since the Dockerfile sits at the branch root.

**Keeping starter in sync:** `release-please.yml`'s `sync-to-starter` job copies `pyproject.toml`, `uv.lock`, `update.py`, `start.sh` from `dev` to `starter` automatically after every release (mirrors the existing `sync-to-main` job pattern). Do not hand-edit those four files directly on `starter` — edit them on `dev` and let the release sync propagate.
