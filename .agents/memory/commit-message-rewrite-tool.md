---
name: Retroactive commit message rewrite
description: How to reword a batch of non-conventional commits into release-please-compatible messages without altering diffs.
---

## Rule
When a batch of commits lands without conventional-commit prefixes (breaking
release-please's changelog/version classification), reword them with
`git filter-branch --msg-filter` keyed on `$GIT_COMMIT` (original SHA) rather
than an interactive rebase — it's scriptable, reviewable, and leaves the
tree/diff of every commit untouched. Template lives at
`scripts/rewrite-commit-messages.sh` (not `.local/` — that path was wrong).

**Why:** Interactive `rebase -i` reword requires manual editor steps per
commit and can't be reliably scripted/reviewed ahead of time; `filter-branch
--msg-filter` gives a single reviewable script and only ever changes the
message, never the code.

**How to apply:**
1. Update `BASE` in the script to the last already-correct commit (e.g. the
   prior release-please merge SHA).
2. Inspect range: `git log --oneline $BASE..HEAD` and read each commit's
   `--stat`/full diff to classify type(scope) accurately — do not trust the
   original vague subject line.
3. Write a `case "$GIT_COMMIT" in <sha8>*) echo "type(scope): message" ;; ...
   *) cat ;; esac` block inside the `--msg-filter` body, one case per commit
   SHA (8-char prefix is enough). Multi-paragraph bodies use
   `printf "%s\n" "line1

   line2"` (double-quoted, real blank line for the paragraph break — no `\n`
   escapes needed inside a quoted heredoc-style string).
4. Working tree must be clean before running (commit or stash the script
   file itself if it's part of uncommitted changes) — `filter-branch` refuses
   to run otherwise.
5. Run the script directly: `bash scripts/rewrite-commit-messages.sh`.
6. Verify: `git log --oneline $BASE..HEAD` (message check) and
   `git diff HEAD <pre-rewrite-backup-tag>` (must be empty — confirms trees
   are byte-identical, only messages changed).
7. Force-push: `git push --force-with-lease origin <branch>`.
8. Clean backup refs: `git for-each-ref refs/original/ --format='%(refname)' | xargs git update-ref -d`

**Design details:**
- No single quotes inside the `--msg-filter '...'` body — use double quotes
  for any `printf`/`echo` inside it, or it terminates the outer single-quoted
  string early. If a generated message needs an apostrophe (e.g. "aiopath's"),
  splice one in with the standard `'"'"'` trick (close single, quote a
  literal `'` in double quotes, reopen single) rather than switching that one
  line to single quotes.
- Commits already in valid `type(scope): …` form can just get a light-touch
  `echo` passthrough, or be left to the `*) cat ;;` fallback.
- Tag `HEAD` before running (`git tag backup-before-rewrite <sha>`) so the
  diff-identity check in step 6 has something to compare against; delete the
  tag after verification.

**Constraints:**
- Destructive history-rewriting. This project's `dev` branch is single-owner
  (no other active collaborators), so the main agent has run this directly
  against pushed history here after an explicit user request naming the
  script — that precedent does not generalize to multi-collaborator repos.
  For any shared/multi-contributor branch, get explicit human sign-off before
  running, and before force-pushing in particular.
- Always requires `git push --force-with-lease` afterward; this step still
  needs explicit user go-ahead since it rewrites already-pushed refs.
