---
name: update.py minimal git refresh pattern
description: Why hard_reset() in update.py wipes .git and resets onto FETCH_HEAD instead of resetting onto a named ref.
---

`update.py`'s `hard_reset()` is a **production-only** code updater (runs before
`python -m bot` on every `start.sh`), not a dev git workflow — it should never
need branch history, multiple remotes, or a `.git.bak` recovery path.

**The bug this replaced:** fetching a bare branch name (`git fetch origin
main`) only populates `FETCH_HEAD` — it does **not** create the local
remote-tracking ref `refs/remotes/origin/main` unless a full refspec is used.
So `git reset --hard origin/main` failed with "ambiguous argument
'origin/main': unknown revision" even though the fetch itself succeeded.

**Fix — reset onto `FETCH_HEAD`, not a named ref:**
1. `shutil.rmtree(".git", ignore_errors=True)` then `git init` + `git remote
   add origin <repo>` — always start clean, no `.git.bak` backup/rename.
2. Strip a leading `origin/` from the configured ref (the remote only knows
   the bare name), then `git fetch --depth 1 origin <ref>`.
3. `git reset --hard FETCH_HEAD`.

This one recipe handles plain branch names, tags, `origin/<branch>`, and
full/short commit SHAs identically, and never downloads more than the single
target commit.

**Why:** the user explicitly wants this to stay minimal — no defensive
`.git.bak`, no full-history clone, no branch/ref-type detection branching.
If fetch or reset fails, the working tree files are simply left as they were
after the last successful update; `.git` is disposable and gets rebuilt from
scratch on the next run.

**How to apply:** if `hard_reset()` needs new ref-type support in the future,
keep resetting onto `FETCH_HEAD` rather than a named ref — don't reintroduce
per-ref-type branching or a `.git.bak` safety net.
