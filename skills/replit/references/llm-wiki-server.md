# llm-wiki server — app desktop headless + MCP over HTTP

Menjalankan `nashsu/llm_wiki` (knowledge base markdown untuk agen) di server tanpa
desktop, lalu mempublikasikannya ke banyak agen lewat **MCP over HTTP** + REST.
Berlaku di Replit maupun VPS Debian/Ubuntu biasa.

## Dua bagian runtime (jangan dicampur)

| Bagian | Isi | Butuh |
|---|---|---|
| **App** (Tauri) | `squashfs-root/usr/bin/llm-wiki`, API lokal `:19828`, clip server `:19827` | X display (nyata atau Xvfb + WM) |
| **Server** | `llmwiki-server.js` (Node, **stdlib saja**) → `/mcp` + proxy REST | Node ≥ 18 |

Server Node yang mempublikasikan; API app **tidak** diumbar langsung.

## File bundel — sekarang dikirim **di dalam skill ini** (`scripts/llm-wiki/`)

`install.sh` (unduh AppImage + ekstrak + bikin token) · `run-public.sh` (supervisor:
Xvfb → WM → app → server, auto-restart) · `run-ui.sh` (x11vnc + noVNC: UI desktop
dibuka dari browser) · `start-app.sh` (launcher app portabel) · `llmwiki-server.js`
(server MCP+REST) · `.env` (token, chmod 600) · `pixbuf/` (loader PNG opsional) ·
`.ldpath`/`.libdirs.pre` (dir lib khusus mesin, boleh kosong).

Terpasang dengan satu perintah:

```bash
bash setup.sh --llm-wiki        # bundle -> ${LLM_WIKI_HOME:-$XDG_DATA_HOME/llmwiki-app}, lalu install.sh
```

Modulnya (`scripts/setup/llm-wiki.sh`) **melaporkan** paket sistem yang kurang
(xvfb/fluxbox/shared-mime-info/x11vnc) alih-alih memasangnya sendiri — instalasi paket
sistem bukan urusan script user-level.

## Prasyarat (Replit = NixOS: pakai nix, bukan apt)

```bash
nix build nixpkgs#xvfb nixpkgs#fluxbox nixpkgs#shared-mime-info   # app-nya butuh ini
nix build nixpkgs#x11vnc nixpkgs#novnc                            # hanya kalau mau UI lewat browser
```

Masukkan nama paket yang sama ke `replit.nix` supaya bertahan setelah repl di-recreate.
Node ≥ 18 sudah ada di box ini (dipasang `setup.sh --node`); di host non-nix padanannya
`apt install xvfb fluxbox shared-mime-info x11vnc novnc`.

- **node ≥ 18** — satu-satunya runtime server. **Jangan** pakai node milik Hermes
  (`$HERMES_HOME/tools/node-*`): di luar jalur, butuh `libatomic.so.1`, dan Hermes
  membuang `LD_LIBRARY_PATH` dari child MCP.
- **window manager wajib** — tanpa WM window GTK dibuat tapi tidak pernah di-map
  (screenshot hitam, `xwininfo -root -tree` = `0 children`).
- **`shared-mime-info` wajib** — gdk-pixbuf 2.42 memilih loader lewat MIME sniffing;
  tanpa database MIME, semua gambar "unrecognized" dan GTK abort di `gtkiconhelper.c`.
- AppImage ini **tidak** menyertakan loader PNG; kalau GTK mati karena ikon, pakai
  `pixbuf/loaders.cache` (loader harus cocok ABI: header 2.42.8 untuk lib bundle 2.42.8).

### Xvfb/fluxbox otomatis (`_llm_wiki_provision_display`)

`setup.sh --llm-wiki` menyediakannya sendiri; tak perlu langkah manual di atas kalau
flag itu dipakai. Dua jebakan yang sudah ditangani dan **jangan** dihilangkan:

- `/nix/store` bisa tampak writable (mode 777) sementara `nix build --store /nix/store`
  hanya *mencetak* path tanpa menyalin apa pun (chroot store: hasilnya di
  `/nix/store/nix/store/<hash>`). Karena itu build **selalu** ke store per-user
  `~/.store` dan path hasil di-resolve ke `~/.store/nix/store/<hash>` sebelum diuji
  (nix tetap mencetak `/nix/store/<hash>` yang belum tentu ada di box). Launcher-nya
  butuh nama binari sebagai argumen pertama: `nixenv nix build …`.
- Biner store punya `PT_INTERP` + `RUNPATH` ke `/nix/store`, jadi store per-user tak
  terlihat loader. Wrapper `~/.local/bin/Xvfb` menjalankannya lewat `nixenv` (mount
  namespace: symlink store sistem + `~/.store`; `unshare -r`, tanpa root) dan menyisipkan
  `-xkbdir` — tanpa itu Xvfb mati `Failed to activate virtual core keyboard`.
- **Wrapper yang ada di PATH bukan bukti display hidup.** `command -v Xvfb && command -v
  fluxbox` lolos walau `~/.store` sudah di-GC atau `nixenv` hilang — wrapper basi menunjuk
  target yang tak ada dan provisioning dilewati, jadi app mati `Failed to initialize GTK`
  tanpa ada yang memperbaikinya. Gerbangnya `_llm_wiki_display_ok()`: `$XDG_BIN_HOME/nixenv`
  harus ada DAN setiap wrapper harus benar-benar meng-`exec` target yang `-x`; kalau tidak,
  run penuh `_llm_wiki_provision_display`.

## Jalankan

```bash
bash setup.sh --llm-wiki   # sekali per mesin: bundle + AppImage + token
bash run-public.sh         # supervisor, foreground (systemd / workflow / tmux)
bash run-ui.sh             # opsional: UI desktop lewat browser (noVNC :8000)
```

Di mesin lain (belum punya skill ini): clone repo-nya dulu, lalu flag yang sama.

```bash
git clone --depth 1 -b <branch> https://github.com/skynight137/skills.git ~/work/skills
cd ~/work/skills/skills/replit
bash scripts/setup.sh --llm-wiki --node --sshx -y
```

- **`run-public.sh` menyiapkan `LD_LIBRARY_PATH` sendiri.** Shell telanjang (ssh, cron,
  workflow, systemd) tidak mewarisi profil, jadi `node` mati `libatomic.so.1: cannot open
  shared object file` sebelum apa pun jalan. Loop prepend kandidat
  (`${REPL_HOME:-}/.local/lib`, `$HOME/workspace/.local/lib`, `$HOME/.local/lib`) lalu
  `export`; di bawah `set -u` bentuk sisipannya `${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH:-}}`
  (`case "$LD_LIBRARY_PATH:-"` justru `unbound variable`).
- **Token harus di-`export` ke proses anak, bukan cuma ditulis di `.env`.** Baris token di
  file tidak masuk environment server (`/proc/<pid>/environ` tetap kosong), sehingga gate
  read-only tampak "lulus" padahal auth RO tak pernah diuji. Backfill juga `.env` lama yang
  belum punya baris `LLM_WIKI_READONLY_TOKEN`, chmod tetap 600.
- **noVNC di `:3000`, bukan `6800`** — 6800 milik sshd remote-shell; dua service di satu
  port = yang kalah bind diam-diam, dan gejalanya muncul sebagai service yang lain mati.

## Endpoint

`PORT` = `${LLM_WIKI_PORT:-8080}`.

| Endpoint | Auth | Untuk |
|---|---|---|
| `http://127.0.0.1:${PORT}/mcp` | `Authorization: Bearer <token>` | agen di mesin yang sama lewat jalur publik |
| `http://127.0.0.1:8199/mcp` | tanpa token (bind loopback) | agen lokal yang tak mau bawa secret (ini yang dipakai profile Hermes) |
| `https://<host>:${PORT}/mcp` | header sama | agen di mesin lain, **kalau** port sudah dirutekan |
| `https://<host>:${PORT}/api/v1/...` | header sama | script/curl |
| `https://<host>:${PORT}/health` | tanpa auth | cek server + upstream |

Port publik default **80** (`LLM_WIKI_PORT=80` di `.env`), jadi URL klien tanpa sufiks.
8080 dipakai kalau 80 sudah dipegang hal lain. Kalau tabrakan,
server tidak bisa bind dan `/health` justru balas **302 +
`{"error":"unauthenticated",...,"login_url":"/login"}`**: itu dashboard Hermes, bukan
llm-wiki. Cek pemilik port dulu sebelum menuduh server rusak.

Di Replit, port yang baru ditambahkan ke `.replit [[ports]]` belum tentu langsung
dirutekan (butuh Repl restart) — selama itu, klien di mesin yang sama pakai loopback.

## Token (dua level)

| Env | Hak |
|---|---|
| `LLM_WIKI_API_TOKEN` | penuh (tulis, embed, rescan, chat) |
| `LLM_WIKI_READONLY_TOKEN` | read-only: REST GET + `search`/`graph`; tool MCP baca saja (tool tulis → `-32003`) |

Keduanya dibaca dari `.env`, dipakai dengan header yang sama, dan token read-only
boleh dibagikan ke agen tamu. Kalau `LLM_WIKI_READONLY_TOKEN` kosong → perilaku lama.

Instance publik **selalu** butuh token; `LLM_WIKI_TRUST_LOOPBACK=1` ditolak kalau bind
bukan loopback (biar tidak ada endpoint tanpa auth yang kebuka). Kedua token dibuat
**otomatis** oleh `install.sh` (`crypto.randomBytes(32).toString('hex')`), jadi tidak ada
yang perlu di-generate manual. Belum ada identitas per penulis: audit tidak membedakan
agen, dan pemisahan tulis hanya sekuat token read-only itu.

Selaras dengan itu, skill bawaan Hermes bernama **`llm-wiki`** (kategori research) tetap
**disabled** di setiap profile — sumber kebenaran deployment ini adalah entry MCP
`llm-wiki` + bundel di `tools/llmwiki-app/`, bukan skill bawaan itu. Jangan mengaktifkannya
kembali saat menambah profile baru, dan cek dengan `hermes -p <profile> skills list | grep llm-wiki`.

## Daftarkan klien

```bash
hermes -p <profile> mcp add llm-wiki --url http://127.0.0.1:8199/mcp
hermes -p <profile> config set mcp_servers.llm-wiki.headers.Authorization 'Bearer ${LLM_WIKI_API_TOKEN}'
```

`config set` menerima `${VAR}`; Hermes membacanya dari `.env` profile itu, jadi nama tokennya
tetap **`LLM_WIKI_API_TOKEN`** (alias `MCP_<NAMA>_API_KEY` cuma dipakai kalau memakai flag
`--auth header`). Klien non-Hermes: `{"mcpServers":{"llm-wiki":{"url":"https://$REPLIT_DEV_DOMAIN/mcp",
"headers":{"Authorization":"Bearer <token>"}}}}`. Tool yang muncul: 12
(`llm_wiki_status/projects/set_project/files/read_file/write_page/search/graph/
rescan_sources/embed_page/reviews/chat`).

Uji tulis/baca via curl (tanpa klien MCP, sudah diverifikasi di instalasi bersih):

```bash
T=$(sed -n 's/^LLM_WIKI_API_TOKEN=//p' /path/ke/app/.env)
# tulis — field-nya `content`, bukan `body`; tool-nya `llm_wiki_write_page`
curl -s -X POST localhost:8199/mcp -H "x-llm-wiki-token: $T" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"llm_wiki_write_page",
       "arguments":{"path":"wiki/queries/uji.md","title":"Uji","content":"# Uji\n"}}}'
# baca balik
curl -s -X POST localhost:8199/mcp -H "x-llm-wiki-token: $T" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"llm_wiki_read_file",
       "arguments":{"path":"wiki/queries/uji.md"}}}'
```

Port: MCP hanya di server (`8199` loopback, `${PORT}` publik) — **`19828` itu API app**,
`POST /mcp` ke situ dijawab `{"error":"Not found"}`. Token diterima sebagai
`x-llm-wiki-token` maupun `Authorization: Bearer`; balasan `400 missing field ... content`
artinya field-nya yang salah, bukan tool-nya. Bukti sehat: respons `tools/call` memuat
`"ok": true` dan `bytes`.

## Model project & kategori (pertanyaan yang sering muncul)

- App punya **satu “current project”** (disimpan di clip server, hanya di memori).
  `LLM_WIKI_PROJECT` menetapkan defaultnya; `llm_wiki_set_project` mengubahnya
  **global untuk instance itu** — jadi dua agen yang berbagi satu app menulis ke
  project yang sama kecuali mereka mengirim `project=<id>` eksplisit per panggilan.
- **Root wiki = `<dir app>/project`**, menempel di instalasi supaya app dan isinya
  terhapus sekaligus (`rm -rf <dir app>`). Ubah lewat `LLM_WIKI_PROJECT` di `.env`
  (default ditulis `install.sh`), atau per panggilan MCP dengan `project=<path absolut>`;
  `llm_wiki_projects` mendaftar id yang dikenal. Isi wiki selalu `<root>/wiki/**`, jadi
  saat menulis cukup path relatif: `wiki/queries/x.md`.
- Pisah topik pakai **folder + tag + frontmatter** di dalam satu project
  (`wiki/concepts`, `wiki/entities`, `wiki/comparisons`, `wiki/queries`, `wiki/ops`,
  `wiki/life`, katalog di `wiki/index.md`) — itu "kategori"-nya.
- Butuh project benar-benar terpisah (data/izin berbeda)? Jalankan **stack kedua**
  (port + `LLM_WIKI_PROJECT` + token sendiri). Jangan mengandalkan satu token
  bersama untuk pemisahan.
- **Dir project harus sudah ada di disk sebelum `llm_wiki_set_project`.** Menunjuk ke
  path yang belum ada membuat SEMUA call balas `400 Failed to resolve project path`
  (app tidak membuat dir; symlink ke luar project juga ditolak "path escapes project").
  Pola multi-project (`workspace/project-1`, `project-2`, ...): `mkdir -p
  <root>/project-N/wiki`, seed skeleton (`wiki/index.md`, `wiki/log.md`), baru
  `set_project` ke dir itu, lalu buktikan tulis/baca lewat MCP sebelum bilang jadi.
  Current project cuma di memori — restart app balik ke default `LLM_WIKI_PROJECT`.

## Menulis halaman (konvensi + mekanik)

- `llm_wiki_write_page {path, content}` — `path` **relatif ke `wiki/`** (`ops/x.md`,
  `concepts/y.md`). Menimpa halaman yang sudah ada wajib `allowOverwrite: true`; tanpa itu
  call ditolak. Balasan sukses memuat `verified: true` + `bytes`, dan tetap baca balik
  (`llm_wiki_read_file`) sebelum melaporkan selesai.
- **Setelah satu batch tulis — atau setelah mengedit file wiki langsung di disk — jalankan
  `llm_wiki_rescan_sources`.** Tanpa itu halaman ada di disk tapi belum masuk index/graph,
  jadi pencarian tetap kosong walau tulisannya "berhasil".
- Frontmatter wajib (spesifikasi ada di `wiki/SCHEMA.md` project): `title`, `created`,
  `updated`, `type`, `tags`, `sources`, `confidence`, `contested`, `contradictions`.
- **Tag provenance wajib untuk knowledge yang lahir dari pengalaman sebuah box** (tag
  `repl` di project ini): pembaca di luar konteks Replit bisa men-skip hanya dari tag itu,
  dan `index.md` + `log.md` memuat satu baris konteks di kepalanya. Taksonomi tag dicatat di
  `wiki/SCHEMA.md`; tambah tag baru hanya kalau yang ada tidak cukup, lalu catat di tabelnya.
- Satu halaman = satu topik, nama `kebab-case.md`; `log.md` append-only (entri baru di bawah,
  tanggal + verb `create|update|fix`) dan `index.md` diperbarui di batch yang sama supaya
  hitungan/judulnya tidak basi.

## Replit-spesifik

- Taruh semuanya di bawah `$REPL_HOME` (persisten); `$HOME` dan `/tmp` kena wipe, dan
  **proses yang dijalankan dari sesi agen mati bersama sesinya** — stack yang tadi hidup
  bisa sepenuhnya mati di sesi berikutnya. Probe dulu (`19828`, `80`, `8199`, `6800`)
  sebelum mendiagnosis apa pun. Daftarkan TIAP supervisor sebagai workflow sendiri di
  `.replit` (`llm-wiki-public` → `run-public.sh`, `llm-wiki-ui` → `run-ui.sh`); satu
  workflow per proses panjang, dan JANGAN berbagi `waitForPort` dengan workflow lain.
  Nama workflow milik operator (`llm-wiki-server` / `llm-wiki-public` sama-sama sah),
  tapi `waitForPort` HARUS sama dengan port loopback yang dipakai klien MCP (`8199`):
  angka lain membuat health-check workflow menunggu port yang tak pernah dibuka,
  sementara servernya sendiri sehat — entri terlihat mati padahal cuma salah port.
  Sebelum bilang sebuah workflow tidak ada, baca SEMUA header `name = ` di `.replit`;
  tiap workflow punya blok `[[workflows.workflow]]` sendiri dan `grep -A4` bisa
  menampilkan blok tetangga.
- **Supervisor jangan percaya file socket X.** `/tmp/.X11-unix/X99` menipu dua arah:
  Xvfb yang mati meninggalkan socket-nya, supervisor mengira display hidup, Xvfb tidak
  pernah dinyalakan, dan app keluar `Failed to initialize GTK` (log hanya berisi panic
  GTK) sementara supervisor melaporkan dirinya sehat; socket juga bisa hilang saat Xvfb
  masih hidup. Syaratkan proses Xvfb untuk display itu hidup dan hapus socket + lock
  basi sebelum start — aturan lengkap + guard WM di skill `headless-gui-linux`.
- Port harus ada di `.replit [[ports]]` (dan perubahan baru efektif setelah Repl
  restart). Untuk port app `:19828` cukup jangan diumbar — server Node di port yang
  sudah terdaftar (80) yang jadi pintunya.
- Tidak ada root/systemd: `machine-id` tak bisa ditulis → dbus session distart manual;
  websocket/DBus warning `LIBDBUSMENU-GLIB` tidak fatal.
- `apt` tidak tersedia untuk user → `shared-mime-info`/mesa/wayland diambil dari
  `/nix/store` (lihat `references/nix.md`).

## Gate verifikasi (jangan percaya klaim, cek ini)

1. `curl -s localhost:$(sed -n 's/^LLM_WIKI_PORT=//p' ~/.local/share/llmwiki-app/.env)/health` → `ok:true`, `upstream` healthy (port diambil dari
   `.env`; curl ke `:8080` yang menjawab dengan JSON lain = port itu milik dashboard).
2. `initialize` ke `/mcp` → `serverInfo.name == llm-wiki`.
3. `tools/list` → 12 tool.
4. `llm_wiki_write_page` lalu `llm_wiki_read_file` dengan path sama → isi cocok
   (`verified:true` untuk write).
5. Token read-only: GET REST 200, POST `/pages/write` **403**, `llm_wiki_projects` jalan,
   `llm_wiki_write_page` ditolak `-32003`; token penuh tetap 200 untuk tulis.
6. `pkill -x llm-wiki` → dalam <40 detik app hidup lagi (bukti supervisor benar).

## Yang tidak bisa diharapkan

- UI desktop dibuka lewat browser: **tidak bisa langsung** — frontend Tauri (`invoke`),
  jadi pakai noVNC (`run-ui.sh`: x11vnc loopback + noVNC publik `:3000`, VNC password).
- Pilih project lewat file chooser GTK: enumerasi GIO kosong di box ini.
- Multi-user/login: tidak ada; satu token, satu current project.
- Vector search butuh `embeddingConfig` (provider + model + baseUrl, bisa
  OpenAI-compatible atau Ollama) di app state; chat butuh `llmConfig` (API key LLM).
  Tanpa itu search tetap jalan mode keyword; `llm_wiki_chat` mengembalikan error.
- GPU: tidak ada → software render (`llvmpipe`); UI berat tapi jalan.

## Lokasi data: `$REPL_HOME`, bukan `$HOME`

Di Replit `$HOME=/home/runner` sedangkan workspace Repl adalah `$REPL_HOME`
(`/home/runner/workspace`); ssh tanpa login shell tidak mengekspor `$REPL_HOME`.
Instalasi hidup di `${REPL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/llmwiki-app`
supaya workflow `.replit` dan tombol Run menemukannya, jadi kalau menjalankan setup
lewat ssh setel sendiri: `export REPL_HOME=/home/runner/workspace`. Token disimpan di
`<dir>/.env` (instalasi lama `llmwiki.env` dimigrasikan otomatis, nama lama tak dipakai).
Jangan biarkan dua salinan hidup — salinan di `$HOME/.local/share` tidak akan dipakai
workflow mana pun.

Display (Xvfb/fluxbox) dan store nix-nya ikut `$REPL_HOME` (`$REPL_HOME/.local/bin`,
`$REPL_HOME/.store`) — `$HOME` kena wipe tiap Repl restart, jadi wrapper yang menunjuk
`$HOME/.store` akan mati dengan `cannot execute`. `nixenv` juga resolve store dari
`REPL_HOME`, dan `run-public.sh` menambahkan `$REPL_HOME/.local/bin` + `.../node/bin`
ke PATH sendiri supaya supervisor yang dijalankan lewat ssh tetap menemukan Xvfb/node.

## Instal dari nol (mesin bersih)

Tidak ada yang disiapkan manual: skill mengunduh, mengekstrak, dan mem-build semua
sendiri. Urutannya:

1. `npx -y skills add skynight137/skills -s replit --agent "*" -y` — prompt interaktif
   mati kalau stdin bukan TTY, dan tanpa `LD_LIBRARY_PATH` node mati `libatomic.so.1`.
   Di ssh non-interaktif: `export LD_LIBRARY_PATH=$(ls -d /nix/store/*gcc-1*-lib/lib | tail -1)`,
   dan PATH tidak punya `node`/`npx` sama sekali (`/usr/bin/env: node: No such file or
   directory`) — prepend bin dir store: `export PATH="$(ls -d
   /nix/store/*nodejs-slim-*/bin | head -1):$PATH"`.
2. `bash ~/.agents/skills/replit/scripts/setup.sh --llm-wiki` (juga butuh
   `LD_LIBRARY_PATH` di atas; tanpa itu `node -e` pembuat token gagal).
3. Cek `lldd` bersih: `LD_LIBRARY_PATH=$(cat ~/.local/share/llmwiki-app/.ldpath) ldd
   ~/.local/share/llmwiki-app/squashfs-root/usr/bin/llm-wiki | grep -c "not found"` → 0.
   Kalau ada sisa, modul mem-build paketnya lalu mengulang resolusi; `.ldpath` yang
   berhenti tumbuh = paket memang tidak punya lib itu, bukan sukses.

Port publik default 8319 (8080 milik dashboard Hermes) dan disimpan sebagai
`LLM_WIKI_PORT` di `.env`; sesudah server hidup supervisor memanggil dev-domain sekali
supaya platform mendaftarkan portnya.

## Client di mesin lain

Tailscale di box ini berjalan **userspace** (`--tun=userspace-networking`, SOCKS5 di
`:1055`) dan **tidak** punya TUN, jadi `http://<ip-tailnet>:8319` dari mesin lain
memberi `000` walau server hidup — `ssh` tetap jalan karena lewat ProxyCommand SOCKS.
Yang dipakai: tunnel ssh ke loopback klien.

    ssh -N -L 127.0.0.1:8319:localhost:8319 repl-test      # di mesin klien
    hermes mcp add / edit entry:  url http://127.0.0.1:8319/mcp
                                  header Authorization: Bearer <LLM_WIKI_API_TOKEN>

Token penuh dari `~/.local/share/llmwiki-app/.env` di mesin server. Bukti koneksi:
`hermes mcp test llm-wiki` harus menampilkan daftar tool, bukan "Connection failed".
Tunnel mati bersama sesinya — jalankan di supervisor (`persist`) atau workflow kalau
butuh permanen.

## Publik lewat dev domain

Pakai port **80**: `LLM_WIKI_PORT=80` di `.env`, deklarasikan `.replit`
(`[[ports]] localPort = 80` + `externalPort = 80`), lalu akses
`https://$REPLIT_DEV_DOMAIN/mcp` — tanpa sufiks port. Header tetap
`Authorization: Bearer <token>`. 8081 termasuk yang di atas kertas boleh, tapi di
repl-test deklarasi + listener tidak membuat edge memetakannya (`000` terus) sementara
8080/6800 yang sudah hidup saat boot dipetakan; detail di `references/public-ports.md`.

Tunnel ssh hanya fallback saat edge belum memetakan port 80:
`ssh -N -L 127.0.0.1:8080:localhost:80 repl-test` lalu url loopback.

### Port UI: samakan nomor lokal dan publik

`.replit` memetakan `localPort -> externalPort`. Supaya tidak bingung (lokal `:6080`,
publik `:3000`), UI sekarang **listen di 3000 dan dipetakan `3000 -> 3000`** — satu angka
untuk dua jalan: `http://127.0.0.1:3000/vnc.html` dan
`https://<REPLIT_DEV_DOMAIN>:3000/vnc.html` sama-sama 200. Ganti dengan
`LLM_WIKI_UI_PORT=<port>` + entri `[[ports]]` yang cocok kalau operator mau angka lain.

## Jangan tertukar: dua "llm-wiki"

| | Skill Hermes `llm-wiki` | App nashsu/llm_wiki |
|---|---|---|
| Wujud | SKILL.md (markdown Karpathy) | AppImage + node server + MCP |
| Env | `WIKI_PATH` (default `~/wiki`) | `LLM_WIKI_*` (`API_TOKEN`, `PORT`, `PROJECT_PATH`) |
| Tool | read_file/write_file/search_files | tool MCP `llm_wiki_*` |
| Letak | `hermes-agent/skills/research/llm-wiki/`, bisa di-disable via `skills.disabled` | bundle mesin repl |

`LLM_WIKI_PATH` **tidak ada** di Hermes (yang ada `WIKI_PATH`); awalan `LLM_WIKI_` milik app.
Reference milik skill Hermes (`references/self-hosted-service.md`) memuat cara menjalankan app
nashsu sebagai layanan (layout `wiki/**.md`, API `:19828/api/v1`, MCP-over-HTTP, token satu file).
