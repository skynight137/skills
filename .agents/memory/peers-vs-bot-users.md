---
name: Peers vs bot_users for broadcast targeting
description: Why Chat Cloner and broadcast use db_manager.pyrogram peers, not bot_users, for user targeting — and what bot_users is still needed for.
---

# Peers vs `bot_users` for Broadcast Targeting

## The rule

Chat Cloner (`-dc users`, `-dc supergroups`, `-dc channels`, etc.) iterates peers via
`db_manager.pyrogram.iter_peers(bot_id, peer_type)` / `get_peer_count(bot_id, peer_type)`.

`bot_users` (via `UserInteractionTracker`) is **kept only** for `is_new_user`
detection in `start_menu` → referral / XMissions system.

## Peer ID sign convention (critical)

MongoDB `peers_<bot_id>._id` values are:
- **positive** for users and bots (matches Telegram user_id directly)
- **negative** for channels, supergroups, and groups (stored as the negation of MTProto
  `channel_id` / `chat_id` — mirrors Pyrogram's `peer.id` property)

`iter_peers` keyset pagination must start from `-(2**62)` (not `0`) or channels/supergroups
will yield zero results (all their IDs are negative and would be filtered out by `_id > 0`).

Pyrogram's `resolve_peer` handles negative IDs correctly — it maps the negative value back to
`InputPeerChannel(channel_id=abs(id), access_hash=...)`.

## Why

| Collection | Written when | Count (live, bot 8277414548) |
|------------|-------------|------------------------------|
| `bot_users` | User sends `/start` only | 99 |
| `peers_<bot_id>` (type=user) | Any MTProto exchange (start, group msg, admin action, inline, …) | 164 |

Peers give **65% more reach** with zero extra work.  
Both collections are equally persistent with MongoStorage (no SQLite files used).

## Where the methods live

`database/collections/pyrogram.py` — `PyrogramCollection`:
- `async def get_peer_count(bot_id, peer_type) -> int` — `count_documents({"type": peer_type})`
- `async def iter_peers(bot_id, peer_type, batch_size=1000) -> AsyncIterator[int]` — keyset pagination starting at `-(2**62)`

## What was NOT changed

- `bot/utils/user_tracker.py` — `UserInteractionTracker.record_user()` and `get_users_list()` unchanged
- `database/collections/bot_users.py` — unchanged
- Any `/start` flow touching `is_new_user` — unchanged

**Why:** `is_new_user` requires "was this the first /start ever?" semantic. Peers
only store `last_update_on` with no first-seen timestamp, so they cannot answer this question.
