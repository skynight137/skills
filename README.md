# Skills

Agent skills ([agentskills.io](https://agentskills.io) / [skills.sh](https://skills.sh) format) for headless browser automation and coding discipline. Each skill is a self-contained folder (`SKILL.md` + `scripts/` and `references/` where needed) so it installs cleanly with the skills CLI — no external file dependencies.

## Skills

| Skill | Purpose |
|-------|---------|
| [`replit`](skills/replit/) | The Replit sandbox toolkit — everything that only makes sense on a Replit/Nix workspace, as one installable skill with topic references: platform facts (`$HOME` wiped on recreate, `REPL_HOME`/XDG, the env-load channel, rc & git persistence), Nix store work (`.replit [nix] packages` / `replit.nix` / `nix-env`, the full transitive `LD_LIBRARY_PATH` closure — the top-level `$REPLIT_LD_LIBRARY_PATH` is never enough), Playwright on the bundled Chromium (no browser download), and the Camoufox anti-detection Firefox server (Cloudflare/Turnstile/WAF sites, cookie persistence, keep-alive). |

## Install

```bash
npx -y skills add skynight137/skills -s replit

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