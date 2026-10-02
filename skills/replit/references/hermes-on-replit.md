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
   links `libatomic.so.1`; the Nix image has no loader path for it. NOT
   Hermes-specific: EVERY official linux-x64 Node ≥ 22 (setup.sh `--node`
   ships 26 for Camofox) needs the same lib — the fix is one function,
   `ensure_libatomic` (run by `--node`, `--fix`, and every install), which
   stages the copy AND prepends the pool to the current process's
   LD_LIBRARY_PATH. A `✓ already staged` on a machine where node still fails
   = stale setup.sh (pre-4.5.x marker-only check). The script scans
   `gcc-*-lib` dirs ONLY (one store pass — libatomic always ships there,
   references/nix.md §2); gfortran/julia copies exist in the store but are
   NOT used — hand-copy from those only as a last resort, after the
   `file -L ... 'ELF 64-bit LSB shared object, x86-64'` check (some copies
   are **32-bit**), into the workspace pool (`$REPL_HOME/.local/lib`), never
   `$HOME` (wiped) or
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
- `.replit [userenv.shared]`: slash-free `PIP_INDEX_URL` (written by
  `setup.sh`). `LD_LIBRARY_PATH` is **NOT managed** — the rc block only
  reaches rc-sourcing shells; processes launched outside bash (Deployments,
  app-run, daemons started pre-fix) never see the pool unless you pin
  `LD_LIBRARY_PATH = "<workspace>/.local/lib:<platform nix dirs>"` by hand.
  Reaches every **newly spawned** process — a
  gateway already running keeps its old env; prove it with
  `tr '\0' '\n' < /proc/<pid>/environ` (live-process-forensics). Verify after
  restart with `hermes pm doctor` — expect `✓ node ✓ npm ✓ python ✓ ripgrep
  ✓ uv`.
- Bare `node --version` from an unrelated shell still "fails" (PM's staged dir
  isn't on PATH; the system node is the Nix-wrapped one) — normal. PM launches
  its own binaries with the environment above, not PATH. To make interactive
  shells share the agent's toolset: `setup.sh --hermes` appends a
  `# >>> hermes-tools >>>` block after the managed toolchain block in
  `.config/bashrc` — lazily prepends every `$HERMES_HOME/tools/*` dir (newest
  version via sort -V) + venv/bin, so user shells get the same node/npm/gh/
  ffmpeg/rg/uv/tirith/python + hermes launcher. `.replit` keeps nodejs-24/
  python3.13 as nix fallback; the block just wins PATH order. Globbing is
  lazy so `hermes update` needs no rc rewrite; `--clean hermes` drops it.
