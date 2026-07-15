---
name: MsgStore chain-mode security and album delivery grouping
description: Non-obvious decisions in bot/modules/special/msg_store.py chain relay and bot/modules/core/start.py delivery — check before touching either.
---

## Chain mode: each relay hop must check its own paid-content catalog

`_is_paid_content` takes an optional `client` param (defaults to `self.client`). The chain
relay loop in `_handle_chain_mode` calls it once per hop with `client=c`, not just once
against the originating source before the loop.

**Why:** A relay bot can have visibility into a chat that the originating bot doesn't sell
access to, but the relay bot's own catalog does. Checking only the source at the top of the
loop let a chain bridge past a hop's own Paid Message boundary. Each hop is a distinct
wallet/product owner and must be checked independently.

**How to apply:** Any new access-control check added to chain-mode (or similar multi-bot
relay features) must be re-evaluated per hop inside the loop, using that hop's client —
never assume a check against the source/first bot covers every downstream bot.

## Album delivery: group by contiguous media_group_id, not "all-or-nothing"

`_deliver_messages` (start.py) no longer requires every message in a delivery batch to
share one `media_group_id` before using `copy_media_group`. It splits the batch into
ordered chunks via `_group_messages_for_delivery`: contiguous runs sharing a group id (2+
members) become an atomic `copy_media_group` chunk; everything else (standalone messages,
and any lone message that only captured a *partial* album) is copied individually via
`copy()`, chained through `reply_to` to preserve order.

**Why:** A single lone message that happens to carry a `media_group_id` (because the
requested range only captured part of an original album) must NOT go through
`copy_media_group` — that call pulls in the *entire* original album from Telegram, not just
the requested subset, silently over-delivering content outside the requested range.

**How to apply:** When modifying delivery/copy logic for stored messages, preserve the
distinction between "single message that happens to have a group id" (per-message copy)
and "2+ contiguous messages sharing a group id" (atomic album copy) — do not revert to an
all-or-nothing check on the whole batch.
