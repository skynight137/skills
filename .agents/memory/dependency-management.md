---
name: Dependency management migration
description: pyproject.toml + uv.lock is now canonical; requirements.txt is deprecated; install patterns and gotchas.
---

## Rule
`pyproject.toml [project].dependencies` is the sole source of truth for runtime deps.
`uv.lock` (committed) pins the full resolved graph (146 packages as of v3.26.10).
`requirements.txt` has been removed from `dev`. Do not recreate it.

## Install commands
- Development or CI: `uv sync`
- Fresh venv: `uv venv .venv --python 3.14 && uv sync`
- Add a package: `uv add <pkg>` (updates both pyproject.toml and uv.lock atomically)
- After manual pyproject.toml edit: `uv lock` then verify no warnings

## start.sh
Correct form is:
```sh
uv sync
uv run python update.py
uv run python -m bot
```
Do NOT create a `.venv` manually or call `source .venv/bin/activate`. Replit installs to `.pythonlibs`; setting `VIRTUAL_ENV=.venv` before `uv sync` triggers a warning and causes uv to recreate `.pythonlibs` while `python3` on `$PATH` still points to the empty `.venv` (Nix Python 3.12 with no packages). `uv run` bypasses this entirely — it selects the project-managed Python 3.14 from `.pythonlibs` automatically.

## Known gotchas
- `redis==8.0.1` does NOT have a `[asyncio]` extra — async support is built-in. Using `redis[asyncio]` triggers a uv warning and should be written as `redis==8.0.1`.
- All three git+ deps (kurigram, yt-dlp, pycloudflared) are pinned to specific commit SHAs as of 2026-06-27. To upgrade any of them: run `git ls-remote <repo-url> <branch>`, update the SHA in pyproject.toml, then run `uv lock`.

**Why:** Having `requirements.txt` as the install source while `pyproject.toml` declared `dependencies = []` meant `uv lock` produced a lockfile with no runtime deps, making builds non-reproducible and breaking any tool that reads pyproject.toml for metadata.

**How to apply:** Any new runtime dependency goes in `pyproject.toml [project].dependencies` via `uv add`. Never touch `requirements.txt` for new packages.
