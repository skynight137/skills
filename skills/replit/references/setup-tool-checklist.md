# Adding a tool or flag to setup.sh

Every tool is wired at roughly two dozen places spread over eight existing files,
plus its own installer module. A partial wiring does not error: the flag is
simply invisible, or the tool installs and then cannot be repaired or cleaned.
Touch the sites in this order.

## 0. Enumerate the sites, never work from memory

```bash
grep -n "INSTALL_<an analogous tool>" scripts/setup/*.sh setup.sh
grep -n "<tool-binary-name>" scripts/setup/*.sh
```

Pick the closest existing analogue (a new direct-binary download mirrors
rclone/aria2c) and copy its shape. The first grep finds every flag site, the
second the fix/doctor/cleanup rows.

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

- After `--clean`, confirm a **shared** `$XDG_BIN_HOME` PATH line SURVIVES: it is
  owned by every tool that has a binary there, so `owned_only_by` keeps it and
  removing it would break the others.
- Run `--fix` twice and require an identical `md5sum` of the rc.
- An install run and a `--fix` run can differ **only** by the position of that
  shared dir line (same set, different order, because registration and rescue
  order feed the emitter). `diff` the two files and check the line set before
  calling it a regression.

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
