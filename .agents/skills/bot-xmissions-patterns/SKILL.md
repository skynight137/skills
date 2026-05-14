---
name: bot-xmissions-patterns
description: Use this skill when working on the XMissions system — adding new missions, modifying the menu, changing the callback schema, or understanding how xmissions.py routes to mission modules. Covers menu flow, callback schema (xm <user_id> <action>), mission interface contract, owner CRUD management, reward types, rotator_blogs deep link flow, referral mission dual-sided reward system, and how to add new mission types.
---

# Bot — XMissions Patterns

## What Is the XMissions System?

A centralized menu of configurable daily reward missions accessible via `/xmissions`. Owners create and manage missions through the bot's built-in management UI (no code changes needed). Each mission type lives in its own module; `xmissions.py` is the router.

---

## File Map

```
database/models/mission.py               # MissionModel, MissionType, MissionRewardType
database/models/claim_record.py          # ClaimRecordModel (daily completion records)
database/models/referral_record.py       # ReferralRecordModel (cumulative referral progress)
database/collections/missions.py         # MissionsCollection — owner-scoped CRUD + get_active_by_bot
database/collections/claim_records.py    # ClaimRecordsCollection — has_claimed, record_claim
database/collections/referral_records.py # ReferralRecordsCollection — add_referred_user, mark_rewarded

bot/modules/xmissions/xmissions.py      # Menu + callback router (all `xm` callbacks)
bot/modules/xmissions/reward.py         # grant_reward(client, user_id, mission) → (bool, str)
bot/modules/xmissions/instant_claim.py  # instant_claim_task() — eligibility check only
bot/modules/xmissions/rotator_blogs.py  # rotator_blogs_task() — Blogger link generation
bot/modules/xmissions/referral.py       # referral_task() + build_ref_token() + grant_referred_reward()
bot/modules/xmissions/owner_manage.py   # Owner CRUD UI (add/toggle/remove missions)
bot/modules/core/start.py               # _handle_xm_deeplink() + _handle_xm_ref_deeplink()
bot/plugins/xmissions.py                # Registers /xmissions and xm callbacks
bot/utils/constants/tasks.py            # CallbackPrefix.XMISSIONS = "xm"
bot/utils/constants/display.py          # ButtonText.MANAGE_MISSIONS, CLAIM_REWARD, MISSION_TYPE_REFERRAL, etc.
bot/modules/docs/xmissions.md           # Full technical reference
```

---

## User Flow

```
/xmissions
  └─ xmissions_menu()                        → loads missions from DB, shows dynamic menu
       ├─ [🎁 Rotator Mission] clicked        → xmissions_callback() action=m_<mission_id>
       │    └─ rotator_blogs_task()           → edits message to task text + [🔙 Back]
       ├─ [⚡ Instant Mission] clicked        → xmissions_callback() action=m_<mission_id>
       │    └─ instant_claim_task()           → edits message to claim text + [⚡ Claim] [🔙]
       │         └─ [⚡ Claim] clicked        → action=claim_<mission_id>
       │              └─ grant_reward()       → edits message to result + [🔙 Back]
       ├─ [🤝 Referral Mission] clicked       → xmissions_callback() action=m_<mission_id>
       │    └─ referral_task()               → shows progress + unique invite link + [🔙 Back]
       ├─ [⚙️ Manage Missions] clicked        → owner only → owner_missions_menu()
       ├─ [🔙 Back] clicked                   → action=menu → re-edit to mission list
       └─ [⛔ Close] clicked                  → action=close → delete message
```

---

## Callback Schema

```
xm <user_id> <action>
```

| Action | Effect |
|---|---|
| `menu` | Re-edit to mission list menu |
| `close` | Delete menu message |
| `m_<mission_id>` | Load mission, call task function, show result |
| `claim_<mission_id>` | Grant instant_claim reward, record claim |
| `owner` | Show owner CRUD menu (owner/dev only) |
| `oadd` | Show mission type picker |
| `otype_<type>` | Show reward type picker |
| `ortype_<rw>\|<mt>` | Start sequential text-input add flow |
| `otog_<mission_id>` | Toggle is_active |
| `orem_<mission_id>` | Remove mission |

Ownership check always applied: `query.from_user.id == user_id`.
Owner/dev guard for management: `user_id in (client.owner_id, client.dev_id)`.

**Separator note for `ortype_`:** uses `|` between reward_type and mission_type to avoid ambiguity with underscore-containing type names (e.g. `instant_claim`, `rotator_blogs`).

---

## Mission Interface Contract

Every mission module must export a coroutine with this signature:

```python
async def <type>_task(client, user_id: int, mission: MissionModel) -> tuple[bool, str]:
    """
    Returns:
        (True, task_text)   — mission available; text shown to user
        (False, error_text) — already claimed, misconfigured, or unavailable
    """
```

The `MissionModel` argument carries all per-mission config (links, enc_key, reward fields).
`xmissions_callback` handles display and keyboards. The task function only returns text.

For `instant_claim` missions: `(True, text)` → claim button shown by caller.
For `rotator_blogs` and `referral` missions: only Back button shown (link/info embedded in text).

---

## Mission Types

| Type | Value | Icon | Extra Fields Required |
|---|---|---|---|
| Rotator Blogs | `rotator_blogs` | 🎁 | `rotator_links`, `rotator_enc_key` |
| Instant Claim | `instant_claim` | ⚡ | (none beyond base reward fields) |
| Referral | `referral` | 🤝 | `min_referral_count`; optionally `referred_reward_amount` or `referred_reward_product_id` |

## Reward Types

| Type | Value | Required Field | How Granted | Who Can Create |
|---|---|---|---|---|
| Credits | `credits` | `reward_amount: float` | `WalletService.add_credits()` | `is_dev` only |
| Product | `product` | `reward_product_id: str` | `InventoryService.add_inventory()` + optional access link | Any owner |

**Credits access control:** `owner_type_selected()` checks `user_id == client.dev_id`. If False, the `💰 Credits` button is not added to the keyboard — only `📦 Product` appears. This is enforced in the UI layer; no extra check needed at save time.

**Invited-friend reward with Product missions:** When `reward_type=product`, the add-mission flow skips the "credits for invited friend" prompt entirely (`referred_reward_amount` stays `None`). The prompt is only shown when `rtype == MissionRewardType.CREDITS`. Invited friends who join via a Product-reward referral link get no automatic credit bonus.

---

## Enum Reference

```python
class MissionType(StrEnum):
    ROTATOR_BLOGS = "rotator_blogs"
    INSTANT_CLAIM = "instant_claim"
    REFERRAL      = "referral"

class MissionRewardType(StrEnum):
    CREDITS = "credits"
    PRODUCT = "product"
```

Values stored in MongoDB remain lowercase. Always reference by UPPERCASE attribute:
- `MissionType.ROTATOR_BLOGS`, `MissionType.INSTANT_CLAIM`, `MissionType.REFERRAL`
- `MissionRewardType.CREDITS`, `MissionRewardType.PRODUCT`

---

## MissionModel Fields

```python
class MissionModel(CollectionModel):
    id: str                              # token_hex(5) — 10 hex chars
    bot_id: int                          # Owner bot Telegram user ID
    mission_name: str                    # Display name on button (max 64 chars)
    mission_type: MissionType            # ROTATOR_BLOGS | INSTANT_CLAIM | REFERRAL
    reward_type: MissionRewardType       # CREDITS | PRODUCT
    reward_amount: float | None          # Required when reward_type=CREDITS
    reward_product_id: str | None        # Required when reward_type=PRODUCT
    reward_packet_index: int             # 0-based packet index (product only)
    min_referral_count: int              # default=1 — threshold for referrer reward (REFERRAL only)
    referred_reward_amount: float | None # Credits granted to invited user on joining (REFERRAL only)
    referred_reward_product_id: str|None # Product granted to invited user on joining (REFERRAL only)
    is_active: bool                      # Only active missions appear in menu
    created_at: datetime
    rotator_links: list[str]             # Required when mission_type=ROTATOR_BLOGS
    rotator_enc_key: int                 # Required when mission_type=ROTATOR_BLOGS
```

DB access via `client.db_manager.missions` (MissionsCollection).
Claim records via `client.db_manager.claim_records` (ClaimRecordsCollection).
Referral records via `client.db_manager.referral_records` (ReferralRecordsCollection).

---

## Claim Record Key Format

```
<user_id>_<mission_id>_<YYYYMMDD>
```

One document per user per mission per UTC calendar day. Reset at midnight UTC.
Used by `instant_claim` and `rotator_blogs` only.

---

## Referral Record Key Format

```
<referrer_id>_<mission_id>
```

One document per referrer per mission. Cumulative — never daily-reset.
Fields: `referrer_id`, `mission_id`, `bot_id`, `referred_users: list[int]`, `count: int`, `rewarded: bool`.

---

## Rotator Blogs Deep Link Flow

Token plaintext: `_xm_<mission_id>_<user_id>_<YYYYMMDD>`
Token built by `rotator_blogs.build_xm_token(client, mission_id, user_id, task_date)`.

```
user clicks rotator link (Blogger article)
  → Blogger redirects to t.me/<bot>?start=<encrypted_token>
  → start.py: _handle_xm_deeplink(client, message, user_id, xm_parts=[mission_id, user_id, date], is_new_user)
  → validate: token_user_id == message.from_user.id
  → load MissionModel from db_manager.missions
  → check claim_records.has_claimed(user_id, mission_id, task_date)
  → grant_reward(client, user_id, mission)
  → claim_records.record_claim(user_id, mission_id, task_date, ...)
```

Deep link prefix routing in `start.py`: `if prefix == "xm":` (from `_xm_…` token).
Sub-prefix routing inside `_handle_xm_deeplink`: `if xm_parts[0] == "ref":` → referral path.

See `project-blogger-integration` skill for Blogger XOR encryption details.

---

## Referral Deep Link Flow

Token plaintext: `_xm_ref_<mission_id>_<referrer_user_id>`
Token built by `referral.build_ref_token(client, mission_id, referrer_id)`.
No date — progress is cumulative, not daily-reset.

```
User A opens /xmissions → selects Referral mission
  → referral_task() shows progress + unique invite link

User B clicks A's link
  → start_menu: is_new_user = await record_user(B)   ← True only first-ever /start
  → _handle_xm_deeplink dispatches to _handle_xm_ref_deeplink(is_new_user)
  → validate ref_parts; reject self-referral; gate on is_new_user
  → referral_records.add_referred_user(referrer=A, referred=B)  ← $addToSet atomic
  → grant_referred_reward(client, B, mission)   ← B gets welcome credits/product
  → B sees welcome message with reward notice
  → if A's count >= min_referral_count and not yet rewarded:
      → grant_reward(client, A, mission)
      → referral_records.mark_rewarded(A, mission_id)
      → DM A: "🎉 Referral Complete!"
  → else:
      → DM A: "🤝 Progress: X/Y"
```

**Circular referral (A→B→A) is blocked naturally:** A is not a new user from B's perspective, so `is_new_user=False` rejects A clicking B's link.

**Key functions in `referral.py`:**
- `referral_task(client, user_id, mission)` — always returns `(False, text)` (no claim button needed)
- `build_ref_token(client, mission_id, referrer_id)` — encrypts the deep link token
- `grant_referred_reward(client, user_id, mission)` — grants B's welcome reward, returns reward description string

---

## Owner Add-Mission Flow

Owner presses [➕ Add Mission] → `oadd` callback → guided multi-step flow:

1. `otype_<type>` callback — pick mission type (rotator_blogs | instant_claim | referral)
2. `ortype_<rw>|<mt>` callback — pick reward type
   - `is_dev`: sees `💰 Credits` + `📦 Product`
   - non-dev owner: sees `📦 Product` only
3. Bot sends prompts + uses `wait_for_message(query, partial(_process_input, key=..., data=...))` for:
   - Mission name
   - Reward amount (credits) OR product_id (product)
   - Rotator links + XOR enc key (rotator_blogs only)
   - Min referral count (referral only)
   - Invited-friend credits prompt (referral + **Credits** reward only; skipped for Product reward)
4. `MissionModel` saved via `db_manager.missions.add(mission)`

Cancel detection: `data.get("_cancelled")` or missing key after wait_for_message.

---

## Adding a New Mission Type — Checklist

1. **Enum** — add `MY_TYPE = "my_type"` to `MissionType` in `database/models/mission.py`.

2. **Module** — `bot/modules/xmissions/my_type.py`
   ```python
   async def my_type_task(client, user_id: int, mission: MissionModel) -> tuple[bool, str]:
       ...
   ```

3. **Icon** — add to `_TYPE_ICON` dicts in both `xmissions.py` and `owner_manage.py`:
   ```python
   _TYPE_ICON = { ..., MissionType.MY_TYPE: "🏆" }
   ```

4. **Dispatch** — add branch to `_dispatch_task()` in `xmissions.py`:
   ```python
   if mission.mission_type == MissionType.MY_TYPE:
       return await my_type_task(client, user_id, mission)
   ```

5. **Owner add** — add button in `owner_add_start()` in `owner_manage.py`:
   ```python
   buttons.callback_button(ButtonText.MISSION_TYPE_MY_TYPE, f"{XM} {user_id} otype_my_type")
   ```
   Add the corresponding `ButtonText.MISSION_TYPE_MY_TYPE` to `utils/constants/display.py`.

6. **No plugin changes needed.** `xmissions.py` already catches all `^xm` callbacks.

7. **Docs** — update `bot/modules/docs/xmissions.md` and this skill file.
