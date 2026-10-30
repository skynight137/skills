# Port di Replit: mana yang bisa dibuka ke publik

Port tidak otomatis publik karena ada proses yang listen. Edge Replit hanya membuka
port yang **dideklarasikan** di `.replit`:

```
[[ports]]
localPort = 8081
externalPort = 8081
```

dan perubahan itu baru berlaku setelah Repl di-restart (Stop lalu Run, atau tombol Run
dari workflow). Mengedit `.replit` lalu menembak `https://$REPLIT_DEV_DOMAIN:8081/`
tanpa restart berakhir `000` karena edge masih menolak port itu. Flush DNS/`curl` tidak
menolong. Bukti cepat:

```
IP=$(getent ahostsv4 "$REPLIT_DEV_DOMAIN" | awk 'NR==1{print $1}')
for p in 80 443 8080 8081; do timeout 6 bash -c "echo > /dev/tcp/$IP/$p" 2>/dev/null \
  && echo "$p=open" || echo "$p=closed"; done
```

## Port yang boleh dipakai sebagai port publik

:80, :3000-:3003, :4200, :5000, :5173, :6000, :6800, :8000, :8008, :8080, :8081,
:8099, :9000. Port di luar daftar (mis. 8319, 64316) hanya hidup di loopback atau
lewat tunnel, tidak pernah tersaji dari edge.

## Pola pemakaian

1. **Satu app satu port publik, selebihnya loopback.** Layanan yang tidak wajib
   dijangkau dari internet (bridge antar-mesin, MCP, database, app internal) tetap di
   `127.0.0.1` dan diakses lewat ssh/tailscale, jadi port publik tidak habis.
2. **Pilih dari daftar di atas** saat memang butuh publik; jangan ambil port di luar
   daftar lalu heran `000`.
3. **Dokumentasikan pemiliknya** di `.replit` (nama workflow/port) supaya port berikutnya
   tidak bertabrakan. `8080` di box ini milik dashboard Hermes, `6080` di-map ke `:80`
   untuk noVNC.
4. **`externalPort = 80`** berarti port itu muncul di `https://$REPLIT_DEV_DOMAIN/` tanpa
   sufiks, satu app saja.
5. **Bawaan yang kelebihan** boleh dicabut: baris `[[ports]] localPort = 6800` ada supaya
   `sshd` bisa dijangkau saat tailnet putus. Kalau semua mesin sudah saling terhubung
   lewat tailnet (ssh lewat ProxyCommand SOCKS), port itu tidak wajib publik.

## Jebakan

- Entry `[[ports]]` tanpa `externalPort` tidak menyajikan apa pun (mis. 8319).
- Dua app di port sama: yang belakangan gagal bind, supervisor hanya mencatat
  `FAILED`.
- Port publik ke app yang butuh auth **wajib** punya token/header sendiri; edge tidak
  menambahkan lapisan auth apa pun.
