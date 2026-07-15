---
name: Rich message help display — send_help_menu
description: get_help_menu returns raw HTML; callers must send it via send_rich_message (32 768-char limit), never plain message.reply() which has a 4 096-char limit and triggers MessageTooLong on large help texts.
---

## The rule

`get_help_menu(message, key)` returns `(html_text, buttons)`. The HTML text for commands like `clone_chat` exceeds 4 096 chars.

**Never** send it via `message.reply(text, reply_markup=markup)` — plain text send (4 096-char limit) triggers `MessageTooLong` → `.txt` file fallback.

**Always** send it via `send_help_menu(client, message, key)` which uses `send_rich_message` (32 768-char limit).

**Why:** Bot API 10.1 rich messages have a 32 768-char limit; plain sendMessage caps at 4 096. `main_clone_chat` (and other large help texts) exceed 4 096.

**How to apply:** Any new module that shows a command's help page must call `send_help_menu(self.client, self.message, key)` — never unpack `get_help_menu` and call `reply()`.

## Callback edits in help.py

`help_menu_callback` correctly uses `edit_message_text(..., rich_message=InputRichMessage(html=text))` for in-place navigation. This is backed by `EditMessage` TL flag.23 in kurigram. The initial display (via the module callers) was the source of the bug, not the callbacks.

## _SEMAPHORED_METHODS

This frozenset was dead code — the semaphore logic was commented out in `wrap_pyrogram_methods`. Removed entirely to avoid future confusion.
