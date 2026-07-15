---
name: Sweep verification pitfalls
description: Common false-positive patterns found when independently verifying explorer-subagent sweep findings before writing them into docs/superpowers/sweep-*.md
---

When an explorer subagent flags a "bug," verify it directly against the code before writing it into a sweep doc — several recurring false-positive shapes have shown up across sweep rounds:

- **`finally:` blocks run on both success and failure paths.** A comment like "clean up on error" next to a `finally:` block does not mean the cleanup is skipped on success — `finally` always executes. Don't trust the comment; trust the control-flow keyword.
- **`pathlib`/`AsyncPath` "with_*" methods (`with_stem`, `with_suffix`, `with_name`) are non-mutating.** A bare-statement call (`path.with_stem(x)` without reassignment) is a real bug — the result is discarded. This is a genuinely common typo-class bug worth flagging when found for real.
- **Mutually exclusive `if`/`elif` (or an `if` followed by `if not (...)`) guarding two similar-looking branches** can look like accidental duplication at a glance — check the actual boolean conditions before calling it a duplicate-execution bug.
- **Global module-level caches/dicts used for dedup** (e.g. keyed by a Telegram `media_group_id` or similar) are only unique within the scope that generated the key — in a multi-bot/multi-VPS codebase, always check whether `bot_id` (or an equivalent per-instance identifier) needs to be part of the key, since the same message-group ID can occur independently across separate bot sessions.

**Why**: Repeated across at least two sweep rounds — roughly half of raw explorer-subagent findings on `bot/modules/` and `bot/tools/`-style code turned out to be false positives once checked against actual control flow. Direct verification before writing findings into the permanent sweep docs avoids polluting `docs/superpowers/` with defects that don't exist.

**How to apply**: Before adding any finding to a `sweep-*.md` Fix Status table, read the actual surrounding code (not just the subagent's excerpt) and mentally trace both the success and failure paths.
