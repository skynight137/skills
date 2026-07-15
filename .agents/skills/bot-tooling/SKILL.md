---
name: bot-tooling
<<<<<<< HEAD
description: Use this skill when setting up the development environment, running linting, managing dependencies, or working with workflows. Covers Python 3.14, uv, ruff, and Replit workflow rules for this project.
=======
description: >-
  Use this skill when setting up the development environment, running linting,
  managing dependencies, running one-off Python code, or working with
  workflows. Covers Python 3.14, uv, ruff, and Replit workflow rules for this
  project.
enabled: true
>>>>>>> 2ecb89d (update)
---

# Bot Tooling

Development environment and tooling standards for this project.

---

## 1. Runtime & Package Manager

<<<<<<< HEAD
- **Python**: 3.14 (pinned via `.python-version`)
- **Package Manager**: `uv` — all Python operations use `uv run` or `uv pip`
- **Virtual Environment**: `.venv` (managed by uv)
- **Running code**: `uv run python ...` or `uv run pytest ...`
=======
- **Python**: 3.14, managed by `uv` in `.venv` (see `pyproject.toml` / `uv.lock`)
- **Package Manager**: `.local/bin/uv`
- **All execution goes through `bash start.sh <mode>`** — never invoke `python`, `python3`, or `uv run` directly.
  - Replit's Nix environment does not offer a 3.14 module yet; a bare `python`/`python3` call
    resolves to whatever Nix ships (3.12/3.13), not this project's `.venv`, and will break on
    3.14-only dependencies (e.g. `pydantic-core` requiring `Sentinel` from `typing_extensions` 4.14+).
  - **Running one-off Python code**: `bash start.sh --py "import sys; print(sys.version)"` —
    activates `.venv` first, then runs the code with the correct interpreter.
  - **Running the bot**: `bash start.sh` (prod) or `bash start.sh --dev` (dev)
  - **Running tests**: `bash start.sh --test`
>>>>>>> 2ecb89d (update)

---

## 2. Linting & Formatting — Ruff

- **Tool**: `ruff` for all Python linting and formatting.
- **NEVER invoke `ruff` directly in the shell.**
<<<<<<< HEAD
- **Always use the `Ruff Fix & Format` workflow** on Replit — it runs `uv run ruff check --fix --unsafe-fixes` using the project's pinned version.
=======
- **Always use the `Ruff Fix & Format` workflow** on Replit — it runs `bash start.sh --lint`, which
  activates `.venv` before calling `uv run --active ruff check --fix --unsafe-fixes` / `ruff format`.
>>>>>>> 2ecb89d (update)
- Reason: direct shell invocation risks version mismatch and startup failures.

**Process:**
1. Finish code changes.
2. Restart the `Ruff Fix & Format` workflow.
3. Wait for it to complete.
4. Then commit.

---

## 3. Replit Workflow Rules

- Keep background workflows to a minimum to preserve resources.
<<<<<<< HEAD
- Available workflows: `Backend API (Dev)`, `Front-end (Dev)`, `Front-end build`, `Initialization`, `Ruff Fix & Format`, `Start`, `Start webhook-proxy`.
- Start only the workflows needed for the current task.
=======
- Available workflows (all wrap `bash start.sh <mode>`): `Bot Server` (prod), `Frontend (Dev)`
  (dev backend + Vite), `Frontend build`, `Dependency Initialize`, `Cleanup garbage`,
  `Ruff Fix & Format`, `Run Tests`, `Start webhook-proxy`, `Blogger (Dev)`, `Push Dev`.
- Start only the workflows needed for the current task.
- Do not create a new workflow that calls `python`/`uv run` directly — route through `start.sh`.
>>>>>>> 2ecb89d (update)

---

## 4. Testing

- **Framework**: `pytest` with `httpx.AsyncClient`
<<<<<<< HEAD
- **Run**: `PYTHONPATH=. uv run pytest web/tests/test_api_v2.py`
=======
- **Run**: `bash start.sh --test` (or restart the `Run Tests` workflow) — runs
  `pytest tests/ -v --tb=short -n auto --dist worksteal` inside `.venv`.
>>>>>>> 2ecb89d (update)
- **Assertions**: Check for keys in response body (`assert "products" in result`), not just `status_code`.
- Always include support for query parameters (`limit`, `keywords`) and JSON payloads.

---

## 5. Verification Before Completion

Before marking any task done:
1. Verify all changes ensure system stability.
2. Double-check error handling, edge cases, concurrency behaviour.
3. Run ruff via the workflow.
4. Check runtime logs for `AttributeError`, `TypeError`, or silent failures.
5. Identify next steps and remaining technical debt.
