# Muse VM — platform policy files & the runtime cell

Surveyed 2026-11-04: a read-only sweep of the guest filesystem (filename
sweep for *polic*, *scope*, *blocklist*, *gatekeeper*, *allowlist* across
`/opt/hatch`, `/opt/muse`, `/etc`, `~/config` and the ssh store, plus
per-file reads) found **122 policy-bearing entries in 8 kinds**. The
operational lesson cuts both ways: some policy assumed to be platform-owned
DOES exist inside the guest at unexpected paths, and some policy that looks
like it should be a local file is **host-side only** — no file in the VM
holds it, and hunting or editing local files for it is wasted work.

Editability rule of thumb (see platform.md): everything under `/opt/hatch`
is a read-only squashfs, `/etc` is an overlay wiped on every redeploy, and
only `~` persists. "Exists in the guest" therefore never means "editable
with lasting effect".

## The runtime cell (`/opt/hatch/runtime-cell/`)

The guest is a systemd-nspawn machine (`htch-runtime`) rendered and
installed by the platform's **spawnd**. This directory is where the
platform's renders live — it is the source of several files that appear
inside the guest as un-editable system files.

- `guest.env` — spawnd-rendered plain `KEY=VALUE` (deliberately NOT a
  shell script; nothing the cell can influence). Root-owned, bind-mounted
  read-only into the cell, and read **host-side** by the privsep side to
  build environments for tool invocations. Keys: `HOME`, `TMPDIR/TMP/TEMP`,
  `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME` (no
  `XDG_DATA_HOME`), `JARVIS_HOME`, `JARVIS_BIN_DIR`, `JARVIS_AUTHD_SOCK`,
  `JARVIS_STEFI_PROXY_SOCK`, `HTTP(S)_PROXY`/`ALL_PROXY`/`NO_PROXY` (both
  cases), the CA-bundle family (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`,
  `CURL_CA_BUNDLE`, `AWS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`,
  `GIT_SSL_CAINFO`), `WGETRC`, `NODE_USE_ENV_PROXY`, `PATH`. This file is
  where the sanctioned egress proxy, the CA bundle, and the platform XDG
  defaults are assigned — they reach platform daemons and tool
  subprocesses via this file, **not** interactive or SSH shells.
- `guest-runtime-env.sh` — the shell-side companion for in-cell
  entrypoints: computes the same proxy host (`hatch-egress-proxy`) and
  `no_proxy` list, loads `/etc/hatch/env` + `/etc/hatch/env.override`,
  and preserves a host-side `JARVIS_SANDBOX_API_SOCK` override. Do not
  confuse it with `guest.env`: the trusted path deliberately does not
  use this cell-side script.
- `control-execd.sh` — launcher for the exec daemon behind agent shell
  exec. It sources the host-rendered, root-owned `guest.env` (via
  `runtime-cell-entry.sh` helpers) — NOT the cell-writable
  `guest-runtime-env.sh` — so tool subprocesses inherit Sentinel-routed
  proxy settings and the TLS CA bundle from a trusted source. Combined
  with platform.md's environment model (agent exec shells run
  `bash --norc --noprofile` with a daemon-composed env and no rc hook),
  this is the whole runtime-shell picture: there is no file inside the
  guest you can edit to change what env the agent's shells spawn with.
- `/etc/hatch/env` — the live host-composed environment inside the guest
  (systemd `EnvironmentFile` source for cell services). Key families are
  `JARVIS_*` wiring only: sockets for authd, inference, the sandbox API,
  Sentinel's HTTP API, the STeFi proxy, telemetry, and the
  egress-approval pair (`JARVIS_DAEMON_EGRESS_APPROVAL_SOCK`,
  `JARVIS_EGRESS_APPROVAL_ADMIN_SOCK`), plus channel/pin, FQDN,
  hatchling id, tier, and compute/data regions. Root-owned overlay file —
  wiped on redeploy. Its override slot `/etc/hatch/env.override` exists
  and is currently effectively empty (1 byte).
- `bin-scopes.conf`, `connector-scopes.conf`,
  `workflow-skill-scopes.conf` — release-channel → visibility maps,
  generated from `hatch-skills/catalog.toml`. `launch-daemon.sh` exposes
  only the active channel's (`JARVIS_CD_CHANNEL`) binaries at
  `/opt/hatch/bin`; an unset or unknown channel reveals **none**.
  Visibility only — a scope entry grants no permission by itself.
- `etc/hosts`, `etc/resolv.conf` — spawnd's static renders, declared
  authoritative and complete (not merged with any inherited rootfs file),
  bind-mounted read-only into the cell. These renders are WHY those
  `/etc` files cannot be edited from inside the VM (see egress.md for
  what the resolver does with them).
- `etc/wgetrc` — version-coupled wget config selected via `WGETRC`; pins
  wget's CA to `/run/hatch/egress-tls/ca-bundle.pem`.
- `build-cell-trust-store.sh` — host-side producer (never enters the
  cell): publishes the Sentinel egress CA into the cell anchors
  (`/run/hatch/cell-anchors`) and the NSS db (`/etc/pki/nssdb`). This is
  the mechanism that puts the platform egress CA in the cell trust
  store.
- `require-modules.sh` — kernel hardening producer: writes the
  `/etc/modprobe.d` blacklist as `install <mod> /bin/false`, which
  blocks autoload AND explicit modprobe for attack-surface modules
  (the AF_ALG userspace crypto interfaces, e.g. `algif_aead`,
  `algif_hash`).
- `ensure-rootfs.sh` / `post-start.sh` own the cell's network constants
  (gateway `198.19.0.1`, cell `198.19.0.2/30`, proxy host
  `hatch-egress-proxy`) — the same constants egress.md describes from
  the wire side.

## Policy that IS shipped in the guest

- **MASE content/domain data** — `/opt/hatch/assets/blocklist/`. A
  web-search / content-safety dataset (manifest provenance: fetched
  2026-08-17 from bucket `genai_web_search`, prefix `flat`, with
  per-artifact sha256). Contents: FST domain sets — all **2,666,077**
  entries (dominated by adult and mass-UGC subdomains), reduced
  **2,633,926**, contract **295** (the allow-side: contracted
  news/media domains); a 59.9 MB hashed-URL fingerprint file (magic
  MUFP, **7,497,435** entries) whose 302 MB plaintext source FST is
  NOT shipped, so the hashed layer cannot be enumerated from inside;
  and `mase_blocklist_regex.json`, 74 bytes holding exactly ONE
  pattern (a celebrity typo-squat). The consumer is the agent
  binary's domain-blocking crate screening **the agent's own
  tool-call URLs**. It is NOT a tunnel or egress blocklist —
  `api.trycloudflare.com` is not in it, and no edit here changes
  what the gateway blocks.
- **Connector descriptors** — `/opt/hatch/connectors/*/connector.yaml`
  (75). Every one carries an `availability:` block with
  `confidential_vm: true/false` (whether the connector may run on a
  confidential VM). Only **5 of 75** additionally carry a Gatekeeper
  flag (`gk:`) that feature-gates the connector per account:
  expedia (`hatch_connector_exp_enable`), imap_email
  (`hatch_generic_imap_connector`), instacart
  (`hatch_instacart_enabled`), muse_mail (`muse_mail`), onepassword
  (`hatch_1password_integration`). Most also declare an auth mode
  under `auth.connect:` (`managed_consent`, `cli`, `companion`,
  `api_key`, `professional_consent`, `shop-wallet-cli`). A connector
  that is invisible or gated is usually explained here + the
  scope confs above, not by anything in `~/config/skills.yaml` (the
  local service registry — see platform.md).
- **The platform prompt library** — `/opt/hatch/prompts/` (177 files
  per its manifest): 131 hatch-self-improvement, 24
  hatch-context-workers, 10 hatch-agent, 5 hatch-goals, 2
  hatch-alignment, 2 hatch-server, 1 hatch-config, 1
  hatch-objective-execution. Behavior policy for the platform's own
  background workers — not the guest agent's instruction files
  (`~/SOUL.md`, `~/AGENTS.md` are the user-side counterparts, and
  they persist and are editable).
- **Chromium managed policy** — DOES exist as guest files,
  identically at `/etc/opt/chrome/policies/managed/policy.json`,
  `/etc/opt/chrome_for_testing/policies/managed/policy.json`, and
  `/etc/chromium/policies/managed/policy.json`:
  `ComponentUpdatesEnabled: false`, `MetricsReportingEnabled: false`,
  `BrowserSignin: 0`, and a 6-entry `URLBlocklist` of Google
  update/telemetry hosts (`gvt1.com`, `update.googleapis.com`,
  `clients2.google.com`, `optimizationguide-pa.googleapis.com`,
  `content-autofill.googleapis.com`, `android.clients.google.com`) —
  browser hygiene, no tunnel domains. They are renders (the
  generating heredoc lives embedded in the spawnd binary); `/etc` is
  overlay, so local edits die on the next redeploy.
- **Reasoning-effort policy** — `~/config/home.yaml` sets
  `llm.reasoning` effort `xhigh` for the root agent, `high` for
  subagents. (The ladder, verified from the platform binary's
  `LlmReasoningEffort` enum: `minimal < low < medium < xhigh < max`;
  `xhigh` accepts the aliases extra-high / x-high / x_high. There is
  no "ultra".)

## Policy that is NOT in the guest (host-side only)

Researched 2026-11-04 — known to exist, with no guest file holding it.
Do not hunt for these on disk and do not expect a local edit to move
them:

- **The enforced tunnel/domain blocklist** — the one returning
  `403 "Your request was blocked."` (proven for
  `POST api.trycloudflare.com/tunnel` on every egress surface).
  Enforced by the host-side gateway fetch layer (Sentinel). The
  block page's text occurs nowhere in the guest image, and a
  delimiter-aware scan of every binary in `/opt/hatch/bin` found
  zero tunnel-domain entries. (A raw substring hit in a packed
  binary was a false positive — only delimiter-aware checks count.)
  The full list cannot be enumerated from inside; new entries are
  learned only by colliding with them.
- **`cvm-egress-policy.json`** — spawnd's templates pass this file to
  the STeFi proxy (`--cvm-egress-policy /opt/hatch/etc/stefi-proxy/…`),
  but that path does not exist in the guest (there is no
  `/opt/hatch/etc/` at all). The guest ships only the reference; the
  policy lives host-side.
- **Browser domain verdicts ("Central Blackhole")** — the browser
  broker receives block verdicts as observations from a central
  service; no local verdict list exists in the guest.
- **The `network_rules` approval registry** — the per
  (binary path + destination IP + port) grants behind the egress
  permission prompts are stored platform-side, visible read-only
  via the web app's Settings → Permissions. Stale grants for
  long-deleted binary paths prove nothing on this disk holds them
  (see egress.md for how the tuples behave). Two refinements
  verified 2026-11-04 (evening): **(1) Cards are minted only
  through the agent tool channel** — the egress-approval path the
  agent's own tool calls use (the JARVIS_* approval socket pair in
  `/etc/hatch/env`). An unapproved direct dial from an arbitrary
  process that no tool call owns is NOT offered a card: the
  gateway silently kills the connection (observed: `curl
  --resolve` to a real IP from a throwaway local web shell →
  HTTP 000, curl exit 52, the pending-approvals list stayed empty
  and the approval history gained no entry). **(2) The input
  channel does not change the executing process's network
  surface** — the same dial submitted through a browser-driven
  web page died identically, and the platform browser service
  refused to open a `127.0.0.1` page at all. The browser's
  allow-all permission covers only the browser service's own
  fetches; a web terminal's commands still run as guest
  processes under the same tuples. Do not propose browser/UI
  indirection as an approval bypass.
- **The documented "Advanced network settings" card** — product
  documentation found by the user (2026-11-04) describes a
  settings card, collapsed by default, holding three switches:
  **Transparent proxy** (on: the agent can resolve DNS and
  connect directly; off: all traffic must flow through the
  explicit HTTP proxy), **TLS interception** (on: all TLS
  connections are always intercepted for inspection; off: only
  when required by policy), and **SNI mismatch rejection** (on:
  connections are rejected when the TLS server name does not
  match the destination). The quoted text occurs NOWHERE in the
  guest — zero hits across the filesystem and the hatch binary
  strings — and the card does not appear in the user's settings
  menu: documented, but not exposed on this account/surface.
  The switches map onto this file's surfaces: Transparent proxy
  governs the direct-dial surface that generates the per-tuple
  cards (turning it off would force everything through the
  explicit proxy — and would break clients like the userspace
  tailscaled that cannot use a CONNECT proxy), TLS interception
  is the policy behind the Sentinel CA shipped in the guest
  trust store, and SNI mismatch rejection would govern the
  resolve-then-dial / fake-IP intercept surface.
- **The MASE source FST** (`mase_all_urls_normalized.fst`, 302 MB) —
  referenced by the manifest, deliberately not shipped (above).
