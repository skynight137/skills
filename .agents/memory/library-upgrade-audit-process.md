---
name: Library upgrade audit process
description: How to audit a library upgrade for improvement opportunities — skill, reference doc, and trigger phrases.
---

# Library upgrade audit process

## Skill
Load `.agents/skills/library-upgrade-audit/SKILL.md` when any library upgrade is mentioned.

## Reference doc
`docs/superpowers/library-usage.md` — maps each key library to its current version, exact patterns used in the codebase, and "watch for" notes for the next upgrade.

## Trigger phrases (any natural language variant of)
- "X upgraded to Y.Z"
- "check if X Y.Z improves anything"
- "X has a new version, audit it"

## Process summary
1. Read `library-usage.md` entry for the library
2. Fetch changelog between current pin and new version
3. Cross-reference: new API vs current patterns
4. Grep affected call sites to confirm pattern exists
5. Present findings: 🟢 Adopt / 🟡 Evaluate / 🔴 Migrate / ✅ No change
6. After implementing: update `library-usage.md` version + patterns + watch-for notes

**Why:** Libraries evolve faster than codebases. Without a snapshot of current usage patterns, changelog review is generic. With `library-usage.md` as the cross-reference, every upgrade audit is targeted to actual code.
