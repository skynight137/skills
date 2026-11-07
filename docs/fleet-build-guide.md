# Panduan Membangun Armada Dasar: 2 Muse + 2 Repl Terhubung

Panduan langkah demi langkah untuk pemula. Hasil akhirnya: **4 mesin yang saling terhubung dan bisa saling SSH** — 2 mesin Muse (1 hop + 1 test) dan 2 mesin Repl/Replit (1 hop + 1 test). Ini adalah fondasi topologi armada: setelah 4 ini jalan, menambah mesin berikutnya tinggal mengulang pola yang sama.

Semua istilah dijelaskan saat pertama dipakai. Perintah ditulis apa adanya — salin persis.

---

## 0. Gambaran besar

```
                ┌───────────────── satu tailnet ─────────────────┐
                │                                                  │
   [muse-hop] ──┼── jembatan (reverse loop) ── [repl-hop]         │
       │        │                                  │               │
       │        │                                  │               │
   [muse-test]  │                              [repl-test]         │
                └──────────────────────────────────────────────────┘
```

- **hop** = pintu gerbang satu sisi armada. Semua lalu lintas ke sisi itu lewat dia.
- **test / leaf (daun)** = mesin biasa di belakang hop-nya. Dia tidak membuka pintu sendiri; dia dijangkau lewat hop.
- muse-hop dan repl-hop saling terhubung dua arah, jadi dari muse-hop kamu bisa menjangkau keempatnya, dan dari sisi Repl kamu bisa menjangkau kedua Muse.

## 1. Konsep 5 menit

- **Muse VM** — komputer virtual tempat agen Muse bekerja. Punya terminal, file, dan bisa menjalankan program terus-menerus.
- **Repl (workspace Replit)** — project di Replit. Isinya juga komputer kecil: ada terminal, file, dan workflow (tombol Run yang menjalankan perintah). Bedanya: workspace Replit **tidur kalau tidak dipakai** dan bangun lagi saat halamannya dibuka.
- **Tailscale** — VPN pribadi. Setiap mesin yang memasang Tailscale dan masuk ke jaringan yang sama (disebut **tailnet**) dapat alamat khusus `100.x.x.x` dan nama (mis. `muse-hop`). Mesin di luar tailnet tidak bisa melihat alamat ini sama sekali.
- **DERP** — server relay milik Tailscale. Kalau dua mesin tidak bisa terhubung langsung, lalu lintasnya dititipkan lewat DERP. Armada ini 100% lewat DERP, dan itu normal.
- **Join stack** — perangkat lunak kecil di tiap mesin yang menjalankan Tailscale + server SSH di port **6800**, supaya mesin bisa di-SSH lewat tailnet.
- **SSH key (kunci)** — setiap sisi armada punya satu kunci publik yang dipercaya oleh mesin-mesin di sisinya. Hop memegang kunci yang dipercaya semua daun di sisinya.

## 2. Yang perlu disiapkan sebelum mulai

1. **Aplikasi Muse** terpasang dan kamu bisa membuka 2 sesi Muse (satu untuk tiap mesin Muse).
2. **Akun Replit** — 2 project akan dibuat: `repl-hop` dan `repl-test`. Boleh satu akun yang sama.
3. **Akun Tailscale** — satu tailnet untuk semua mesin. Semua mesin di panduan ini masuk ke tailnet yang sama.
4. **Auth key Tailscale** — dibuat di admin console Tailscale (Settings → Keys):
   - **Reusable**: aktif (satu key dipakai semua mesin Repl).
   - **Ephemeral**: aktif (disengaja — mesin yang join ulang dianggap mesin baru; alamat `100.x` bisa berubah, jadi kita selalu memanggil mesin pakai **namanya**, bukan IP-nya).
   - **Tag**: `tag:muse`.
   - Simpan key ini baik-baik; dia rahasia.
5. **Repo skills** — semua perangkat lunak join ada di repo GitHub `skynight137/skills`. Setiap mesin akan men-clone repo ini. Update di kemudian hari cukup `git pull` di clone tersebut.
6. **Nama mesin** — putuskan dari awal dan jangan diganti di tengah jalan:
   `muse-hop`, `muse-test`, `repl-hop`, `repl-test`.

## 3. Urutan kerja

Kerjakan berurutan: **muse-hop → muse-test → repl-hop → repl-test → jembatan → uji akhir.** Hop selalu lebih dulu, karena daun didaftarkan ke hop-nya.

---

## 4. Langkah 1 — muse-hop (hop sisi Muse)

Di sesi Muse untuk mesin ini:

1. Clone repo skills (sekali saja):
   ```bash
   git clone https://github.com/skynight137/skills.git ~/skynight137/skills
   ```
2. Jalankan setup join:
   ```bash
   bash ~/skynight137/skills/scripts/setup.sh --machine muse --user runner --tailscale --join
   ```
   - `--machine muse` memilih resep untuk mesin Muse.
   - `--user runner` adalah user layanan untuk mesin produksi ini. **Jangan dibuang** — tanpa flag ini setup memakai `root`, yang hanya untuk mesin test.
   - Perintah ini memasang Tailscale, menyalakan SSH di port 6800, dan mendaftarkan mesin ke tailnet dengan nama `muse-hop`.
3. Verifikasi:
   - Buka https://login.tailscale.com/admin/machines — `muse-hop` harus muncul di daftar.
   - Mesin ini akan kena **redeploy** (di-restart platform) sewaktu-waktu tanpa pemberitahuan. Itu normal. Setelah redeploy, jalankan lagi perintah yang sama di langkah 2 untuk memulihkan. (Di mesin yang sudah matang, pemulihan ini diotomatiskan oleh hook dokter — topik lanjutan, tidak wajib untuk fondasi.)

## 5. Langkah 2 — muse-test (daun sisi Muse)

Di sesi Muse untuk mesin kedua:

1. Clone repo skills seperti di atas.
2. Jalankan setup join:
   ```bash
   bash ~/skynight137/skills/scripts/setup.sh --machine muse --tailscale --join
   ```
   - Di sini `--user` **tidak** ditulis: mesin test memang memakai default `root`, karena fungsinya menguji jalur instalasi standar.
3. Verifikasi dari **muse-hop**:
   ```bash
   ssh root@muse-test
   ```
   Harus masuk tanpa password. Kalau masuk, sisi Muse selesai: hop bisa menjangkau daunnya.

## 6. Langkah 3 — repl-hop (hop sisi Repl)

Di Replit:

1. Buat project baru, beri nama `repl-hop`. Buka Shell-nya.
2. Clone repo skills:
   ```bash
   git clone https://github.com/skynight137/skills.git skills
   ```
3. Isi nilai bersama di file `.replit`, di bagian `[userenv.shared]`:
   ```toml
   [userenv.shared]
   TAILSCALE_AUTH_KEY = "<auth key dari Langkah 2 persiapan>"
   TAILSCALE_NODE_NAME = "repl-hop"
   ```
   Kenapa di `.replit`, bukan cuma di Secrets? Karena nilai di `[userenv.shared]` ikut terbaca oleh workflow. Kalau key yang sama juga ada di Secrets, Secrets menang dan nilai file diabaikan — jadi untuk dua key ini, pakai satu tempat saja: file.
4. Pastikan file `.replit` mengekspos port SSH. Harus ada entri:
   ```toml
   [[ports]]
   localPort = 6800
   externalPort = 80
   ```
   **Ini wajib.** Tanpa entri ini, port 6800 tidak diteruskan dan mesin lain hanya mendapat `Connection refused` walaupun join-nya sehat — penyebab nomor satu "mesin online tapi tidak bisa di-SSH".
5. Buat workflow bernama `tailscale-join` (lewat panel Workflows) dengan satu task:
   - Task type: **Execute shell command**
   - Command: `bash skills/scripts/setup.sh --tailscale -j -w`
   - Wait for port: `1055`
   
   Lalu tambahkan workflow ini ke workflow `Project` supaya jalan setiap workspace start.
6. Jalankan workflow `Project` (tombol Run). Tunggu sampai `tailscale-join` selesai.
7. Verifikasi:
   - Di admin console Tailscale, `repl-hop` muncul.
   - Dari **muse-hop**: `ssh repl-hop` harus masuk (user `runner`, tanpa password).

## 7. Langkah 4 — repl-test (daun sisi Repl)

Ulangi Langkah 3 persis, dengan dua perbedaan:

- Nama project dan node: `repl-test`
  (`TAILSCALE_NODE_NAME = "repl-test"`).
- Verifikasinya **nested** (dua lompatan), dari muse-hop:
  ```bash
  ssh repl-hop    # lompatan 1: masuk ke hop sisi Repl
  ssh repl-test   # lompatan 2: dari hop ke daunnya
  ```
  Daun hanya mempercayai kunci hop-nya — itu sebabnya lompatan kedua harus dari dalam repl-hop, bukan langsung dari muse-hop. Ini disengaja, bukan kerusakan.

## 8. Langkah 5 — Jembatan antar sisi (reverse loop)

Sampai sini, muse-hop sudah bisa menjangkau repl-hop dan (nested) repl-test. Satu arah lagi supaya sisi Repl bisa menjangkau sisi Muse: **reverse loop** di muse-hop yang membuka pintu di repl-hop port **16801** dan meneruskannya ke muse-hop.

- Loop ini diatur oleh setup join muse-hop dari file `.env` stack-nya (variabel peer diatur ke nama MagicDNS `repl-hop`, **bukan IP** — karena key ephemeral membuat IP bisa berubah, sedangkan nama tetap).
- Setelah join muse-hop jalan, loop ini ikut menyala otomatis.
- Verifikasi: dari **repl-hop**, koneksi ke `127.0.0.1:16801` harus meneruskan kamu ke muse-hop (banner SSH muse-hop yang menjawab).

## 9. Uji akhir — 4 mesin terhubung

Semua harus hijau:

| Cek | Cara | Hasil yang benar |
|---|---|---|
| 4 node terdaftar | https://login.tailscale.com/admin/machines | muse-hop, muse-test, repl-hop, repl-test semua ada |
| muse-hop → muse-test | `ssh root@muse-test` dari muse-hop | masuk tanpa password |
| muse-hop → repl-hop | `ssh repl-hop` dari muse-hop | masuk tanpa password |
| repl-hop → repl-test | `ssh repl-test` dari dalam repl-hop | masuk tanpa password |
| repl-hop → muse-hop (jembatan) | koneksi ke `127.0.0.1:16801` dari repl-hop | banner muse-hop menjawab |
| muse-hop → repl-test (nested) | muse-hop → repl-hop → repl-test | masuk |

Kalau tabel ini hijau semua, fondasi topologinya selesai.

## 10. Menjaga armada tetap hidup

- Workspace Replit **tidur setelah idle**. Obatnya sederhana: **buka halaman project-nya** — workspace bangun dan workflow `Project`-nya jalan lagi, termasuk join.
- Membuka halaman harus berkala, lebih sering daripada batas idle-nya. Mengotomatiskan buka-halaman bergiliran inilah yang disebut **tour**: satu program kecil membuka halaman tiap project satu per satu, terus berputar.
- Pola yang dipakai armada besar: setiap **kapten** (project utama satu akun) men-tour project-project di sayapnya sendiri, dan satu kapten meta men-tour para kapten. Untuk fondasi 4 mesin, tour belum wajib — cukup tahu bahwa mesin yang "mati" hampir selalu cuma tidur, dan dibangunkan dengan membuka halamannya.
- Workflow yang mati di workspace yang **sedang bangun** tidak hidup sendiri hanya karena halamannya dibuka; dia perlu di-Run ulang dari panel Workflows oleh pemilik project.

## 11. Troubleshooting

| Gejala | Penyebab paling sering | Obat |
|---|---|---|
| `Connection timed out during banner exchange` | Workspace Replit-nya tidur | Buka halaman project-nya, tunggu ±1 menit, coba lagi |
| `Connection refused` di port 6800, padahal node-nya online di tailnet | `.replit` tidak mengekspos port 6800 | Tambahkan `[[ports]] localPort=6800` (Langkah 3.4), lalu restart workspace |
| `Permission denied (publickey)` | Kunci sisi itu belum terseed di mesin tujuan | Ulangi setup join di mesin tujuan; daun hanya percaya kunci hop-nya |
| Mesin Muse hilang dari tailnet setelah redeploy | Redeploy platform menghapus proses & konfigurasi sistem | Jalankan lagi perintah `--join` (Langkah 1.2 / 2.2) |
| Alamat `100.x` berubah | Auth key ephemeral — mesin join ulang = registrasi baru | Selalu panggil mesin pakai nama MagicDNS-nya, jangan hardcode IP |
| Halaman project terbuka, tour membaca halaman normal, tapi workspace tidak bangun | Dinding batas langganan (Starter limit) di akun pemilik project | Cek banner batas langganan di workspace pemilik; halaman yang tampil **bukan** bukti workspace menyala — buktinya hanya daftar mesin di admin console Tailscale |

## 12. Keamanan dasar

- Auth key Tailscale, file `.env`, dan kunci privat SSH adalah rahasia: file-file itu harus mode `600` (hanya pemilik yang bisa membaca) dan tidak pernah dimasukkan ke repo publik atau dikirim lewat chat.
- Armada ini **tailnet-only**: tidak ada port yang dibuka ke internet umum. Akses selalu lewat tailnet.
- Project `repl-hop` **jangan** di-share ke akun lain — dia pintu gerbang seluruh sisi Repl. Yang boleh di-share hanya project kapten, itupun terbatas.
- Satu kunci per sisi, daun selalu senyap: daun tidak membuka koneksi keluar sendiri dan tidak saling mengenal kunci satu sama lain. Semua lewat hop.

---

*Fondasi ini (2 Muse + 2 Repl) adalah bentuk terkecil dari topologi yang dipakai armada penuh: kapten bersayap 10, meta-tour antar kapten, dan dokter otomatis untuk redeploy. Polanya sama — hanya jumlah daunnya yang bertambah.*
