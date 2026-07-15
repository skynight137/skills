---
name: Always-skip work recommendations
description: Items that recur in next-work suggestions but are intentionally deferred or not applicable — never resurface them.
---

# Always-skip work recommendations

## SEC-1 · Saweria webhook callback signature

**What it is:** Payment webhooks from Saweria arrive without an HMAC secret that could be used to verify the sender. The TODO is in `backend/api/public/endpoints/payment.py`.

**Why skip:** Saweria has not exposed a webhook secret in their API. Implementing validation without a secret is impossible. This is a compatibility constraint, not a project decision. Re-evaluate only when Saweria adds a secret mechanism.

**Do not raise as:** "Enable Saweria callback signature check", "Verify payment webhook authenticity", "SEC-1 fix".

## X3 · Typed UpdateParser / Pydantic layer on webhook updates

**What it is:** A past proposal to wrap raw Telegram Bot API webhook JSON in Pydantic models before dispatching to kurigram handlers.

**Why skip:** kurigram objects are already Pydantic-like (typed, validated). Adding a Pydantic deserialization layer on top of the webhook dict before kurigram processes it would be redundant and inefficient — the same parsing would happen twice. The existing `MessageFactory` pattern (P6) is the correct structural improvement.

**Do not raise as:** "Typed UpdateParser", "Pydantic for webhook adapter", "X3", "model_validate webhook updates".
