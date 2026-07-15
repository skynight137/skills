---
name: bot-commit-workflow
<<<<<<< HEAD
description: Use this skill at the end of every task to produce a conventional commit message and tg-update.md post. Covers commit format, type/scope rules, the agent amend workflow, tg-update.md structure, and the release flow.
=======
description: >-
  Use this skill at the end of every task to produce a conventional commit
  message and tg-update.md post. Covers commit format, type/scope rules, the
  agent amend workflow, tg-update.md structure, and the release flow.
enabled: false
>>>>>>> 2ecb89d (update)
---

# Bot Commit Workflow

Commit message standards and post-task deliverables for this project.

---

## 1. Conventional Commits Format (Required)

```
<type>(<scope>): <short description>

[optional body]

[optional footer: BREAKING CHANGE: ...]
```

### Commit Types & Version Impact

| Type | Description | Version Impact |
|------|-------------|----------------|
| `feat` | New feature | **Minor** (x.**Y**.z) |
| `fix` | Bug fix | **Patch** (x.y.**Z**) |
| `perf` | Performance improvement | **Patch** (x.y.**Z**) |
| `refactor` | Code refactor (not a feature/fix) | None |
| `docs` | Documentation changes only | None |
| `style` | Formatting, whitespace (no logic change) | None |
| `test` | Adding or updating tests | None |
| `chore` | Maintenance, dependency updates | None |
| `ci` | CI/CD workflow changes | None |
| `build` | Build system changes | None |

**Breaking Change → Major version**: Add `BREAKING CHANGE:` in footer, or `!` after type.
```
feat!: change API response format
```

### Scope (recommended)
Use the module/directory name: `bot`, `web`, `database`, `frontend`, `ci`, `deps`.

### Valid Examples
```
feat(bot): add auto-retry on download failure
fix(web): fix 500 error on /api/v2/wallet endpoint
perf(database): replace find_one with indexed lookup in WalletsCollection
refactor(aiopath): extract async helpers into separate file
<<<<<<< HEAD
chore(deps): update pyrotgfork to latest version
=======
chore(deps): update kurigram to latest version
>>>>>>> 2ecb89d (update)
feat!: change API response format to envelope standard
```

### Invalid Examples
```
update file          # ❌ no type
fixed bug            # ❌ no type, past tense
feat: .              # ❌ not informative
Fix(Web): ...        # ❌ type and scope must be lowercase
```

---

## 2. Agent Commit Workflow (Replit)

Since Replit Agent cannot run `git commit` directly, at the end of every task the agent outputs a ready-to-copy amend command:

```
git commit --amend -m "fix(rss): rename -chat flag, fix rss_edit arg_base, add feed_link editing"
```

- **Always English**, one title line only, conventional commit format.
- Developer copies and runs it to overwrite the Replit auto-checkpoint message.
- Language policy: commit messages = **English only**. Agent conversation = Indonesian is fine.

---

## 3. `tg-update.md` — Telegram Update Post

After any task that introduces a **new feature, notable change, or fix worth broadcasting**, write `tg-update.md` (ready-to-paste for the xBotz Project Telegram Updates channel).

> `tg-update.md` is in `.gitignore` — never committed.

### Format
```
✨ **Feature Name**  (🐛 fix | ⚡ perf | 🔧 refactor | 📝 docs)

Short one-line summary of what changed.

🆕 What's new
• Key point one
• Key point two
• Key point three (if any)

🤔 How to use
• example usage or step

#feature #module
```

### Rules
- Markdown: `**bold**`, `` `code` ``, `_italic_`
- English only
- Emoji on section titles only — use `•` for bullet items
- Hashtags: one type tag (`#feature`, `#fix`, `#perf`, `#refactor`, `#docs`) + one module tag (`#market`, `#wallet`, `#config`, `#bot`, `#frontend`)
- Address subscribers directly: *"You can now …"*, *"Use … to …"*
- **Never expose internal functions, method names, or implementation details** — user-visible impact only
- **Core variables are allowed** — if a config key, command flag, or setting name changed or moved, name it explicitly so users know what to update and where (e.g., `` `old_key` → `new_key` in `config.py` ``)
- Keep under ~10 lines for mobile readability

---

## 4. Release Flow

1. Push commits to `dev` branch using conventional commit format.
2. GitHub Actions (`release-please.yml`) automatically:
   - Determines next version from commit types.
   - Updates `pyproject.toml`, `bot/__init__.py`, `CHANGELOG.md`.
   - Creates a **Release PR** titled `chore(release): vX.Y.Z`.
3. Merging the Release PR → auto-creates Git Tag + GitHub Release + copies `aiopath`, `bot`, `database`, `web` to `main` branch (production).

**Do not edit version manually** — release-please manages it via the Release PR.
- Config: `.github/release-please-config.json` and `.release-please-manifest.json`
<<<<<<< HEAD
=======

---

## 5. Retroactive Message Rewrite (one-off tool)

If a batch of commits lands without the conventional-commit prefix (e.g. Replit
Agent checkpoints titled "Improve X" instead of `fix(x): ...`), release-please
cannot classify them into the changelog or version bump. `scripts/rewrite-commit-messages.sh`
rewrites commit *messages only* (tree/diff untouched) for a given commit range
into conventional-commit form via `git filter-branch --msg-filter`.

- This is a **destructive, history-rewriting** operation — it requires a
  `git push --force-with-lease` afterward and must never run against `dev`
  without explicit sign-off, since `dev` is shared and tracked by
  `release-please`.
- Treat it as a template: update the base SHA and the commit-hash → message
  map inside the script for each new batch that needs rewording, rather than
  writing a new script from scratch.
>>>>>>> 2ecb89d (update)
