---
name: Sweep "Fixed" commits can be genuinely-committed but still incomplete
description: A sweep-doc status flip to Fixed backed by real, present code is not the same as the fix being correct — verify behavior, not just presence.
---

## What happened

A large "fix many issues" commit changed both the code and flipped ~10
sweep-doc findings from Open to Fixed in the same commit. Unlike the earlier
N-30 case (`sweep-doc-false-fixed-claims.md`, where the described code never
existed at all), here the code genuinely existed and matched the doc's
description of *what* was added. Independent review of each fix still found
that 8 of 10 had real remaining bugs: incomplete tombstone-clearing paths,
a race reintroduced under load, a cache-invalidation gap, an unlocked
non-atomic file rewrite, a UX regression on the not-found path, and a stated
goal (stop full member enumeration, log on cap-hit) that the code didn't
actually achieve despite the row's prose claiming it did.

**Why:** "the described code exists" only proves the diff happened, not that
it's correct or complete. A fix description can accurately summarize what
was added while being silent on the recreate-path/eviction-path/mutation-path
edge cases that make it incomplete. Sweep rows are self-reported by whichever
session wrote the fix — they are not independently adversarial about their
own work.

**How to apply:** treat a sweep-doc "✅ Fixed" row as a claim to verify, not
a fact, even when — especially when — the code backing it is real and
present. For concurrency/race fixes in particular, explicitly ask "what
recreates/evicts/mutates this state through a path the fix didn't touch?"
before accepting the row. Use a distinct status (e.g. "⚠️ Partially Fixed")
with a specific gap description when review finds the fix incomplete, rather
than reverting to Open (which would lose the real progress made) or leaving
it as an unqualified Fixed.
