# Cers-Tunneling

Instalasi sekali perintah untuk men-setup layanan tunneling (Xray, SSH/WebSocket, HAProxy, Nginx) dengan kontrol izin berbasis GitHub.

![Alur instalasi](docs/flow.svg)

## Fitur utama
- **One-liner install**: `install.sh` mengunduh paket lengkap (`auto-tunnel.sh`, `tunnelctl.sh`, `allowed_ips.conf`) langsung dari GitHub dan menjalankan pemasangan.
- **Izin IP dari GitHub**: daftar IP sah dibaca otomatis dari `allowed_ips.conf` di repository ini sehingga hanya VPS terotorisasi yang dapat memakai script.
- **Verifikasi kode admin**: pengguna diminta kode izin pada instalasi pertama dan dicek ulang oleh `tunnelctl` sebelum operasi penting.
- **TLS siap pakai**: sertifikat ACME diterapkan untuk domain Xray lalu dipakai ulang oleh HAProxy/Nginx.
- **Menu operasional**: `tunnelctl` menyediakan pembuatan akun SSH, VMess, VLess, dan Trojan, termasuk setelan port dan firewall.

## Cara instalasi cepat
Jalankan sebagai root pada Ubuntu 20.04/22.04 atau Debian 11/12 (x86_64):

```bash
bash -c "$(command -v curl >/dev/null 2>&1 && echo 'curl -fsSL' || echo 'wget -qO-') https://raw.githubusercontent.com/Beni-glith/Cers-Tunneling/codex/fix-missing-sponge-command-error-2do11b/install.sh | bash"
```

`install.sh` akan:
1. Memastikan curl/wget terpasang.
2. Mengunduh skrip yang diperlukan dari GitHub.
3. Menjalankan `auto-tunnel.sh` untuk menyalin berkas ke sistem dan menyiapkan izin IP serta kode admin.

## Proses izin IP
- Daftar IP sah diambil dari `https://raw.githubusercontent.com/Cers-Tunneling/Cers-Tunneling/main/allowed_ips.conf`.
- Instalasi akan berhenti jika IP VPS tidak ada di daftar tersebut.
- URL daftar izin disimpan di `/etc/tunneling/settings.conf` sehingga `tunnelctl` dapat menyelaraskan ulang sebelum verifikasi IP.

## Menjalankan menu
Setelah instalasi sukses:

```bash
tunnelctl
```

Gunakan opsi *install* di menu untuk memprovisioning layanan (domain + SSL, HAProxy, Nginx, Xray, akun SSH/WS, dan setelan port bawaan).

## Pemecahan masalah
- Pastikan VPS Anda terdaftar pada `allowed_ips.conf`. Jika tidak, hubungi pemilik script.
- Jika sinkronisasi izin gagal, periksa koneksi internet lalu ulangi `tunnelctl --auto-backup` atau jalankan installer kembali.
- Jalankan perintah dengan hak root.
