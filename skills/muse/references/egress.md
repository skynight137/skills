# Muse VM — egress, DNS, and permissions

Verified 2026-11-02 with live probes (`dig`, `curl --resolve`, `tailscale
netcheck`, raw-socket tests). The single fact everything follows from:
**all traffic leaves through a gateway at `198.19.0.1`, and the gateway —
not the VM — decides what a name means and which flows exist.**

## DNS is a fake-IP service

- `/etc/resolv.conf` is a static render (read-only bind mount) pointing at
  `198.19.0.1` — the gateway itself (also the egress proxy host).
- EVERY query returns NOERROR with a stable per-name placeholder A record
  from a `198.18.x` pool (TTL 15), assigned in query order — real domains,
  random strings, nonexistent TLDs alike. There is no NXDOMAIN and no
  allow/deny list inside the VM; the name↔fake-IP mapping lives
  gateway-side and is honored only for proxy-style (CONNECT/SNI) traffic.
- Practical fallout: never resolve-then-dial with the stock resolver, and
  never conclude a host is up/down from a stock DNS answer.

## The two ways out (both TCP)

1. **HTTP CONNECT proxy** at `198.19.0.1:3128`, pre-set in the shell env
   (`HTTP(S)_PROXY` etc.). Proxy-aware programs only — there is no
   OS-level forcing. Carries TCP per connection; **no UDP**.
2. **Direct dials to real IPs**, gated by the platform's permission
   categories (below). Real IPs come from the one working external
   resolver: `dig @8.8.8.8`. (1.1.1.1 and 9.9.9.9 time out; only 8.8.8.8
   answers.) Direct dials are slow to establish (~5–9s) but genuine.

## Apps that resolve and dial by themselves

Some programs do neither of the two ways out cleanly: they resolve names
through the system resolver and then dial the result directly — typical
of statically linked (musl) binaries and tools with their own network
stack. They hit two independent walls:

1. **Resolution.** Strict stub resolvers (musl's is the observed case)
   can fail the gateway lookup entirely (`EAI_AGAIN` / "failed to lookup
   address information"), and even when a placeholder answer comes back
   it is useless for a direct dial. Neither `/etc/resolv.conf` nor
   `/etc/hosts` can be edited — both are read-only bind mounts, root
   included.
2. **Dialing.** A direct TCP dial to the real IP is reset
   (`connection reset by peer`, os error 104) or black-holed unless the
   (binary path + IP + port) tuple is approved.

Workaround pattern — per-process, needs root, persists nothing:

- Get the real IP from the carve-out: `dig @8.8.8.8 <name>`.
- If the program must resolve a name to an address you choose, run it
  in a **mount namespace** with a bind-mounted `/etc/hosts`:
  `unshare --mount bash -c 'mount --bind <doctored-hosts> /etc/hosts && exec <app>'`.
- If it must reach a public TLS service, have it dial a **local
  listener** instead (hosts override pointing the service's real name
  at `127.0.0.1`, so SNI and certificate validation still use the real
  name) and tunnel that listener out through CONNECT: a ~30-line stdlib
  TCP shim that issues `CONNECT host:port` to `198.19.0.1:3128` and
  then pipes raw bytes keeps TLS end-to-end.
- Expect an egress approval prompt for the program's binary path the
  first time it dials; approval keys include the path, so keep binary
  paths stable.

Verified 2026-11-04: a musl-static binary that failed first on DNS
(EAI_AGAIN), then on the direct dial (reset), worked end-to-end with
the namespace + CONNECT-shim combination. Tailnet destinations do not
need any of this — use tailscaled's SOCKS5 (127.0.0.1:1056) instead.

## Permission categories (web app → Settings → Permissions)

These are platform egress toggles, set per category (Deny/Ask). They are
**not** in the mobile app's connector list.

| Toggle | What it actually unlocks (observed) |
|---|---|
| External DNS lookups | `dig @8.8.8.8` returns real records |
| Other TCP connections (Ask) | Direct TCP dials to real IPs succeed (e.g. `curl --resolve` gets the genuine response); also the first-launch path for daemons that dial directly |
| Other UDP traffic | **Nothing observable.** netcheck still reports UDP false, DERP probes go unanswered, and raw UDP `sendto` from a normal process fails instantly with EPERM — even DNS/53 from python, while `dig` in the same minute works. The toggle is a policy label without plumbing; UDP exists only as the resolver-tool carve-out. |

Approvals attach per foreground agent run: a daemon first launched from a
background job sees resets where the same launch in a foreground turn —
after the user approves — succeeds. Treat "works interactively, fails from
a job" as an approval-context problem before treating it as a config bug.

Two independent gates exist and are easy to confuse: the **Tailscale
connector's tunnel proxy** has its own per-address approval (first request
to an exact tailnet IP), unaffected by the Direct-network toggles above.

## Failure signatures worth recognizing

- **Go programs reset, curl works**: the gateway TLS-inspects some flows;
  Go clients (tailscaled's proxied control fetch, sshx) got
  `connection reset` / handshake resets where curl/OpenSSL passed. For
  tailscaled the fix was scrubbing `*_PROXY` so it dials directly.
- **`400 Bad Request` from a well-known endpoint**: you reached the
  gateway intercept on a fake IP, not the service.
- **Timeout, then `403`**: the cloudflared quick-tunnel provisioning path
  (`api.trycloudflare.com`) behaves exactly like this — quick tunnels do
  not work from here. Named tunnels need the operator's Cloudflare account
  token, and the edge connection wants UDP/7844 (dead) before its TCP
  fallback, so expectations stay low until proven otherwise.
- **Tools whose remote transport is itself a quick tunnel** (e.g. 9remote)
  inherit the same wall: they run in local mode only, and no pairing key
  is ever issued.
