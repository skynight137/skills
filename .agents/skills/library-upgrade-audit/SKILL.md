---
name: library-upgrade-audit
description: >-
  Use when a library has been upgraded, or when the user asks whether a newer
  library version introduces features that could improve current usage patterns.
  Also use when the user says "check if X improved", "does X Y.Z help us", or
  "audit our usage of X".
---

# Library Upgrade Audit

## Overview

Cross-reference a library's changelog against the patterns we *actually use* in this codebase to find concrete improvement opportunities. The reference doc lives at `docs/superpowers/library-usage.md`.

**Not the same as `dependency-updater`** (which bumps versions) or `dependency-upgrade` (which handles migration from a major).  
This skill answers: *now that we're on the new version, does it let us write better code?*

## When to Use

- User says "X upgraded to Y.Z — check for improvements"
- User says "does the new motor/structlog/httpx/etc. help us?"
- After `uv sync` or `npm install` pulls in a newer version of a tracked library
- Periodic "maximize library usage" review sessions

**Not when:** The user just wants to *bump* a version number → use `dependency-updater`.

## Steps

**1. Open `docs/superpowers/library-usage.md`**  
Find the section for the library. Read: current version, patterns used, and "Watch for" notes.

**2. Fetch the changelog**  
Use web search or the library's GitHub releases page. Scope: current pinned version → new version only.

**3. Cross-reference**  
For each new changelog item, ask:
- Does it replace a pattern listed under "Patterns used"? → **Adopt**
- Does it add capability we implement manually? → **Evaluate**
- Does it deprecate something we currently use? → **Migrate**

**4. Grep for affected call sites**  
Confirm the pattern exists in the codebase before proposing any change.

**5. Report findings**

```
## Library Upgrade Audit — <library> <old> → <new>

### 🟢 Adopt
<feature>: current pattern → new pattern. Files: X. Saves: Y lines / complexity.

### 🟡 Evaluate
<feature>: description. Tradeoff: note.

### 🔴 Migrate (deprecated)
<API>: deprecated in <ver>, removed in <ver>. Current usage: files. Replace with: new API.

### ✅ No change needed
<brief note if nothing overlaps>
```

**6. Update `docs/superpowers/library-usage.md`**  
After implementing changes: bump the version, update patterns, refresh "Watch for" notes.

## Key Libraries Tracked

structlog · motor · pydantic · fastapi · redis · httpx · aiogoogle · tenacity · kurigram · feedparser/bs4

Full details (current versions, exact patterns, watch-for notes) → `docs/superpowers/library-usage.md`
