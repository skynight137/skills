# Worked example: a fresh Muse VM joins the fleet

The exact sequence that built `muse-test` (2026-11-02) and re-joins
`muse-hop` after every redeploy. Follow it literally; every step's
expected output is shown. Two roles exist: a **leaf** (most boxes —
no reverse tunnel) and the **hop** (one per fleet side — holds the
reverse forward). This example is a leaf joining via muse-hop; the
hop differences are marked.

## 0. Get the skill

```sh
cd ~/workspace && git clone https://github.com/skynight137/skills ~/skynight137/skills
# bundle-only alternative: npx -y skills add skynight137/skills -s muse
SETUP=~/skynight137/skills/scripts/setup.sh   # payload tree in the clone; path varies by install route
```

## 1. Fill the vars (the only hands-on part)

`setup.sh` writes a template to `~/.ssh/.env` (mode 600) on
first run and stops. Fill it:

```ini
TAILSCALE_AUTH_KEY=tskey-auth-…        # reusable, tag:muse, ephemeral is fine
TAILSCALE_NODE_NAME=muse-test          # the node's tailnet name
RS_SSH_USER=runner                     # service user (default is root — pin runner)
# RS_SSH_DIR is recorded by setup — the stack tree's home (~/.ssh on a
# fresh box; a box with an existing ~/workspace/.ssh tree keeps that path)
RS_AUTHORIZED_KEYS=ssh-ed25519 AAAA… muse-hop   # the HOP's pubkey (leaves trust only the hop)
# hop boxes only:
# RS_REVERSE_PEER=100.106.114.30       # the peer hop's tailnet IP
# RS_REVERSE_PORT=16801                # or "auto" to claim the first free 168xx
```

Secrets never live anywhere else. Never paste a key into chat or a
commit; the file is the single source.

## 2. Join

```sh
bash $SETUP --user runner --tailscale --join
```

What you should see, in order:

- `== stack service user: runner (service home: …/.ssh/home) ==`
  (root instead prints a WARNING that sessions can read `.env` —
  expected only when root was chosen on purpose.)
- tailscale phase: binaries are skipped if already installed.
- join phase: `sshd already running` on re-runs, or a fresh start;
  then the node status table with this box's 100.x IP.
- A leaf prints: `leaf mode (RS_REVERSE_PEER unset): reverse loops
  generated but NOT launched …` — a hop prints `hop mode
  (RS_REVERSE_PEER set): node-carried reverse loop launched on port
  16801; …`.
- The handoff block prints the box's **client pubkey**. Send it to the
  hop's operator; it gets registered ONLY in the hop's
  `join-tailnet/authorized_keys`, and only if this box must initiate
  ssh to the hop.

Re-running the same command is the restore path: phases are implied
only when their outputs are missing, key seeding is append-if-absent
(existing `authorized_keys` entries are never removed), and each
component is started only if down.

## 3. Verify (don't trust the join output alone)

```sh
bash $SETUP --verify
# from the hop, the real end-to-end test:
ssh <new-box> 'echo $MUSE_HOME; pwd'        # expect /home/hatch/workspace + /home/hatch/.ssh/home
ssh -tt <new-box> 'pwd'                     # interactive: same service home — no landing cd
```

Logs for everything live in `~/workspace/logs/`
(`sshd.log`, `tailscaled.log`, `reverse-node.log`).

## 4. After a redeploy

Processes and `/etc` users are wiped; files survive. Either re-run
step 2 by hand, or let the self-heal backstop (every 6 h) do it (it probes first,
joins only on failure). Expect ~0 approval prompts: the tailnet
`derpMap` keeps 2 DERP regions (blr + lax) and the node start pins an
already-approved control-plane IP (see `derp-map.md` in the muse-hop
workspace repo).
