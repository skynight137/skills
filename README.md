# Skills

Agent skills ([agentskills.io](https://agentskills.io) / [skills.sh](https://skills.sh) format) for headless browser automation and coding discipline.

**Layout doctrine — bundles are curated memory, payloads are referenced.**
A skill bundle holds only `SKILL.md` + `references/` (the knowledge an agent
needs in context). Executable payloads are NOT bundled: they live at the repo
root under `scripts/<skill>/` and the skill references them by path. This
keeps every skill install — and every agent context that loads it — small.
When an agent actually needs a payload it follows the reference, asks the
operator, and fetches it (clone, or a single file via `curl`).

## Install & run

Install the (slim) bundle with the skills CLI:

```bash
npx -y skills add skynight137/skills -s muse     # just the muse skill
npx -y skills add skynight137/skills -s replit   # just the replit skill
```

Payloads are fetched on demand, never assumed present:

```bash
git clone https://github.com/skynight137/skills          # recommended: payloads + docs + full history
bash scripts/<skill>/setup.sh [args...]                  # per-skill entry point, from the clone

# or a single payload file:
curl -fsSL https://raw.githubusercontent.com/skynight137/skills/main/scripts/<skill>/<path> -o <dest>
```

There is no shared dispatcher and no `--machine` flag: the skill names the
target. On a target box, land the payload tree where that box's workflows
already point (each `SKILL.md`'s "Payloads" section gives the exact runtime
layout); keep the tree intact — modules resolve via `$SCRIPT_DIR`.

## Skills

| Skill | Purpose |
|-------|---------|
| [`muse`](skills/muse/) | The Muse sandbox toolkit — everything that only makes sense on a Muse VM, as one installable skill with topic references: platform facts (systemd-nspawn container, btrfs home vs ephemeral overlay root, env/user/ssh resolution quirks), the egress model (fake-IP DNS, CONNECT proxy, permission categories, no UDP), the two Tailscale join routes (built-in connector vs userspace auth-key node) and the reverse-SSH pattern that actually yields inbound access, and the automation trio (systemd units vs runtime cron vs hooks). Payload: [`scripts/muse/`](scripts/muse/). |
| [`replit`](skills/replit/) | The Replit sandbox toolkit — everything that only makes sense on a Replit/Nix workspace, as one installable skill with topic references: platform facts (`$HOME` wiped on recreate, `REPL_HOME`/XDG, the env-load channel, rc & git persistence), Nix store work (`.replit [nix] packages` / `replit.nix` / `nix-env`, the full transitive `LD_LIBRARY_PATH` closure — the top-level `$REPLIT_LD_LIBRARY_PATH` is never enough), Playwright on the bundled Chromium (no browser download), and the Camoufox anti-detection Firefox server (Cloudflare/Turnstile/WAF sites, cookie persistence, keep-alive). Payload: [`scripts/replit/`](scripts/replit/). |

## Authoring convention

- A skill bundle lives in `skills/<skill-name>/` and contains ONLY:
  - `SKILL.md` — frontmatter (`name`, `description`, `version`, `license`) + body.
  - `references/` — on-demand docs, loaded only when linked from the body (if it has any).
- Executables live OUTSIDE the bundle at `scripts/<skill-name>/` (repo root),
  in one intact tree (entry point + modules; modules resolve via `$SCRIPT_DIR`).
- `SKILL.md` carries a **Payloads** section stating the path rule (what
  `scripts/…` means in the docs) and the fetch flow (ask the operator →
  clone or curl → land at the runtime layout). Never bundle executables
  into a skill folder — that is what bloated the context this layout avoids.

## Verify before publishing

```bash
npx skills add ./ --list        # what the CLI will discover
npx skills add ./ --all --copy  # smoke-test install into a local agent
```

## License

MIT.
