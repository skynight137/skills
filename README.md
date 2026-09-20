# Skills

Agent skills ([agentskills.io](https://agentskills.io) / [skills.sh](https://skills.sh) format) for headless browser automation and coding discipline. Each skill is a self-contained folder (`SKILL.md` + `scripts/` and `references/` where needed) so it installs cleanly with the skills CLI — no external file dependencies.

## Skills

| Skill | Purpose |
|-------|---------|
| [`replit-nix`](skills/replit-nix/) | Replit + Nix: `/nix/store` warm/cold store, `replit.nix` vs `nix-env`, the full transitive `LD_LIBRARY_PATH` closure (the top-level `$REPLIT_LD_LIBRARY_PATH` is never enough), `nix eval`/`path-info` gotchas. Load this when a Replit workload needs system libs. |
| [`replit-knowledge`](skills/replit-knowledge/) | Replit platform facts: `$HOME` wiped on recreate, `$REPL_HOME` is the workspace, XDG pre-set, `REPL_*` env vars, `.replit`/`.bashrc`, npm package firewall, `replit shutdown`. Load this before persisting data or choosing paths on Replit. |
| [`camofox-on-replit`](skills/camofox-on-replit/) | Anti-detection Firefox scraping server — bypasses bot-hardened sites (Cloudflare/Turnstile/WAF, DuckDuckGo) that plain Chromium can't handle. One script provisions everything. |
| [`replit-playwright-chromium`](skills/replit-playwright-chromium/) | Playwright against a pre-installed Chromium — skip `playwright install` entirely; launch via `executable_path`, with an on-demand CDP daemon helper. |

## Install

```bash
npx -y skills add skynight137/skills -s replit-nix
npx -y skills add skynight137/skills -s replit-knowledge
npx -y skills add skynight137/skills -s camofox-on-replit
npx -y skills add skynight137/skills -s replit-playwright-chromium

# or all:
npx -y skills add skynight137/skills
```

## Authoring convention

- A skill lives in `skills/<skill-name>/SKILL.md` (name matches the folder, lowercase + hyphens).
- **Colocate everything the skill needs** inside its own folder (omit a
  part a skill doesn't use):
  - `SKILL.md` — frontmatter (`name`, `description`, `version`, `license`) + body.
  - `scripts/` — executables the skill invokes at runtime (if it has any).
  - `references/` — on-demand docs, loaded only when linked from the body (if it has any).
- Do NOT reference files outside the skill folder — `npx skills add` copies only the skill's own directory, so external paths break on install.

## Verify before publishing

```bash
npx skills add ./ --list        # what the CLI will discover
npx skills add ./ --all --copy  # smoke-test install into a local agent
```

## License

MIT.