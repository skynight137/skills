---
name: LRU-evicted per-key lock tables can reopen their own race
description: Why capping a per-key asyncio.Lock table with LRU eviction can silently defeat the serialization it was added for, under load.
---

## The pattern

A common fix for "concurrent read-modify-write on the same key" bugs is a
per-key `asyncio.Lock` table: `locks: OrderedDict[K, Lock]`, capped at some
max size and evicting the oldest entry (`popitem(last=False)`) to bound
memory across many distinct keys.

This is unsafe if eviction can remove an entry **while its lock is still
held** by an in-flight coroutine. A second call for the *same* key, arriving
after the entry was evicted, calls the same "get or create" accessor and
gets a **brand-new** `Lock` object — because the old one is gone from the
dict — so it does not actually wait on the original holder at all. Two
callers for the same key can then run concurrently again, exactly the race
the lock table was built to prevent.

This only shows up under load: it requires enough distinct keys cycling
through the table (more than the cap) while at least one lock is still held,
so it easily passes casual testing and code review.

**Why:** found in a per-user settings lock table (`OrderedDict` capped at
5,000 entries, LRU eviction) — the eviction path did not check whether the
lock being evicted was currently acquired.

**How to apply:** when reviewing or designing a per-key lock table with
bounded size, verify the eviction policy either (a) never evicts a
currently-held lock (e.g. refcount the lock and only evict when refcount is
zero), or (b) accepts the race as a deliberate tradeoff and documents it.
"Cap size with LRU eviction" is not a safe default for a lock table the way
it is for a plain value cache.
