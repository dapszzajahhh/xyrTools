# xyr-tools

Bash script buat ngurusin VPS dari terminal. Bisa backup full server, backup Pterodactyl, restore panel, pindah server ke VPS baru, sama hardening firewall.

Cuma satu file bash. Gak butuh Python atau dependency aneh-aneh.

## Fitur

- Backup full VPS - filesystem, database, volume Pterodactyl, docker images, metadata
- Backup khusus Pterodactyl - panel, wings, volume server game, database
- Restore Pterodactyl dari arsip backup
- Migrasi VPS ke VPS pakai rsync-over-SSH
- Hardening: UFW + iptables (anti SYN flood) + fail2ban + sysctl syncookies
- Menu CLI simpel, tinggal pilih angka

## Install

Login ke VPS sebagai root, terus:

```bash
mkdir -p /root/xyr-tools
cd /root/xyr-tools
```

Bikin file `xyr-tools.sh`, isi pakai script di atas. Bisa pakai `nano`:

```bash
nano xyr-tools.sh
```

Paste isinya, `Ctrl+O` `Enter` `Ctrl+X`. Terus:

```bash
chmod +x xyr-tools.sh
./xyr-tools.sh
```

Kalau mau akses dari mana aja:

```bash
ln -sf /root/xyr-tools/xyr-tools.sh /usr/local/bin/xyr-tools
```

Sekarang bisa jalanin `xyr-tools` dari folder manapun.

## Menu

```
  1) Backup full VPS
  2) Backup Pterodactyl
  3) Restore Pterodactyl
  4) List backup
  5) Migrasi VPS
  6) Hardening
  7) Status layanan
  0) Keluar
```

Bisa juga langsung panggil tanpa masuk menu:

```bash
./xyr-tools.sh backup
./xyr-tools.sh backup-ptero
./xyr-tools.sh restore-ptero
./xyr-tools.sh list
./xyr-tools.sh migrate
./xyr-tools.sh security
./xyr-tools.sh status
```

Cocok buat cron job.

## Backup

Arsip default disimpan di `/var/backups/xyr-tools/`. Mau ganti lokasi (misal ke disk eksternal), set env waktu jalanin:

```bash
BACKUP_BASE=/mnt/backup ./xyr-tools.sh
```

Atau bikin alias permanen di `.bashrc`:

```bash
echo 'export BACKUP_BASE=/mnt/backup' >> ~/.bashrc
```

### Backup full VPS (menu 1)

Yang diambil:

- Seluruh filesystem (`/`) pakai rsync `-aHAX` - permission, ACL, extended attribute kejaga
- Dump semua database MySQL/MariaDB
- Volume server game Pterodactyl
- Docker images (kalau ada docker)
- Metadata: hostname, OS, kernel, IP, daftar service, cron, config network, config wings

Yang di-skip: `/dev`, `/proc`, `/sys`, `/tmp`, `/run`, `/mnt`, `/media`, `/lost+found`, `/var/lib/lxcfs`, plus folder backup-nya sendiri biar gak rekursif.

Hasilnya satu file `.tar.zst`. Kalau `zstd` gak ada, fallback ke `.tar.gz`.

Kalau server punya Pterodactyl, kredensial MySQL bakal dibaca otomatis dari `/var/www/pterodactyl/.env`. Kalau gak ada, bakal ditanya manual.

Butuh disk kosong kira-kira 2x ukuran data yang di-backup, karena proses bikin folder staging dulu sebelum dikompres.

### Backup Pterodactyl (menu 2)

Lebih cepet dari full backup, cuma ambil yang perlu:

- `/var/www/pterodactyl` - kode panel, `.env`, config
- `/etc/pterodactyl` - config wings
- `/var/lib/pterodactyl/volumes` - data server game
- Semua database MySQL

Kalau cuma mau panel doang dan gak butuh volume game, skip aja foldernya sebelum backup, atau edit scriptnya.

### Restore Pterodactyl (menu 3)

Masukin path arsip, script bakal:

1. Ekstrak ke temp folder
2. Tanya konfirmasi (`YES`)
3. Copy balik ke `/var/www/pterodactyl`, `/etc/pterodactyl`, `/var/lib/pterodactyl`
4. Set ownership ke `www-data`
5. Tanya apakah mau restore database
6. Restart wings, nginx, queue worker, php-fpm

Sesudah restore, kalau IP VPS berubah, edit `/etc/pterodactyl/config.yml` dulu sebelum restart wings.

## Migrasi VPS (menu 5)

Jalanin di **VPS tujuan**. Script narik data dari **VPS sumber** lewat rsync-over-SSH.

Yang perlu disiapin di VPS sumber:

1. SSH key dari VPS tujuan udah ke-pasang. Kalau belum, di VPS tujuan:

```bash
ssh-keygen -t ed25519
ssh-copy-id -p PORT user@VPS-SUMBER
```

2. `rsync` terinstall di kedua VPS. Script yang install kalau belum ada.

Terus masuk menu 5, isi IP VPS sumber, port SSH, user SSH. Ketik `YES` buat konfirmasi.

Yang di-exclude biar aman (gak nimpa config VPS tujuan):

- `/dev`, `/proc`, `/sys`, `/tmp`, `/run`, `/mnt`, `/media`, `/lost+found`, `/swapfile`
- `/boot/grub` - kernel target beda, jangan sampai ketimpa
- `/etc/fstab`, `/etc/mtab`, `/etc/resolv.conf`
- `/etc/netplan/*`, `/etc/network/interfaces` - biar network VPS tujuan gak putus

**Setelah migrasi selesai, JANGAN langsung reboot.** Cek dulu satu-satu:

1. `/etc/fstab` - cocokin UUID partisi pakai `blkid`
2. `/etc/ssh/sshd_config` - cocokin port dan metode auth
3. `/etc/netplan/*` atau `/etc/network/interfaces` - sesuaikan nama interface dan IP
4. Buka sesi SSH baru ke VPS tujuan, mastiin login masih bisa
5. Baru reboot

Kalau pakai Docker atau wings, service perlu di-restart manual karena state di memory gak ikut ke-copy.

## Hardening (menu 6)

Install `ufw`, `iptables`, `fail2ban` terus konfigurasi:

- **UFW**: deny incoming default. Port yang dibuka: SSH, 80, 443, 8080 (wings), 2022 (wings SFTP). Kalau gak pakai Pterodactyl, edit sendiri di scriptnya
- **iptables**: SYN flood protection, drop fragmented packet, drop TCP flag invalid, ICMP rate limit
- **sysctl**: `net.ipv4.tcp_syncookies = 1` plus tweak rp_filter dan redirect
- **fail2ban**: jail `sshd`, maxretry 5, bantime 1 jam

Port SSH bisa diganti waktu setup. **Pastiin bener**, salah port = ke-lock sendiri.

Rules iptables disave ke `/etc/iptables/rules.v4` (Debian family) atau `/etc/sysconfig/iptables` (RHEL family), jadi tetep ada setelah reboot.

### Kalau ke-lock SSH

Masuk lewat console recovery VPS dari panel provider (biasanya VNC atau web console). Terus:

```bash
ufw disable
iptables -F
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
```

Baru benerin confignya pelan-pelan.

## Status (menu 7)

Nampilin status ufw, list rule iptables, status fail2ban, nilai syncookies, sama service Pterodactyl yang aktif. Berguna buat mastiin hardening masih nyala atau udah ke-reset sama reboot.

## Catatan Pterodactyl

Beberapa hal yang sering bikin bingung:

- Database panel defaultnya bernama `panel`. Kalau di-install pakai nama lain, ubah lewat prompt waktu backup
- Volume server game bisa gede banget. `/var/lib/pterodactyl/volumes` kadang puluhan GB. Backup makan waktu dan disk
- Panel dan wings biasanya di VPS beda. Kalau cuma wings doang di VPS ini, script tetep deteksi kok, menu 2 bakal skip bagian panel
- SSL Let's Encrypt ada di `/etc/letsencrypt`, ikut ke-backup di full backup. Restore ke VPS dengan domain beda perlu re-issue cert pakai `certbot`
- Wings pakai TLS cert sendiri di `/etc/pterodactyl`. Kalau IP berubah, cert-nya perlu re-generate: `cd /etc/pterodactyl && wings --auto-tls`

## Yang disupport

- Ubuntu 20.04+
- Debian 11+
- CentOS 7+, Rocky, AlmaLinux, Fedora

Tested di Ubuntu 22.04 dan Debian 12. Kalau ada error di distro lain, biasanya cuma beda nama package atau path config.

## Yang dibutuhin

- Bash 4+
- `rsync` (diinstall otomatis kalau belum ada)
- `tar`
- `zstd` (opsional, buat kompresi lebih cepet - fallback ke gzip kalau gak ada)
- `mysqldump` atau `mariadb-dump` (cuma kalau mau backup database)
- `docker` (opsional, cuma dipakai kalau ada)

## Lisensi

MIT. Pakai, ubah, sebar, terserah.

## Disclaimer

Backup sama migrasi itu operasi yang berisiko. Test dulu di VM lokal kalau bisa sebelum dipakai di server production. Author gak tanggung jawab kalau ada data yang ilang atau server yang rusak.

---

Kalau nemu bug atau punya request, buka issue aja.