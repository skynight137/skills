---
name: Bot reassignment order of operations
description: DB node_id update must happen BEFORE stop/unregister; use unregister_client not remove_client to avoid deleting the DB document.
---

# Bot reassignment — order of operations

**Rule:** Always update `bot.node_id` in MongoDB **before** stopping and unregistering the client locally.

**Why:** The Change Stream on the target node fires as soon as the DB write lands. If you stop the client first, there's a window where the bot is not running on either node. Doing the DB write first means the target node's `_on_bot_assigned` callback can start the bot the moment it arrives — zero gap.

**The correct sequence:**
```
1. await user_bot_config.update_fields({"node_id": target_node_id})  ← DB first
2. await user_bot.bot_manager.stop_client(bot_id)                    ← then stop
3. await user_bot.bot_manager.unregister_client(bot_id)              ← then deregister
```

**`unregister_client` vs `remove_client`:**
- `unregister_client(bot_id)` — removes from `_clients` dict only, no DB touch. Correct for reassignment.
- `remove_client(bot_id)` — deletes the bot document from MongoDB entirely. **Wrong** for reassignment; the target node would have nothing to pick up.
