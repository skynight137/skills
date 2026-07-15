---
name: aiopath standalone library setup
description: How the aiopath/ directory was made an independently buildable library and a uv workspace member of the monorepo, plus a related AsyncPath bug pattern.
---

## Making a flat-layout directory buildable when its pyproject.toml sits inside the package itself

`aiopath/` has `__init__.py`, `path.py`, `constants.py`, etc. directly alongside its own `pyproject.toml` (no nested `aiopath/aiopath/` folder). Poetry-core's build backend assumes the package name matches a *subdirectory* of the project root, so it fails with `ModuleOrPackageNotFoundError: No file/folder found for package aiopath` on this layout.

**Fix:** switch that sub-project's `[build-system]` to `setuptools.build_meta` and add:
```toml
[tool.setuptools]
package-dir = { "aiopath" = "." }
packages = ["aiopath"]

[tool.setuptools.package-data]
aiopath = ["py.typed"]
```
This tells setuptools "the `aiopath` package's modules live in `.`" without moving any files, and without pulling `tests/`/`scripts/`/`docs/` into the built package (they're excluded automatically since they're not declared packages).

**Why:** avoids an invasive file-tree rename just to satisfy one build backend's directory convention, while still producing a real installable/publishable distribution.

## Wiring a sub-directory library into the root project via uv workspace

Add to the root `pyproject.toml`:
```toml
[tool.uv.workspace]
members = ["aiopath"]

[tool.uv.sources]
aiopath = { workspace = true }
```
and list `"aiopath"` in the root `dependencies`. This replaces "ambient" imports (working only because the repo root happens to be on `sys.path`) with a real editable install in `.venv`, while keeping `aiopath/` independently `uv build`-able.

**How to apply:** after editing, run `bash start.sh --init` (or restart the `Dependency Initialize` workflow) to regenerate `uv.lock`, then copy `pyproject.toml`+`uv.lock` into `base-image/` too (see base-image-dependency-sync memory) since they must mirror root exactly.

## AsyncPath: use `self._path.<method>`, never `super().<method>`, for concrete-Path-only operations

`AsyncPath` no longer inherits from `pathlib.Path` (only from `AsyncPurePath` → `PurePath`), and builds a real `Path` lazily via the `_path` cached_property. Any method that calls `super().resolve()`, `super().absolute()`, `super().expanduser()`, or `super().readlink()` will raise `AttributeError` at runtime because `PurePath` doesn't have those methods — only `Path` does. The correct pattern (already used by `samefile()`) is `await to_thread(self._path.<method>, ...)`. `super().match(...)` is fine since `match()` is genuinely a `PurePath` method.

**Why:** this was a real, silent bug — no import error, just an `AttributeError` the first time the method actually ran (caught by `aiopath/tests/test_async_path_basic.py::test_resolve`).

**How to apply:** when adding any new `AsyncPath` method that delegates to `pathlib.Path` behavior, check whether that method exists on `PurePath` (safe with `super()`) or only on `Path` (must go through `self._path`).
