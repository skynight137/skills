---
name: Node heartbeat upsert datetime mode
description: NodeStatusCollection.upsert must use mode="python" to keep datetime as BSON DateTime; mode="json" stores ISO strings and breaks age calculation.
---

# Node heartbeat upsert — datetime serialisation

**Rule:** `NodeStatusCollection.upsert` calls `model.model_dump(mode="python", ...)`, never `mode="json"`.

**Why:** Pydantic `mode="json"` converts `datetime` → ISO-8601 string. Motor then stores a plain string in MongoDB instead of a BSON DateTime. When read back, the field is a string, so `(datetime.now(timezone.utc) - node.last_seen)` raises a `TypeError`. The age/staleness calculation in the reassign-node UI silently breaks.

**How to apply:** Any new collection whose model contains `datetime` fields that need arithmetic on read-back should use `mode="python"` in its upsert/replace path. `mode="json"` is safe only when the datetime will never be used for subtraction (e.g. stored purely for display).
