---
name: Short-TTL stat/exists caches need invalidation on mutation, not just a timer
description: A TTL-only cache on exists()/is_dir()/is_file()-style checks goes stale immediately after a write/delete on the same path within the TTL window.
---

## The pattern

Adding a short TTL cache (e.g. 0.5s) in front of a filesystem `stat()` call
to stop scan loops from saturating a thread pool is a reasonable perf fix,
but a pure timer-based cache breaks any "check → mutate → check" call site
on the same path object: `exists()` (false, cached) → create the file via a
different code path → `exists()` again within the TTL still returns the
stale cached `False`.

A timer alone cannot distinguish "nothing changed, cache is still valid"
from "something changed and the cache must be dropped." It needs the
mutating operations (`unlink`, `rename`, `replace`, `touch`, `mkdir`, write,
etc.) on the same object to explicitly clear the cache entry.

**Why:** found in an `AsyncPath` TTL stat cache — a real caller elsewhere in
the codebase does exactly the exists-before/mutate/exists-after pattern this
breaks (download-then-verify), so the perf fix introduced a correctness
regression in normal flow, not just an edge case.

**How to apply:** whenever you see a TTL cache wrapping a filesystem
existence/type check, check whether any mutating method on the same
class/instance fails to invalidate it. If so, either add invalidation on
every mutating method, or cache only for a scope where no mutation of that
path is possible in between (e.g. a single scan pass over read-only paths).
