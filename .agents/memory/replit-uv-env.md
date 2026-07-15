---
name: Replit uv env var overrides
description: Replit injects env vars that break uv managed Python; now neutralized via .replit [userenv.shared], not start.sh exports.
---

## The problem

Replit injects these into every shell session:

```
UV_PYTHON_DOWNLOADS=never
UV_PYTHON_PREFERENCE=only-system
UV_PROJECT_ENVIRONMENT=/home/runner/workspace/.pythonlibs
```

Combined effect:
- `uv venv --python 3.14` fails with "No interpreter found for Python 3.14 in search path" even after `uv python install 3.14` — because `only-system` + `never` blocks the managed install from being used
- `uv sync` / `uv run` write to `.pythonlibs` instead of `.venv`

## The fix (current — 2026-06-29)

The overrides now live in `.replit [userenv.shared]`, which applies to all workflows and shell sessions:

```toml
[userenv.shared]
UV_PYTHON_PREFERENCE = "managed"
UV_PYTHON_DOWNLOADS = "auto"
UV_PROJECT_ENVIRONMENT = ".venv"
PYTHONPATH = ""
PIP_INDEX_URL = "https://pypi.org/simple/"
npm_config_registry = "https://registry.npmjs.org/"
NPM_CONFIG_REGISTRY = "https://registry.npmjs.org/"
GOPROXY = "https://proxy.golang.org,direct"
YARN_REGISTRY = "https://registry.yarnpkg.com/"
YARN_NPM_REGISTRY_SERVER = "https://registry.yarnpkg.com/"
```

`PYTHONPATH = ""` clears the Nix 3.12 pollution (replaces `unset PYTHONPATH` that was previously in `start.sh`).

The `start.sh` header still has the exports **commented out** — they serve as documentation of what the env vars do, but are no longer active since `.replit` sets them first.

**Why:** Setting env vars in `[userenv.shared]` is the canonical Replit approach — it applies to all shells and workflows without requiring each script to re-export. Exporting in `start.sh` only worked for subprocesses of `start.sh`, not for the Replit IDE shell itself.

**How to apply:** If this project is run outside Replit (CI, local), export the three UV vars manually before calling `uv venv` or `uv sync`. The `start.sh` comments serve as the reference.

## setup_venv() behavior in start.sh

`setup_venv()` additionally runs `uv python install 3.14` before `uv venv .venv --python 3.14` if `.venv` does not exist:

```bash
setup_venv() {
    if [ ! -d ".venv" ]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh   # install uv if missing
        uv python install 3.14
        uv venv .venv --python 3.14
    fi
    source .venv/bin/activate
}
```

`uv python install 3.14` is required because Nix rebuilds can clear the managed Python cache.

## Second hazard — Nix Python 3.12 PYTHONPATH pollution

`python312Packages.mypy` and `python312Packages.typecode-libmagic` in `replit.nix` cause Nix to inject the full Python 3.12 dependency tree into `PYTHONPATH`, including `typing-extensions 4.13.2`. Python 3.14 resolves `typing_extensions` from there before the venv's copy (4.15.0), breaking `pydantic-core` which requires `Sentinel` (added in 4.14.0).

**Fix (current):** `PYTHONPATH = ""` in `.replit [userenv.shared]` — already in place. This is cleaner than `unset PYTHONPATH` in `start.sh` because it applies to the IDE shell too.

**Symptoms if broken:** `ImportError: cannot import name 'Sentinel' from 'typing_extensions' (/nix/store/.../python3.12/...)` even though the venv has the correct version.
