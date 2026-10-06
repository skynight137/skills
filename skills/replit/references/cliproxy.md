# CLIProxyAPI on Replit — CLI OAuth subscriptions → OpenAI/Claude APIs

**What it is:** [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
wraps OAuth-based CLI subscriptions (Codex/ChatGPT, Claude Code, Antigravity,
Gemini CLI, Kimi, xAI, Copilot, Kiro…) into OpenAI + Claude + Gemini compatible
API endpoints on one port. It is NOT an http/socks proxy — it is a
subscription→API bridge with multi-account round-robin, per-model quota
cooldowns, and CLI-fingerprint emulation.

## Install / manage (setup.sh)

```bash
bash scripts/setup.sh --cliproxy     # install (also in the interactive menu)
bash scripts/setup.sh --clean cliproxy   # remove binary+symlink, KEEP config/logins
bash scripts/setup.sh --doctor       # verifies it (banner probe, not --version)
```

Layout: binary + config in **`$CLIPROXY_HOME`** — `$XDG_CONFIG_HOME/cli-proxy`
(the XDG rule every other tool follows), with a legacy manual install at
`$REPL_HOME/cli-proxy` still honored when it already has a `config.yaml`) —
symlinked to `$XDG_BIN_HOME/cli-proxy-api` so the CLI is on PATH.
`CLIPROXY_HOME` is exported in the rc + `.replit [userenv.shared]`.

- **First install generates a safe `config.yaml`** (openssl-random client key +
  management secret, `host: 127.0.0.1`, chmod 600). It does NOT copy
  `config.example.yaml` verbatim — that example binds ALL interfaces and ships
  placeholder keys that look real. The example is kept alongside for reference.
- **A pre-existing `config.yaml` is never overwritten** — keys and OAuth logins
  live there. This matches a prior manual install at `$REPL_HOME/cli-proxy`.
- `--clean cliproxy` deliberately preserves the app dir (config + auth files).

## Run

```bash
cli-proxy-api --config "$CLIPROXY_HOME/config.yaml"   # API on http://127.0.0.1:8317
cli-proxy-api -codex-login -no-browser                # or -claude-login /
                                                      # -antigravity-login /
                                                      # -kimi-login / -xai-login
```

`-no-browser` is what makes OAuth work on this box: it prints an auth URL to
open on any device with the account, then you paste the code back. Credentials
land in `oauth.auth-dir` (`~/.cli-proxy-api`) — that dir is NOT persistent
($HOME is wiped), so copy it under `$REPL_HOME` or re-login after a recreate.

Client endpoints need the `access.api-keys` key: `Authorization: Bearer <key>`
(`/v1/chat/completions`), or `x-api-key` for `/v1/messages`. The management
API/panel (`/v0/management/*`, secret-key) is on the same port.

## Upstream options

1. **OAuth subscriptions** — the point of the tool; log in per account, the pool
   round-robins and cools down per quota window.
2. **API-key upstreams** — `api-keys.openai-compatibility` points at any
   OpenAI-compatible endpoint (e.g. the host's OmniRoute gateway), with
   `models:` alias mapping. Verified chain: CPA → OmniRoute → upstream.

## Pitfalls (all hit for real)

- **No `--version` flag.** An unknown flag prints the version banner and exits
  **2** — a naive `check_tool` reports "FAILED to run". Probe the banner text.
- **SIGPIPE vs pipefail:** resolving the release tag with
  `curl … | grep -m1 '"tag_name"'` dies rc=23 (grep closes the pipe, pipefail
  propagates curl's SIGPIPE) and the install aborts silently after the step
  header. Use `awk 'END{print t}'` (reads to EOF).
- Release asset names are **version-embedded** (`CLIProxyAPI_<ver>_linux_amd64.tar.gz`),
  so the tag must be resolved first (`/releases/latest` redirect works as the
  fallback when the GitHub API rate-limits).
- The binary's startup model-refresh reaches out to GitHub (raw.githubusercontent);
  an offline box still serves, just with a stale catalog.
- `config.yaml` has **no hot reload** — restart after edits.