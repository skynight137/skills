# Skills

Agent skills ([agentskills.io](https://agentskills.io) / [skills.sh](https://skills.sh) format) for headless browser automation and coding discipline.

**Layout doctrine — bundles are curated memory, payloads are referenced.**
A skill bundle holds only `SKILL.md` + `references/` (the knowledge an agent
needs in context). Executable payloads are NOT bundled: they live at the repo
root under `scripts/` — one shared tree (`scripts/setup/`) plus one tree
per machine kind (`scripts/muse/`, `scripts/replit/`) — and the skill
references them by path. This
keeps every skill install — and every agent context that loads it — small.
When an agent actually needs a payload it follows the reference, asks the
operator, and fetches it (clone, or a single file via `curl`).

## Install & run

The standard route is a plain git clone — git is the only tool it needs,
which matters on fresh VMs that have no Node.js yet (the npx route spent a
whole Node install on the installer alone):

```bash
git clone https://github.com/skynight137/skills          # bundles + payloads + docs + full history
git -C skills pull                                       # every later update is just this
bash scripts/setup.sh [--machine muse|repl] [args...]    # THE setup entry, from the clone
```

Bundle-only install (curated memory without payloads, for agents that want
the smallest possible context):

```bash
npx -y skills add skynight137/skills -s muse     # just the muse skill
npx -y skills add skynight137/skills -s replit   # just the replit skill
```

Or a single payload file, fetched on demand:

```bash
curl -fsSL https://raw.githubusercontent.com/skynight137/skills/main/scripts/<path> -o <dest>
```

There is ONE shared setup entry: `scripts/setup.sh` dispatches on
`--machine muse|repl` (auto-detected when omitted) to the profiles and
lanes in `scripts/setup/`. On a target box, land the payload tree where that box's workflows
already point (each `SKILL.md`'s "Payloads" section gives the exact runtime
layout); keep the tree intact — modules resolve via `$SCRIPT_DIR`.

## Repository layout

```
skills/                      skill bundles — curated memory only (SKILL.md + references/)
  muse/                      the Muse VM toolkit
  replit/                    the Replit/Nix workspace toolkit
scripts/                     executable payloads, referenced by the skills by path
  setup.sh                   THE setup entry point (--machine muse|repl);
                             setup PREPARES a box — it never runs workloads
  setup/                     shared setup tree: profiles, lanes and the join engine
    llm-wiki/                the llm-wiki app bundle (installed by the llm-wiki lane)
  tour.py                    the shared keepalive tour — a ready-to-run script, NOT part of setup
  tour.sh                    the tour's launcher (env assembly only; all logic is tour.py)
  socks5-probe.py            one-shot SOCKS5 reachability diagnostic through tailscaled
  muse/                      Muse-VM-only payloads
    ts_proxy_connect.py      ssh ProxyCommand transport (CONNECT via the runtime tunnel proxy)
  replit/                    Replit-only payloads: the nix machinery (nixenv, resolve-libs.sh,
                             generate-closure.sh, libpool.sh), dot_replit.py (.replit editor),
                             probe-tailnet-peers.sh, start-replit-chromium.sh, join-lifecycle-test.sh
docs/                        lab results & studies — cross-machine findings (detection
                             studies, lane comparisons), NOT box operating guidance; fleet build guide
tests/                       CI tool-setup driver (tool-setup.sh) + test scripts
.github/workflows/ci.yml     CI: payload checks + one isolated setup lane per tool
```

## Skills

| Skill | Purpose |
|-------|---------|
| [`muse`](skills/muse/) | The Muse sandbox toolkit — everything that only makes sense on a Muse VM, as one installable skill with topic references: platform facts (systemd-nspawn container, btrfs home vs ephemeral overlay root, env/user/ssh resolution quirks), the egress model (fake-IP DNS, CONNECT proxy, permission categories, no UDP), the two Tailscale join routes (built-in connector vs userspace auth-key node) and the reverse-SSH pattern that actually yields inbound access, and the automation trio (systemd units vs runtime cron vs hooks). Payload: [`scripts/muse/`](scripts/muse/) + the shared tree [`scripts/setup/`](scripts/setup/). |
| [`replit`](skills/replit/) | The Replit sandbox toolkit — everything that only makes sense on a Replit/Nix workspace, as one installable skill with topic references: platform facts (`$HOME` wiped on recreate, `REPL_HOME`/XDG, the env-load channel, rc & git persistence), Nix store work (`.replit [nix] packages` / `replit.nix` / `nix-env`, the full transitive `LD_LIBRARY_PATH` closure — the top-level `$REPLIT_LD_LIBRARY_PATH` is never enough), Playwright on the bundled Chromium (no browser download), and the Camoufox anti-detection Firefox server (Cloudflare/Turnstile/WAF sites, cookie persistence, keep-alive). Payload: [`scripts/replit/`](scripts/replit/) + the shared tree [`scripts/setup/`](scripts/setup/). |

## Authoring convention

- A skill bundle lives in `skills/<skill-name>/` and contains ONLY:
  - `SKILL.md` — frontmatter (`name`, `description`, `version`, `license`) + body.
  - `references/` — on-demand docs, loaded only when linked from the body (if it has any).
- Executables live OUTSIDE the bundle at repo-root `scripts/`, in one
  intact tree: the shared `scripts/setup/` (the one entry's profiles,
  modules and lanes) plus per-machine trees holding only what that VM
  kind needs (modules resolve via `$SCRIPT_DIR`).
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
