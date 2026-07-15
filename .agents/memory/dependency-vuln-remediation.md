---
name: Dependency vulnerability remediation
description: Strategy for resolving dependency vulnerabilities, especially unfixable transitive ones.
---

- Transitive deps (not directly pinned) may already resolve to a fixed version via `uv lock`
  alone; only direct pins need manual version bumps.
- Some transitive dev-only deps need `uv lock --upgrade-package <name>` explicitly if `uv lock`
  doesn't pick the newer compatible version on its own.
- When a vulnerable transitive dependency has no fixed release upstream, check whether the
  direct dependency pulling it in has a newer version that dropped or replaced it.

**Why:** upgrading only what's directly pinned isn't enough when an unmaintained transitive
dep has no fixed version — the fix often lives one level up the dependency chain.

**How to apply:** when a vuln scanner flags a package you don't import directly, trace which
direct dependency pulls it in before assuming it's unfixable.
