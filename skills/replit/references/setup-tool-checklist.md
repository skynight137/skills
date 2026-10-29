# Adding a tool or flag to setup.sh

Every tool is wired at roughly two dozen places spread over eight existing files,
plus its own installer module. A partial wiring does not error: the flag is
simply invisible, or the tool installs and then cannot be repaired or cleaned.
Touch the sites in this order.

## 0. Enumerate the sites, never work from memory

```bash
grep -n "INSTALL_<an analogous tool>" scripts/setup/*.sh setup.sh
grep -n "<tool-binary-name>" scripts/setup/*.sh
grep -n "<tool-binary-name>" "$REPL_HOME/.replit"      # a workflow may already run it
```

Pick the closest existing analogue (a new direct-binary download mirrors
rclone/aria2c) and copy its shape. The first grep finds every flag site, the
second the fix/doctor/cleanup rows.

The third grep is the one that is easy to skip and expensive to miss. The box may
already run the tool from a `.replit` workflow pointing at a hand-installed copy
in an arbitrary directory. Repoint that workflow at the managed binary (or at the
generated launcher, when the tool needs a daemon), or — when the workflow runs the
operator's own script, which holds their runtime config — make that script prefer
the managed path and keep their copy as a fallback. Skip this and the installer
reports success while the old copy keeps serving.

## 1. Version / URL constants — `scripts/setup.sh`

Add the `*_RELEASE_BASE` next to the other download bases. Check the real
artifact before writing the URL: `curl -fsSL https://api.github.com/repos/<o>/<r>/releases/latest`
and read `assets[]`. Plenty of projects publish nothing usable there — the
artifact may be a versionless channel tarball (tailscale), an S3 object with no
GitHub release at all (sshx), or a binary with **no checksum asset**
(cloudflared). State the checksum reality in the comment: an unverified
download is a decision, not an accident.

## 2. Flag + ownership — `scripts/setup/common.sh`

`INSTALL_<TOOL>=false` with the other flags, and a `wire_tool <tool> -- "$XDG_BIN_HOME"`
line in `seed_tool_wiring`. Ownership is what `--clean` uses to decide which
block lines belong to the tool; without it the tool is un-cleanable by design.

## 3. Installer — a module in `scripts/setup/` plus one `source` line in setup.sh

`install_<tool>()`: `step`, `need_cmd`, download into `$XDG_DATA_HOME/_<tool>.*`,
verify, extract, place in `$XDG_BIN_HOME`, `ok` with the version, then
`record_tool_env_vars` / `record_tool_path_dirs` / `wire_tool`.

- `verify_sha256` **dies on an empty expected hash** — call it only when the
  checksum fetch actually succeeded, or delete the file on mismatch yourself.
- arch variants go in `<tool>_asset_name()` with a `die` default.
- Use `find <dir> -name <bin> -print -quit` for the binary: upstream archives
  change between a bare file and a wrapper directory.
- Print the first command a human has to run (auth, daemon start) — none of
  these installers starts a service.
- A hand-installed copy is usually a SYMLINK onto PATH from some random
directory, so check the target before replacing it: name the symlink and where it
pointed before overwriting, and replace a plain file quietly (that is almost
always your own previous install). A symlink is the fingerprint of an install
made outside `setup.sh`.

### Repo-import installers (a bundle dir, not a download)

Some tools ship as a directory of files from this repo (`scripts/<tool>/`) and their
own `install.sh` performs the download — `--llm-wiki` is the working example.

- Never create a SECOND copy on a box that already runs one: resolve the target
  first (`<TOOL>_HOME`, then an existing `$WORKSPACE/tools/<tool>`, then
  `$XDG_DATA_HOME/<tool>`). A re-run that forks the install leaves the old copy
  serving whatever the workflow starts.
- `install.sh` can exit `done` while the app never runs: on NixOS there is no
  `/usr/lib/x86_64-linux-gnu`, so the binary extracts and then dies on
  `libX11.so.6: cannot open shared object file`. After any extract, `ldd` the
  binary and resolve the misses from the store (`xorg.libX11`, `xorg.libxcb`,
  `libdrm`, `mesa`, `expat`, `fribidi`, `harfbuzz`, `zlib`, `libgpg-error`,
  `stdenv.cc.cc.lib`, plus a by-filename `ls /nix/store/*/lib/<lib>` fallback for
  split outputs such as `libcom_err`), and write the dirs to `.ldpath`.
- A lib-list file consumed as `read -a ... && for` needs a **trailing newline**:
  `read` returns non-zero at EOF without one, which short-circuits the `&&` chain,
  so every entry vanishes silently.

## 4. Make the flag real — `rc.sh`, `cli.sh`, `ui_menu.sh`

- `rc.sh` usage(): the flag line, **and** the `--clean <targets>` list.
- `rc.sh` parse_args(): `--<tool>) INSTALL_<TOOL>=true ;;`
- `rc.sh` the two `INSTALL_ALL` sites: the no-flag guard and the `if $INSTALL_ALL`
  block. Miss the guard and a run with only the new flag installs EVERYTHING.
- `cli.sh`: the dispatch line, the menu-selection guard in `main()`, and the
  "Run directly" banner.
- `ui_menu.sh`: `_MENU_ITEMS`, the `_status_init` TOOLS array, and the
  tick-to-flag `case`. Miss the case and picking the tool in the menu is a no-op.

## 5. Repair, verify, clean

- `fix.sh` `fix_derive_wiring`: a presence check that re-registers the wiring as
  if the tool were installed this run. Direct-binary tools share one loop
  (`for b in rclone ... <tool>; do [[ -x ... ]] && record_tool_path_dirs ...`).
- A tool that needs a GENERATED companion (`$XDG_BIN_HOME/launch-tailscaled`, the
  camofox launcher) must write it from the installer **and** call that writer from
  `fix_derive_wiring`, so `--fix` restores it too. Point `.replit` workflows at the
  generated file, never at a hand-installed path in a random directory: that is the
  entire reason the launcher exists, and it is what stops an old manual install
  from keeping the workflow on a stale binary.
- `doctor.sh`: `check_tool "<name>" "$XDG_BIN_HOME/<bin>" [flag]`. The third arg
  is the probe, so pass a subcommand when the tool has no `--version`
  (tailscale takes `version`). Gate any block-content check on the presence of
  the actual export line, not on a marker.
- `cleanup.sh`: `clean_<tool>()`, a `clean_paths_for` line, the `back_up_tool`
  case when the tool owns user data, and **four** case lists (the pre-flight
  target scan, the summary/hint scan, the `all` wipe list, the per-target
  dispatch). A tool missing from the dispatch list is silently un-cleanable.
- A tool that owns user data (node key and login, models, OAuth creds) must
  PRESERVE its data dir and say so in the pre-flight line. Never `rm -rf` a dir
  that also holds the operator's own scripts: remove only what this installer
  created and warn about anything else you find there.

## 6. Test it for real

```bash
bash setup.sh --<tool>
bash setup.sh --doctor | grep -i <tool>          # ✓ with a version
bash setup.sh --clean <tool> -y                  # binary gone, data dir kept
bash setup.sh --<tool>                           # reinstall after the test
```

- **A "fake root" is only fake if you override every root.** The box rc already
  exports `XDG_BIN_HOME`, `XDG_DATA_HOME`, `HERMES_HOME`, `XDG_CONFIG_HOME` and
  `WORKSPACE`; passing only `REPL_HOME`/`XDG_DATA_HOME` still installs into the
  LIVE toolchain, re-runs the Hermes installer's skill sync, and fills the disk.
  Pass all of them, plus `HOME` and `LLM_WIKI_HOME`/whatever the tool honours:
  ```bash
  env REPL_HOME=$RW/repl WORKSPACE=$RW/work XDG_BIN_HOME=$RW/bin \
      XDG_DATA_HOME=$RW/data XDG_CONFIG_HOME=$RW/cfg HERMES_HOME=$RW/hermes \
      HOME=$RW/home bash scripts/setup.sh --<tool> -y
  ```
  Then check the real `$XDG_BIN_HOME` mtimes if the run was short and suspiciously
  productive; a fake-root run that installs unrelated tools means the guard in
  `rc.sh` is missing a flag, not that the test worked.
- The one-flag run must install ONLY that tool. If it starts provisioning Android,
  ollama, zsh and friends, an `INSTALL_*` flag is missing from the no-flag guard in
  `rc.sh` (line ~180) — this is exactly how `--llm-wiki` and, before it,
  `--hermes-chromium` behaved.

- After `--clean`, confirm a **shared** `$XDG_BIN_HOME` PATH line SURVIVES: it is
  owned by every tool that has a binary there, so `owned_only_by` keeps it and
  removing it would break the others.
- Run `--fix` twice and require an identical `md5sum` of the rc.
- An install run and a `--fix` run can differ **only** by the position of that
  shared dir line (same set, different order, because registration and rescue
  order feed the emitter). `diff` the two files and check the line set before
  calling it a regression.
- Assert a daemon came up from its OWN interface (socket, HTTP), never from
  `pgrep -f <text>`: an unanchored pattern also matches a shell whose command
  text contains it, so it answers "already running" and skips the start. See
  `references/exposing-ports.md` §"Stopping these services, and probing them".
- After the change lands on `main`, pull it and re-run `--fix` against the live
  box, expecting the same rc `md5sum` as before. Identical output means the
  merged code reproduces what is installed; any drift is a regression the PR
  introduced, not local state.

## Harness for the rc writer (when the change touches emission)

Source the modules in a scratch shell with the side-effect helpers stubbed and
the globals `common.sh` would have set:

```bash
ok(){ :; }; step(){ :; }; skip(){ :; }; warn(){ :; }; die(){ return 0; }
env_var_owner(){ printf '%s' "$1"; }
record_tool_env_vars(){ :; }; record_tool_path_dirs(){ :; }
WORKSPACE=$REPL_HOME REPL_HOME=... HOME=... HERMES_HOME=... REPLIT_MODE=true
_TOOL_ENV_VARS=(JAVA_HOME) _TOOL_PATH_DIRS=()
source scripts/setup/fix.sh; source scripts/setup/rc.sh
write_bashrc   # BASHRC pointed at a COPY of the live rc
```

- Every variable named inside `emit_managed_block`'s comments must be SET, or the
  heredoc aborts under `set -u` and the emitted block is **silently truncated**.
  An empty pair of parentheses in the output is the fingerprint of a variable
  that expanded to nothing.
- Simulate the harsh case too: no registration for the tool at all (a run that
  installs something else). That is what exercises a migration/lift path.
- Then `bash -n` the result, source it twice in a clean shell and count the
  entries (`sort | uniq -c`) — the duplicate check, not just validity.
