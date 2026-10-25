# The interactive shell surface (rc chain, durable toolchain, zsh)

## Where a shell gets its environment

- `$REPL_HOME/.config/bashrc` is the only persistent rc. The image's
  `/home/runner/.bashrc` sources it **only while `REPLIT_MODE` is empty**;
  agent/workflow shells set `REPLIT_MODE`, so they see nothing until the
  `REPLIT_BASHRC` shim (`unset REPLIT_MODE; source ~/.bashrc`) runs. Check
  `printenv REPLIT_MODE` before assuming an rc line reached a shell.
- Never hand-append to a generated `$REPL_HOME/.config/bashrc`. The emitter
  rebuilds the file from its registry plus a rescue pass that recognizes only
  plain `export NAME="value"` lines, so a multi-line `if` guard or `case` block
  is dropped silently on the next `setup.sh` / `fix` run. Register the variable
  where the other tools do (`record_tool_env_vars`, `record_tool_path_dirs` in
  `scripts/setup/*.sh`) and let `rc.sh` emit it.
- Dotfiles belong under `$REPL_HOME` (`$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`);
  `$XDG_BIN_HOME` is the only PATH entry. `$HOME` is wiped on recreate, so a
  file placed there is a one-session file.

## Installing a shell or CLI with no Replit module

- `nix profile install --profile "$REPL_HOME/.local/nix-profiles/<name>"
  nixpkgs#<attr> ...`, then `ln -sfn` each binary into `$XDG_BIN_HOME`. The
  profile is a durable GC root on the workspace volume; a bare `/nix/store/...`
  path is not, and it disappears when the store is pruned.
- The login shell cannot be changed: `/etc` is a read-only mount, `/etc/shells`
  has no zsh, and `chsh` cannot write `/etc/passwd`. Ship a shell as a command
  (`zsh`, `exec zsh`), never as a login shell.

## oh-my-zsh + powerlevel10k (Termux-Setup parity)

Install: `bash setup.sh --zsh` (or the interactive menu's `zsh` item) —
`scripts/setup/zsh.sh`. Idempotent: each clone is skipped once present.

- Layout that survives a recreate: `$XDG_DATA_HOME/oh-my-zsh` (oh-my-zsh plus
  `custom/themes/powerlevel10k` and `custom/plugins/*`), dotfiles in
  `$XDG_CONFIG_HOME/zsh`, `ZDOTDIR` exported from the rc. zsh reads
  `$ZDOTDIR/.zshrc`; there is no `$HOME/.zshrc` for it to find.
- `ZSH_THEME="powerlevel10k/powerlevel10k"`;
  `plugins=(git python colored-man-pages zsh-syntax-highlighting zsh-autosuggestions zsh-fzf-history-search zsh-autocomplete)`.
  Install `fzf` alongside zsh — the fzf-history plugin binds a widget that needs
  the binary on PATH.
- Source the bashrc from the zshrc (`[[ -r $REPL_HOME/.config/bashrc ]] &&
  source "$REPL_HOME/.config/bashrc"`) so a zsh shell keeps the registries, TLS
  bundle, LD_LIBRARY_PATH and tool PATH the bash shells get.
- Drop the upstream Termux aliases that assume apt (`AU`/`AI`/`AR`); the Replit
  equivalent is a `replit.nix` entry or `nix profile install`. Keep venv aliases
  (`penv`/`psource`/`pipi`) pointed at `$REPL_HOME/.venv` so they survive a
  recreate.
- `POWERLEVEL9K_MODE=nerdfont-v3` renders boxes wherever the terminal client
  lacks a Nerd Font (Termux ships `font.ttf`; a browser or remote shell does
  not). Set `POWERLEVEL9K_MODE=ascii` or run `p10k configure` when glyphs show
  as `?` or boxes.

## Cloning a payload into a tree that needs parents

- `git clone <url> <dir>` refuses when `<dir>` exists and is non-empty. Create
  subdirectories **after** the clone; when the layout needs pre-existing
  parents, clone to a temp path and `cp -a tmp/. dir/`. Pre-creating
  `custom/themes` before cloning oh-my-zsh is the exact shape that dies inside a
  `set -e` script with `destination path ... exists and is not empty`.

## Runbook: zsh on a fresh box, and after any rc rewrite

1. **Install.** `bash setup.sh --zsh` (or the menu's `zsh` item). One command,
   idempotent, re-run it to fetch whatever is missing. It runs
   `nix profile install --profile $REPL_HOME/.local/nix-profiles/zsh nixpkgs#zsh
   nixpkgs#fzf`, symlinks `zsh` + `fzf` into `$XDG_BIN_HOME`, clones oh-my-zsh
   plus the five `custom/` repos, writes `$XDG_CONFIG_HOME/zsh/.zshrc` and
   `.p10k.zsh`, and registers `ZDOTDIR` + `$XDG_BIN_HOME` as tool wiring.
2. **Never hand-edit the generated dotfiles.** `install_zsh` writes `.zshrc`
   with `cat >` and re-`cp`s `.p10k.zsh` on every `--zsh` run, so a manual edit
   is silently reverted by the next install. Edit `scripts/setup/zsh.sh` and
   re-run. `--fix` does not touch them at all (wiring only).
3. **`ZDOTDIR` belongs in the managed block, nowhere else.** There is no
   `$HOME/.zshrc`, so without that export a bare `zsh` starts with no theme, no
   plugins and none of the tool paths. It is ordinary tool wiring
   (`common.sh` resolves it, `install_zsh` and `fix_derive_wiring` register it),
   so `setup.sh --fix` restores it and `doctor` fails loudly when it is gone.
   Do NOT re-add it as a hand snippet above `# >>> toolchain >>>`: the emitters
   own everything from that marker down, and a snippet above it drifts the
   moment the block is regenerated (this box carried exactly that snippet and
   it was the only `ZDOTDIR` export, so a rewritten rc would have dropped zsh
   back to a plain shell). The dotfiles reach the tool env by sourcing the
   bashrc, so registries, TLS vars, `LD_LIBRARY_PATH` and the Hermes launcher
   all arrive from that same block; `ZDOTDIR` is the only zsh-specific line.
4. **Manual touches the installer leaves to you.** `.p10k.zsh` is
   `p10k-classic.zsh` with `POWERLEVEL9K_MODE=nerdfont-v3`, so a terminal
   without a Nerd Font renders every prompt glyph as a box or `?`; run
   `p10k configure` or set `POWERLEVEL9K_MODE=ascii`. The aliases the zshrc
   carries (`penv`, `psource`, `pipi`, `gclone`, `unzsh`) hold literal paths
   baked at install time.
5. **Non-interactive zsh prints noise that is not breakage.** With no
   controlling terminal, oh-my-zsh reports
   `(anon):setopt:7: can't change option: monitor` and p10k reports
   `[ERROR]: gitstatus failed to initialize` plus advice to `exec zsh`. Both are
   TTY artifacts of `zsh -lic`. Judge the wiring, not the prompt.
6. **Verify (what "working" looks like here).**
   - `bash setup.sh --doctor` → `✓ zsh: zsh 5.9 (x86_64-pc-linux-gnu)` and
     `✓ ZDOTDIR in the managed block of .../bashrc`.
   - `grep -nE '^export (ZDOTDIR|HERMES_HOME)=' "$REPL_HOME/.config/bashrc"` →
     both hits land between `# >>> toolchain >>>` and `# <<< toolchain <<<`.
   - `bash -lic 'echo $ZDOTDIR'` in a fresh terminal → the workspace dotdir
     (`$REPL_HOME/.config/zsh`). Starting `zsh` from that shell is what makes
     the dotfiles reachable; the export is the rc's job, not zsh's.
   - `zsh -lic 'echo $ZSH_THEME; echo ${#plugins[@]}; command -v hermes'` →
     `powerlevel10k/powerlevel10k`, `7`, and the launcher under
     `$HERMES_HOME/hermes-agent/.hermes/bin`.

## Proving shell wiring

- Write the probe to a file and run the shell on it (`zsh -i /tmp/probe.zsh`).
  Nesting `bash -lc "zsh -ic \"...\""` returns empty expansions and reads as a
  broken config when the quoting, not the config, is at fault.
- Prove the rc, not the binary: `env -u ZDOTDIR bash -lc 'zsh -i probe.zsh'`
  must still print the expected `ZDOTDIR`, theme and plugin count — that is what
  shows the export came from the generated rc rather than the calling shell.
- Long tool output can come back compressed (quotes, dots and filenames
  dropped). Print with delimiters (`... | sed 's|^|ITEM<|; s|$|>|'`) or read
  bounded ranges (`awk 'NR>=X && NR<=Y'`), and read a skill's own files with
  `skill_view(name, file_path=...)` instead of trusting a mangled listing.

## Contributing skill changes from this box

- Work in a worktree on a branch and open a PR against `skynight137/skills`;
  never commit to `main`.
- Pushes authenticate through gh's helper
  (`credential.https://github.com.helper` = `!<nix path>/.gh-wrapped auth
  git-credential` in `$GIT_CONFIG_GLOBAL`), so a plain
  `git push -u origin <branch>` works. Confirm with
  `git push --dry-run origin <branch>` before blaming auth for a failed push.
- PRs here are squash-merged, so a branch's commits never become ancestors of
  `main`. After a merge, `git rebase origin/main` before opening the follow-up
  PR: without it the new PR's diff re-lists the merged work and carries a commit
  that is already in main through its content (a 2-commit follow-up rendered as
  13 files and 3 commits until the rebase dropped the applied one).
- `setup` / `fix` re-emit from the checkout they are launched from, so run them
  from the branch under test. A `main` checkout re-emits the old block and the
  live rc will not show the change.
