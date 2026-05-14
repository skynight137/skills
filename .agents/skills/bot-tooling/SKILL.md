---
name: bot-tooling
description: Use this skill when setting up the development environment, running linting, managing dependencies, or working with workflows. Covers Python 3.14, uv, ruff, and Replit workflow rules for this project.
---

# Bot Tooling

Development environment and tooling standards for this project.

---

## 1. Runtime & Package Manager

- **Python**: 3.14 (pinned via `.python-version`)
- **Package Manager**: `uv` — all Python operations use `uv run` or `uv pip`
- **Virtual Environment**: `.venv` (managed by uv)
- **Running code**: `uv run python ...` or `uv run pytest ...`

---

## 2. Linting & Formatting — Ruff

- **Tool**: `ruff` for all Python linting and formatting.
- **NEVER invoke `ruff` directly in the shell.**
- **Always use the `Ruff Fix & Format` workflow** on Replit — it runs `uv run ruff check --fix --unsafe-fixes` using the project's pinned version.
- Reason: direct shell invocation risks version mismatch and startup failures.

**Process:**
1. Finish code changes.
2. Restart the `Ruff Fix & Format` workflow.
3. Wait for it to complete.
4. Then commit.

---

## 3. Replit Workflow Rules

- Keep background workflows to a minimum to preserve resources.
- Available workflows: `Backend API (Dev)`, `Front-end (Dev)`, `Front-end build`, `Initialization`, `Ruff Fix & Format`, `Start`, `Start webhook-proxy`.
- Start only the workflows needed for the current task.

---

## 4. Testing

- **Framework**: `pytest` with `httpx.AsyncClient`
- **Run**: `PYTHONPATH=. uv run pytest web/tests/test_api_v2.py`
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
