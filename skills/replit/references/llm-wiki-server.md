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

## File bundel (di repo ini: `tools/llmwiki-app/`)

`install.sh` (unduh AppImage + ekstrak + bikin token) · `run-public.sh` (supervisor:
Xvfb → WM → app → server, auto-restart) · `start-app.sh` (launcher app portabel) ·
`llmwiki-server.js` (server MCP+REST) · `llmwiki.env` (token, chmod 600) ·
`pixbuf/` (loader PNG opsional) · `.ldpath`/`.libdirs.pre` (dir lib khusus mesin, boleh kosong).

Belum dipublikasikan ke repo publik — salin folder ini ke server, atau publish dulu
kalau mau dipakai pihak ketiga.

## Prasyarat (Debian/Ubuntu)

```bash
apt install -y nodejs curl xvfb fluxbox shared-mime-info dbus-x11
```

- **node ≥ 18** — satu-satunya runtime server. **Jangan** pakai node milik Hermes
  (`$HERMES_HOME/tools/node-*`): di luar jalur, butuh `libatomic.so.1`, dan Hermes
  membuang `LD_LIBRARY_PATH` dari child MCP.
- **window manager wajib** — tanpa WM window GTK dibuat tapi tidak pernah di-map
  (screenshot hitam, `xwininfo -root -tree` = `0 children`).
- **`shared-mime-info` wajib** — gdk-pixbuf 2.42 memilih loader lewat MIME sniffing;
  tanpa database MIME, semua gambar "unrecognized" dan GTK abort di `gtkiconhelper.c`.
- AppImage ini **tidak** menyertakan loader PNG; kalau GTK mati karena ikon, pakai
  `pixbuf/loaders.cache` (loader harus cocok ABI: header 2.42.8 untuk lib bundle 2.42.8).

## Jalankan

```bash
bash install.sh          # sekali per mesin: AppImage + token
bash run-public.sh       # supervisor, foreground (systemd / workflow / tmux)
```

## Endpoint

| Endpoint | Auth | Untuk |
|---|---|---|
| `http://127.0.0.1:8081/mcp` | `Authorization: Bearer <token>` | agen di mesin yang sama (ini yang dipakai profile Hermes) |
| `http://127.0.0.1:8199/mcp` | tanpa token (bind loopback) | agen lokal yang tak mau bawa secret |
| `https://<host>:8081/mcp` | header sama | agen di mesin lain, **kalau** port sudah dirutekan |
| `https://<host>:8081/api/v1/...` | header sama | script/curl |
| `https://<host>:8081/health` | tanpa auth | cek server + upstream |

Port publik default **8081**, bukan 8080: di box ini 8080 dipakai
`hermes -p <profile> dashboard`. Kalau tabrakan, server tidak bisa bind dan `/health`
justru balas **302 + `{"error":"unauthenticated",...,"login_url":"/login"}`** — itu
dashboard Hermes, bukan llm-wiki. Cek pemilik port dulu sebelum menuduh server rusak.

Di Replit, port yang baru ditambahkan ke `.replit [[ports]]` belum tentu langsung
dirutekan (butuh Repl restart) — selama itu, klien di mesin yang sama pakai loopback.

## Token (dua level)

| Env | Hak |
|---|---|
| `LLM_WIKI_API_TOKEN` | penuh (tulis, embed, rescan, chat) |
| `LLM_WIKI_READONLY_TOKEN` | read-only: REST GET + `search`/`graph`; tool MCP baca saja (tool tulis → `-32003`) |

Keduanya dibaca dari `llmwiki.env`, dipakai dengan header yang sama, dan token read-only
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
hermes -p <profile> mcp add llm-wiki --url http://127.0.0.1:8081/mcp
hermes -p <profile> config set mcp_servers.llm-wiki.headers.Authorization 'Bearer ${LLM_WIKI_API_TOKEN}'
```

`config set` menerima `${VAR}`; Hermes membacanya dari `.env` profile itu, jadi nama tokennya
tetap **`LLM_WIKI_API_TOKEN`** (alias `MCP_<NAMA>_API_KEY` cuma dipakai kalau memakai flag
`--auth header`). Klien non-Hermes: `{"mcpServers":{"llm-wiki":{"url":"http://127.0.0.1:8081/mcp",
"headers":{"Authorization":"Bearer <token>"}}}}`. Tool yang muncul: 12
(`llm_wiki_status/projects/set_project/files/read_file/write_page/search/graph/
rescan_sources/embed_page/reviews/chat`).

## Model project & kategori (pertanyaan yang sering muncul)

- App punya **satu “current project”** (disimpan di clip server, hanya di memori).
  `LLM_WIKI_PROJECT` menetapkan defaultnya; `llm_wiki_set_project` mengubahnya
  **global untuk instance itu** — jadi dua agen yang berbagi satu app menulis ke
  project yang sama kecuali mereka mengirim `project=<id>` eksplisit per panggilan.
- Pisah topik pakai **folder + tag + frontmatter** di dalam satu project
  (`wiki/concepts`, `wiki/entities`, `wiki/comparisons`, `wiki/queries`, `wiki/ops`,
  `wiki/life`, katalog di `wiki/index.md`) — itu "kategori"-nya.
- Butuh project benar-benar terpisah (data/izin berbeda)? Jalankan **stack kedua**
  (port + `LLM_WIKI_PROJECT` + token sendiri). Jangan mengandalkan satu token
  bersama untuk pemisahan.

## Replit-spesifik

- Taruh semuanya di bawah `$REPL_HOME` (persisten); `$HOME` dan `/tmp` kena wipe.
  `/tmp/.X11-unix` bisa hilang → app mati `Failed to initialize GTK` → itu sebabnya
  ada supervisor.
- Port harus ada di `.replit [[ports]]` (dan perubahan baru efektif setelah Repl
  restart). Untuk port app `:19828` cukup jangan diumbar — server Node di port yang
  sudah terdaftar (mis. 8081) yang jadi pintunya.
- Tidak ada root/systemd: `machine-id` tak bisa ditulis → dbus session distart manual;
  websocket/DBus warning `LIBDBUSMENU-GLIB` tidak fatal.
- `apt` tidak tersedia untuk user → `shared-mime-info`/mesa/wayland diambil dari
  `/nix/store` (lihat `references/nix.md`).

## Gate verifikasi (jangan percaya klaim, cek ini)

1. `curl -s localhost:8081/health` → `ok:true`, `upstream` healthy (curl ke `:8080` yang
   menjawab dengan JSON lain = port itu milik service lain).
2. `initialize` ke `/mcp` → `serverInfo.name == llm-wiki`.
3. `tools/list` → 12 tool.
4. `llm_wiki_write_page` lalu `llm_wiki_read_file` dengan path sama → isi cocok
   (`verified:true` untuk write).
5. Token read-only: GET REST 200, POST `/pages/write` **403**, `llm_wiki_projects` jalan,
   `llm_wiki_write_page` ditolak `-32003`; token penuh tetap 200 untuk tulis.
6. `pkill -x llm-wiki` → dalam <40 detik app hidup lagi (bukti supervisor benar).

## Yang tidak bisa diharapkan

- UI desktop dibuka lewat browser: **tidak bisa langsung** — frontend Tauri (`invoke`),
  jadi pakai noVNC (`run-ui.sh`: x11vnc loopback + noVNC publik `:8000`, VNC password).
- Pilih project lewat file chooser GTK: enumerasi GIO kosong di box ini.
- Multi-user/login: tidak ada; satu token, satu current project.
- Vector search butuh `embeddingConfig` (provider + model + baseUrl, bisa
  OpenAI-compatible atau Ollama) di app state; chat butuh `llmConfig` (API key LLM).
  Tanpa itu search tetap jalan mode keyword; `llm_wiki_chat` mengembalikan error.
- GPU: tidak ada → software render (`llvmpipe`); UI berat tapi jalan.
