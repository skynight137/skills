---
name: Partial-fix review pitfalls
description: Recurring "looks fixed but isn't" patterns found when a fix validates or checks something but doesn't act on the result.
---

A code-review pass on a batch of small fixes surfaced three variants of the same root problem: a fix adds a check or transformation, but a later line still uses the *pre-check* value instead of the checked/transformed one.

## Validate-then-discard
A partial-update path builds a merged model and runs it through `model_validate` (or similar) purely to catch bad input — then persists the original raw dict instead of the validated instance's dump. Validation without using its output only prevents rejection; it does not apply coercion, defaults, or normalization to what's actually written.

**How to apply:** whenever a fix adds validation before a write, check whether the write statement changed too. If the write still references the pre-validation variable, the fix is incomplete.

## Existence-only conflict checks before a destructive action
A "resume interrupted migration" fix checked only whether a target document *exists* before deleting the source — not whether its *content* actually matches what the migration would have produced. Existence is necessary but not sufficient to prove a resumed operation vs. a genuine conflict with unrelated data.

**How to apply:** before any delete/overwrite gated on "target already exists, so this must be a retry," compare the target's actual content against the expected result, not just its presence.

## Early return skips trailing cleanup

When a function has shared cleanup at the bottom (e.g. `await message.delete()`, resource close, or metric increment), an early `return` added by a partial fix silently skips that cleanup for the new branch. The test that validates the fix passes (the new path works), but the omitted cleanup only surfaces during integration.

**How to apply:** whenever a fix adds an early `return` inside a branch, grep for all cleanup statements after the final `return` in the function and replicate them in the new early-return branch.

## React per-resource fetch-attempted tracking

A `useState(false)` guard for "did we already try to fetch?" stays `true` across React Router route changes unless it is explicitly reset. In a detail-page component that re-uses the same component for different resource IDs (e.g. `/product/:id`), a boolean flag causes the second product to silently skip fetching if the first attempt already flipped it. Replace with a `Set` keyed by resource ID (`useState(() => new Set())`), so each distinct ID gets its own independent attempt guard.

**How to apply:** whenever a "fetch attempted" boolean is used in a component that can receive different resource IDs via URL params, use a Set keyed by ID instead.

## Scheme/format truthiness after a regex-to-parser rewrite
Replacing a permissive hand-rolled regex with a stdlib parser (e.g. `urllib.parse.urlparse`) can silently narrow accepted input if the new code checks a derived truthy field (`parsed.scheme`) instead of the literal marker the old regex keyed off. Example: `urlparse("user:pass@host")` reads `user` as the scheme (colon before `@`, no `://`), so `parsed.scheme` is truthy but wrong — checking for the literal `"://"` substring first avoids the misclassification.

**How to apply:** when swapping a regex validator for a stdlib parser, enumerate the old regex's *optional* groups (scheme, credentials, port) and write concrete test inputs for each before/after — don't just check the "obviously valid" cases.
