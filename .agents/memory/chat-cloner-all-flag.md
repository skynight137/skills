---
name: Chat Cloner -all flag replaces ALLUSERS
description: BroadcastTarget.ALLUSERS was removed; -all flag (ArgFlags.ALL) now applies to any peer target for an all-clients broadcast. PeerType is a StrEnum.
---

# Chat Cloner -all flag replaces ALLUSERS

## Rule
`BroadcastTarget.ALLUSERS` has been removed. The "broadcast to all users" behaviour is now triggered by the **`-all` flag** (`ArgFlags.ALL`) applied on top of any peer target (`-user`, `-bot`, `-channel`, etc.).

**Why:** A dedicated ALLUSERS target created combinatorial explosion in the target-matrix logic. The `-all` flag is orthogonal: it means "apply this target across all managed clients" rather than picking a specific client. This separates *who* from *how many clients*.

**How to apply:**
- `-all` is a **dev-only** flag — gated behind the dev-role check. It multiplies cost by ~3× (one MTProto call per client).
- `PeerType` is a `StrEnum` in `tasks.py` — use `PeerType.USER`, `PeerType.BOT`, etc. for typed peer strings. Never use raw string literals like `"user"` in task config.
- When constructing a broadcast task config, check `ArgFlags.ALL` first; if set, iterate all registered clients with the given peer target.
- `BroadcastTarget.ALLUSERS` must not be re-added — any code paths that used it have been migrated to the flag pattern.
