---
name: IndexedCollection secondary-index lock pattern
description: IndexedCollection.update_one and _apply_remote_change lock rules for safe index swaps and cross-node cache invalidation.
---

# IndexedCollection lock pattern for secondary indexes

## The rule

`IndexedCollection` maintains secondary in-memory `_indexes` dicts alongside `self.cache`. Any mutation of these structures must be lock-protected because they are read by concurrent coroutines.

**`update_one` lock sequence:**
```python
async with self.lock:
    old_model = self.cache.get(id)          # snapshot under lock
result, updated_model = await super().update_one(id, data)   # release lock across await
async with self.lock:
    self._add_to_indexes(updated_model)     # add new entry
    if old_model:
        self._remove_from_indexes(old_model)  # remove old entry
# Both under same lock acquisition — no suspend point between them
```

**Why:** Reading `old_model` without the lock gives a stale snapshot; using it after the `await` removes a ghost entry. Swapping indexes without a lock lets concurrent readers see a missing entry during the gap between remove and add.

**`_apply_remote_change` override:** Subclasses that maintain derived secondary indexes (beyond what `IndexedCollection` manages) must override `_apply_remote_change` to invalidate those indexes after calling `super()`:

```python
async def _apply_remote_change(self, change: dict) -> None:
    await super()._apply_remote_change(change)
    self._invalidate_my_derived_cache()   # e.g. _invalidate_telegram_feeds_cache()
```

Without this, remote node mutations (Change Stream) update the main cache but leave derived indexes stale — causing wrong lookups until the next local write.

**`load()` lock sequence — index rebuild must also hold lock:**
```python
await super().load()               # fills self.cache under its own lock, then releases
async with self.lock:              # must re-acquire before rebuilding indexes
    for model in self.cache.values():
        self._add_to_indexes(model)
```

**Why:** After `super().load()` releases the lock, a concurrent `get_by_index()` call can arrive before the index rebuild loop completes. It sees a fully-populated cache but an empty index, returning wrong results. Holding the lock across the rebuild closes this window. Confirmed fix in Rounds 15–16 (2026-06-24).

**How to apply:** Any time a new derived secondary index is added to an `IndexedCollection` subclass, override `_apply_remote_change` to invalidate it. Also ensure any `load()` override wraps its index rebuild in `async with self.lock:`.
