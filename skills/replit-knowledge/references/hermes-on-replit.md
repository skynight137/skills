# Running / updating Hermes Agent on a Replit sandbox

Symptom set: `hermes update` (or `hermes pm install`) fails on the isolated PM
bootstrap — either `uv sync --locked` aborts with "The lockfile at `uv.lock`
needs to be updated, but `--locked` was provided" (at the "Preparing the
isolated Hermes runtime…" step), or verification of a PM-staged binary dies
with `libatomic.so.1: cannot open shared object file` / `wrong ELF class:
ELFCLASS32` behind the generic "staged entry failed verification … exited
127" wrapper.

## Mechanisms

1. **Index-URL mismatch.** Replit's shell env (and the package-firewall
   capture in `/run/replit/env/last`) carry `PIP_INDEX_URL`/`UV_INDEX_URL`
   with a **trailing slash** on `/simple/`. Hermes PM
   (`pm/index_config.py::bridged_index_settings`) deliberately re-bridges PIP
   settings into every uv call, so `UV_INDEX_URL=…/simple/` reaches
   `uv sync --locked` even after you unset the UV var — and uv treats
   `…/simple/` as a different registry than the slash-free one recorded in
   `pm/uv.lock`. Diagnosis path that worked: reproduce the exact call under
   ablation — copy `pm/pyproject.toml` + `pm/uv.lock` to a temp dir, run
   `uv sync --locked --all-packages --no-default-groups --no-install-project`
   with the *full* PM env (`pm.runtime.runtime_environment()` returns the
   exact dict from the repo venv), then drop vars one at a time. Culprits:
   `UV_INDEX_URL` and its PIP bridge; harmless-but-noise:
   `UV_INSECURE_HOST`, `UV_PYTHON_*`.
2. **libatomic for staged node.** PM's node is a standalone x64 tarball that
   links `libatomic.so.1`; the Nix image has no loader path for it. Store
   copies exist under `gcc-*-lib`/`gfortran`/`julia` dirs but some are
   **32-bit** — `file` before exporting (replit-nix §2), and keep the durable
   copy in the workspace (`$REPL_HOME/.local/lib`), not `$HOME` (wiped) or
   `/nix/store` (GC'd).

## One-shot unblock (no persistence)

```bash
cd "$REPL_HOME/.hermes/hermes-agent" && \
LD_LIBRARY_PATH=<dir with x86-64 libatomic.so.1> \
env -u UV_INDEX_URL -u PIP_INDEX_URL -u UV_INSECURE_HOST -u PIP_TRUSTED_HOST \
  hermes update
```

Strip the PIP vars too — dropping only the UV vars re-poisons through the
bridge. The foreground tool timeout (≈420s) cuts the *view*, not the update:
it keeps running; verify afterwards with `hermes --version` + `git log -1` in
the repo. Don't rerun on a silent timeout alone.

## Permanent wiring

- `setup.sh` toolchain block (and the `[userenv.shared]` defaults it writes):
  slash-free `PIP_INDEX_URL=https://pypi.org/simple`; a guarded
  `unset UV_INDEX_URL UV_INSECURE_HOST` (fires ONLY when they are the
  redundant pypi-over-plain-https values — a real mirror value must pass
  through); `LD_LIBRARY_PATH=$REPL_HOME/.local/lib` prepended idempotently.
- `.replit [userenv.shared]`: slash-free `PIP_INDEX_URL` +
  `LD_LIBRARY_PATH = "<workspace>/.local/lib"` (write via
  `scripts/replit_userenv.py`). Reaches every **newly spawned** process — a
  gateway already running keeps its old env; prove it with
  `tr '\0' '\n' < /proc/<pid>/environ` (live-process-forensics). Verify after
  restart with `hermes pm doctor` — expect `✓ node ✓ npm ✓ python ✓ ripgrep
  ✓ uv`.
- Bare `node --version` from an unrelated shell still "fails" (PM's staged dir
  isn't on PATH; the system node is the Nix-wrapped one) — normal. PM launches
  its own binaries with the environment above, not PATH.
