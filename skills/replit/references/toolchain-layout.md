# Toolchain layout — di mana sesuatu tinggal, dan pola menambah tool

Aturan tata letak `setup.sh`: satu pola untuk semua tool, supaya tool ke-22
terpasang persis seperti tool pertama — dan supaya tidak ada state yang diam-diam
tinggal di lokasi yang kena wipe.

## Persisten vs wiped (Replit)

| Lokasi | Nasib | Isi |
|---|---|---|
| `$REPL_HOME` (= `~/workspace`, volume workspace) | **persisten** | SEMUA state toolchain |
| `$HOME` di luar workspace, `/tmp` | **wiped** saat recreate | hanya cache sekali pakai |

Konsekuensinya mutlak: binary, payload, config, cache, kredensial, dan state
daemon harus berada di bawah root persisten. Default upstream yang menaruh state
di `$HOME` WAJIB dipin ke lokasi persisten oleh modul install-nya.

## Pola path (mode Replit: XDG dir di-root ke `$REPL_HOME`)

| Jenis | Pola | Contoh |
|---|---|---|
| Binary / symlink di PATH | `$XDG_BIN_HOME/<tool>` | `.local/bin/rclone` |
| Payload (dir install tool) | `$XDG_DATA_HOME/<tool>` | `.local/share/ollama`, `.local/share/llmwiki-app` |
| Config | `$XDG_CONFIG_HOME/<tool>` | `.config/opencode` |
| Cache / engine besar | `$XDG_CACHE_HOME/<tool>` | `.cache/camoufox` |
| Var home tool | `<TOOL>_HOME` → menunjuk dir data/config di atas | `OLLAMA_INSTALL_DIR` |

Pengecualian warisan (jangan ditiru tool baru, jangan diutak-atik tanpa migrasi):
`HERMES_HOME=$REPL_HOME/.hermes`, `TAILSCALE_DATA_DIR`, `ZSH_PROFILE` di
`$REPL_HOME/.local/nix-profiles/zsh`.

Modul tidak pernah meng-hardcode `/home/runner/...` dan tidak pernah
menebak root sendiri: root datang dari resolver (bagian berikutnya).

## Root instalasi & manifest (satu resolver, tanpa fallback diam-diam)

Root ditentukan **sekali** di `scripts/setup/root.sh`, sebelum modul lain
menurunkan path apa pun. Urutannya:

1. `SETUP_ROOT` (env) — pilihan eksplisit operator; dicatat ke
   `$PLATFORM_HOME/.config/replit-setup/root` supaya run berikutnya
   (doctor/fix/clean) menemukan root yang sama tanpa env itu.
2. Root tercatat dari pilihan eksplisit sebelumnya.
3. Workspace persisten platform (`$REPL_HOME`).
4. **Die.** Tidak ada lagi layout fallback diam-diam (`$(pwd)` / `$HOME`):
   shell yang kehilangan env platform berhenti sebelum menginstal apa pun,
   bukan diam-diam menginstal ke pohon yang kena wipe.

Setiap run mencetak `setup root: <path> (source: env|recorded|default)`.
Root di luar workspace persisten memicu warning eksplisit (kena wipe saat
recreate) tapi tetap jalan — pilihan operator tidak pernah dipindahkan
diam-diam. Untuk root non-platform, XDG_* bawaan platform di-unset supaya
derivasi XDG jatuh di bawah root pilihan, bukan bocor balik ke workspace
platform.

Setiap install yang sukses mencatat path payload-nya ke manifest
`<root>/.config/replit-setup/manifest.tsv` (baris `tool<TAB>path`, ditulis
`run_install_step` lewat `manifest_record_for` di root.sh — cermin dari yang
dihapus `clean_<tool>`; data user yang dipertahankan clean TIDAK dicatat).
`clean()` menyapu persis path tercatat itu setelah clean per-tool selesai,
kecuali label di `_CLEAN_SKIPPED` (mis. backup Hermes gagal — payload-nya
tidak boleh hilang). tailscale/join sengaja tidak dicatat: state-nya daemon
hidup + identitas node, milik logika eksplisit `clean_tailscale`.

## Pola penamaan

- Flag: `-xx, --<tool>` (nama tool, bukan verba); alias pendek dan panjang satu
  `case` arm yang sama (lihat disiplin rename di SKILL.md).
- Fungsi: `install_<tool>()` di `scripts/setup/<tool>.sh`; `clean_<tool>()` di
  `scripts/setup/cleanup.sh` (atau file modulnya bila sangat tool-spesifik).
- Target clean = label install-nya persis: `--clean <tool>`. Satu tool, satu
  target, satu pemilik.
- Env var milik tool: awalan `<TOOL>_` (`OLLAMA_MODELS`, `CAMOFOX_STATE_DIR`).

## Checklist menambah tool (tujuh permukaan, semuanya atau tidak sama sekali)

Kegagalan klasik di repo ini adalah permukaan yang ketinggalan: flag ada tapi
guard tidak, fungsi clean ada tapi labelnya tidak terdaftar. Audit e2e
2026-11-01 menemukan kasus nyata (`--zsh` memicu INSTALL_ALL,
`--clean hermes-chromium` tidak terjangkau). Maka:

1. `scripts/setup/<tool>.sh` — `install_<tool>()`: idempotent, unduhan
   diverifikasi checksum bila upstream menyediakan, paket sistem report-only.
2. `setup/rc.sh` — flag + `INSTALL_<TOOL>` di **kedua** guard seleksi: guard
   INSTALL_ALL di `parse_args` DAN cek pasca-menu di `setup/cli.sh`. Satu yang
   hilang = flag tunggal jatuh ke INSTALL_ALL / "No tools selected".
3. `setup/cli.sh` — satu baris dispatch `run_install_step <tool> install_<tool>`.
4. `setup/doctor.sh` — satu baris `check_tool` dengan semantik flag versi yang
   benar (`--version` vs `-version` vs subcommand `version`).
5. `setup/cleanup.sh` — `clean_<tool>()` + label di **semua** pola target:
   preflight, hint, dispatch utama, daftar `--clean all`, menu, dan entri
   `clean_paths_for`. Data user tidak pernah dihapus diam-diam: dipertahankan
   atau dibackup dulu (pola hermes/ollama/camofox).
6. `setup/common.sh` — baris `wire_tool <tool> <VARS> -- <PATH dirs>` di
   `seed_tool_wiring()` (cermin dari yang dicatat installer), supaya `--clean`
   dan `--fix` bisa menyelesaikan kepemilikan wiring tanpa menjalankan installer.
7. `setup/root.sh` — satu arm di `manifest_record_for` berisi path payload
   yang dibuat installer (cermin dari yang dihapus `clean_<tool>`, tanpa data
   user yang dipertahankan clean), supaya clean menyapu persis yang ditulis
   install.
   Terakhir: baris tabel tool di SKILL.md + teks usage di `rc.sh`, dalam
   perubahan yang sama.

Verifikasi sebelum merge: siklus penuh di mesin test (repl-test) —
install → run → `--doctor` → `--clean <tool> -y` → pastikan path payload
benar-benar hilang. `bash -n` saja tidak cukup: tiga bug di atas lolos
`bash -n` bertahun-tahun karena sifatnya runtime/registrasi, bukan sintaks.
