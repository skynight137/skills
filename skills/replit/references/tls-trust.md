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

## Why the platform shell breaks Node

The platform exports `SYSTEM_CERTIFICATE_PATH` (the Nix bundle, from `pkgs.cacert` in
`replit.nix`). The setup
generator copies it into `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, `SSL_CERT_DIR`, and
`NODE_EXTRA_CA_CERTS`:

- `setup/rc.sh` — the `if [ -n "\${SYSTEM_CERTIFICATE_PATH:-}" ]` block (exports).
- `setup/common.sh` — the `_TLS_ENV_VARS` block (same four names).

So a fresh shell inherits a Node CA path that lacks the proxy root. The generator
fix sets `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, and `REQUESTS_CA_BUNDLE` to
`/etc/ssl/certs/ca-certificates.crt` when that file is readable, and falls back to
the Nix bundle when it is not. `NIX_SSL_CERT_FILE` and `SSL_CERT_DIR` stay on the Nix
path. Check `setup/rc.sh` on your branch before assuming this is present. Nix-built
tools that read `SSL_CERT_FILE` are not verified against the system bundle. Verify the
generator on main before assuming this is present: `git show origin/main:skills/replit/scripts/setup/rc.sh | grep -n _tls_sys_ca`.

Node is the usual failure in the platform shell. The Nix bundle stays in
`NODE_EXTRA_CA_CERTS` and makes `fetch` fail with `UNABLE_TO_VERIFY_LEAF_SIGNATURE`.
Override it on the command line for a one-off test:
`NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt node -e "fetch('<url>')..."`.

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
