# Large files and disk space

Disk space on a Replit workspace is split between a **small 4 GB tier** and the
**256 GB workspace volume**. Big downloads, model weights, tarballs, video and
archives belong on the workspace volume only. "quota exceeded" / "No space left
on device" while downloading is almost never a real quota — it is a 4 GB mount.

## Measured layout (verify with `df -h` on the box, mounts move)

| Mount | Size | Kind | Safe for multi-GB? |
|---|---|---|---|
| `/home/runner/workspace` (`$REPL_HOME`, `$XDG_DATA_HOME` under it) | 256 GB (≈12% used) | `vdc` volume | yes — the only tier that is |
| `/`, `/home/runner` (`$HOME`, overlay upper) | 4 GB | overlay | no |
| `/tmp` | 4 GB | tmpfs (RAM) | no |
| `/mnt/scratch` | 4 GB | tmpfs (RAM) | no |
| `/mnt/<uuid>` | 256 GB | same `vdc` device as workspace | yes (but not persistent identity) |
| `/var/lib/docker` | 256 GB | same `vdc`, root-owned, **not writable by `runner`** | docker daemon isn't running anyway |

`$HOME` and `/tmp` are the defaults every tool reaches for first — `curl -O`,
`pip download`, `git clone`, browser downloads, `mktemp`. That default is the
bug.

## Decision table

| Artifact | Target |
|---|---|
| < ~2 GB, disposable | `/tmp` is fine (RAM-backed, fast, self-clears) |
| ≥ ~2 GB, disposable | `$XDG_DATA_HOME/tmp/<slug>/` |
| ≥ ~2 GB, keep | `$XDG_DATA_HOME/<tool-or-slug>/` |
| tool cache / runtime (engines, model dirs) | `$XDG_DATA_HOME/<tool>/` |
| inside a project repo | `$REPL_HOME/<repo>/.cache/` and gitignore it |

`$XDG_DATA_HOME` is preset to `/home/runner/workspace/.local/share` (see
`platform.md` §1). Use the variable, not the literal path — the same script then
works off-Replit. Check headroom before starting, not after:

```bash
df -h "$XDG_DATA_HOME"   # Avail column must exceed the file size several times over
```

Note `~/.local/share` and `$XDG_DATA_HOME` are **different things** on this box:
the `~` form resolves under the 4 GB `$HOME` overlay. `~/.local/share/foo` =
fill after ~4 GB; `$XDG_DATA_HOME/foo` = 256 GB tier.

## Resolving a proxied download URL first

Google-Drive-index Workers (OneList / GDrive-index forks: `/0:/`, `/0:findpath`)
serve files through a redirect, and the share text people paste often glues a
status note onto the file id (`...<id>quota exceeded`) — with the note attached
the lookup answers `{"error":"File not found"}` **and** a 302 to `/0:/`, which
looks like the file vanished. A Drive file id is 33 characters: split it at the
first non-id character and re-run the lookup.

```bash
BASE='https://<worker-host>'; ID='<33-char-id>'
curl -sSi "$BASE/0:findpath?id=$ID" | grep -i '^location'   # 302 Location = real path
```

`/<drive>:/` lists the root as HTML — useful when the id itself is unusable.

## Sizing and downloading

```bash
curl -sSI -A 'Mozilla/5.0' "$URL" | grep -i content-length   # size in bytes
mkdir -p "$XDG_DATA_HOME/<slug>" && cd "$XDG_DATA_HOME/<slug>"
curl -sS -r 0-99 -A 'Mozilla/5.0' "$URL" -o probe.bin \
  -w 'code=%{http_code} got=%{size_download}\n'              # want 206, not 200
rm -f probe.bin
curl -L -C - --retry 10 --retry-delay 5 --retry-all-errors -A 'Mozilla/5.0' \
  -o '<name>' "$URL" 2>curl.err                               # run backgrounded
```

- A staggering rate (gigabytes in seconds) means the file is small: re-read the
  size instead of believing the counter looks too good.
- `-C -` resumes after a dropped connection; run the transfer in the background
  and poll `ls -l` + `df -h` rather than blocking a foreground call for an hour.
- Progress goes to `curl.err` (`-s` suppresses the bar on stdout):
  `tail -c 400 curl.err`. Expected total is the byte count from the HEAD.
- `curl -I` without `-A` still works on Workers; Python `urllib` gets **403**
  without a `User-Agent` header, so shell out to curl for probes.
- Verify the finished size equals the HEAD byte count before using the archive.
  `.rar`/`.zip` you cannot `ls` are not verification.

## Pitfalls

- **Don't write to `/mnt/scratch` because "scratch" sounds disposable.**
  It is a 4 GB tmpfs; a 20 GB file dies partway and takes RAM with it.
- **`du`/`ls` on `/mnt/scratch` can answer "Permission denied"** (it is owned by
  uid 11000 with mode 755) while `mkdir`/`touch` as `runner` still succeed.
  Writability is not the same as readability of every entry — do not read that
  error as "unwritable, pick elsewhere".
- **`/var/lib/docker` looks like a 256 GB free target and is not.** Root-owned,
  and the daemon is down, so nothing prunes it.
- **Numbers in terminal output can be redacted to `[PHONE_REDACTED]`** — a
  `content-length: 59172149692` comes back masked. Print the value split
  (`' '.join(reversed([s[i-3:i] ...]))`) or `od -c` the header dump.
- **This profile's terminal result mangles stdout** (spaces collapse, newlines
  vanish). Redirect to a file and `read_file` it for anything you must parse.
- **`df -h` free space is not a quota promise.** Fill is per-mount; a `dd` or
  build can exhaust the 256 GB volume too. Keep headroom for the tool that
  consumes the file.
