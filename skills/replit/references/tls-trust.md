# TLS trust on Replit (per-client CA variables)

Use this when an HTTPS call to a `*.replit.dev` URL (the Replit proxy) fails with
`CERTIFICATE_VERIFY_FAILED`, `unable to verify the first certificate`, or
curl error 60. Verification stays on in every fix below.

## Trust stores on this box

| Store | Path | Trusts the Replit proxy root? |
|---|---|---|
| System bundle | `/etc/ssl/certs/ca-certificates.crt` (~123 certs) | **yes** — curl reads it |
| Nix bundle | `$SYSTEM_CERTIFICATE_PATH` (nss-cacert, ~143 certs) | no |
| certifi | `certifi.where()` | no |

Python's default context has `cafile=None` and `capath=/etc/ssl/certs`, which holds
no hashed certs, so it loads nothing. That is why the same URL works in curl and
fails in Python.

## Per-client variables (verified, verification on, same URL)

| Client | Variable | Set to | Result |
|---|---|---|---|
| Node `fetch` / MCP adapter | `NODE_EXTRA_CA_CERTS` | system bundle | 200 |
| Node `fetch` | `NODE_OPTIONS=--use-system-ca` only | — | fails (`NODE_EXTRA_CA_CERTS` overrides it) |
| Python `urllib`, `httpx` | `SSL_CERT_FILE` | system bundle | 200 |
| Python `requests` | `REQUESTS_CA_BUNDLE` | system bundle | 200 |
| Python (any) | `SSL_CERT_FILE` | Nix bundle | fails |
| git | `GIT_SSL_CAINFO` | system bundle | ok (`ls-remote`) |
| uv | `SSL_CERT_FILE` | system bundle | ok |

`ssl.create_default_context(cafile="/etc/ssl/certs/ca-certificates.crt")` and
`context=` on each `urlopen` is the in-code equivalent for Python.

## Why the Nix bundle is the wrong CA store

The platform exports `SYSTEM_CERTIFICATE_PATH` (the Nix bundle, from `pkgs.cacert`
in `replit.nix`) and already sets `NIX_SSL_CERT_FILE` to it. Copying that path into
the variables curl/node/python actually read (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`,
`REQUESTS_CA_BUNDLE`) does not "pin a CA store" — it **replaces** the platform store
with one that has no Replit roots. Measured on this box: the Nix bundle has 319
subjects and **0** Replit-named ones; `/etc/ssl/certs/ca-certificates.crt` has 287 and
**2** — `Replit internal proxy Root CA - <uuid>` and `Replit Localhost Development CA`.
Proxied HTTPS (`*.replit.dev`, connectors) is what breaks, while the public registry
still answers 200 — a partial failure that reads like a random outage.

It is also a pinned `/nix/store` path: after a rebuild or GC the variable points at a
missing file, and a missing `SSL_CERT_FILE` fails every TLS client hard (Node throws
`UNABLE_TO_VERIFY_LEAF_SIGNATURE` on everything).

Current generator (`setup/rc.sh`, `setup/common.sh`): guarded on
`[ -r /etc/ssl/certs/ca-certificates.crt ]` and exports the system bundle for
`SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS` and `REQUESTS_CA_BUNDLE`.
`NIX_SSL_CERT_FILE` is not set: nix resolves its own cache without it
(`nix flake metadata nixpkgs` verified against Replit's mirror) and nothing else reads
it. Confirm the state on your branch before assuming:
`git show origin/main:skills/replit/scripts/setup/rc.sh | grep -n 'etc/ssl/certs/ca-certificates.crt'`.

Every one of these variables can be unset without breaking the registry — curl 200,
`node fetch` 200, nix resolution fine. They exist so Node, which keeps its own bundled
roots and ignores the platform store, also trusts the Replit roots. A one-off override
for a single command: `NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt node -e
"fetch('<url>')..."`.

## Procedure

1. Run the verified check first: `curl -sS -m 15 https://<domain>:<port>/health`
   (no `-k`). Success means the path is fine; continue with the client.
2. Error 60 with `curl -sk` returning 200 means the server is up and this client's
   store lacks the proxy root. Pick the variable from the table for that client.
3. Re-run the client with verification on. Do not add `-k`, `verify=False`,
   `CERT_NONE`, or `PYTHONHTTPSVERIFY` (not a Python setting).
4. Read which bundle each client loads before choosing a variable. For curl, run
   `curl -sv <url> 2>&1 | grep CAfile`. For Python, run
   `python3 -c 'import ssl; print(ssl.get_default_verify_paths())'`. If curl's
   bundle holds the proxy root and the client's does not, point that client's
   variable at curl's bundle.
5. When testing a client under `env -i`, pass the interpreter by full path
   (`$(command -v python3)`). A bare `python3` is not on the reduced PATH and fails
   with `No such file`, which looks like a result but is not one.

## certifi

certifi fixes servers whose chain ends at a public CA (for example a MongoDB Atlas
host). It does not fix the Replit proxy, because its bundle lacks that root. Check
which case you have before choosing it.
