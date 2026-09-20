#!/usr/bin/env bash
set -euo pipefail

RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YLW=$'\033[1;33m'
CYN=$'\033[0;36m'
NC=$'\033[0m'

log()  { printf "%s[*]%s %s\n" "$CYN" "$NC" "$*"; }
ok()   { printf "%s[+]%s %s\n" "$GRN" "$NC" "$*"; }
warn() { printf "%s[!]%s %s\n" "$YLW" "$NC" "$*"; }
die()  { printf "%s[x]%s %s\n" "$RED" "$NC" "$*" >&2; exit 1; }

BACKUP_BASE="${BACKUP_BASE:-/var/backups/xyr-tools}"

need_root() {
    [ "$(id -u)" -eq 0 ] || die "jalankan sebagai root"
}

detect_os() {
    [ -r /etc/os-release ] || die "tidak bisa baca /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
}

pkg_install() {
    detect_os
    case "$OS_ID" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y -o Dpkg::Options::="--force-confdef" \
                               -o Dpkg::Options::="--force-confold" "$@"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then dnf install -y "$@"
            else yum install -y "$@"; fi
            ;;
        *) die "OS $OS_ID belum disupport" ;;
    esac
}

svc_enable() {
    systemctl enable --now "$1" >/dev/null 2>&1 || systemctl enable "$1" >/dev/null 2>&1 || true
}

svc_restart() {
    systemctl restart "$1" 2>/dev/null || true
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

stamp() { date +%Y%m%d-%H%M%S; }

pause() {
    echo
    read -rp "enter buat lanjut..." _ || true
}

PTERO_DETECTED=""

detect_pterodactyl() {
    PTERO_DETECTED=""
    [ -d /var/www/pterodactyl ] && PTERO_DETECTED="${PTERO_DETECTED} panel"
    [ -d /var/lib/pterodactyl ] && PTERO_DETECTED="${PTERO_DETECTED} wings"
    [ -d /etc/pterodactyl ]     && PTERO_DETECTED="${PTERO_DETECTED} wings-config"
    PTERO_DETECTED="${PTERO_DETECTED# }"
}

dump_mysql_all() {
    local out="$1"
    if ! has_cmd mysqldump && ! has_cmd mariadb-dump; then
        warn "mysqldump gak ada, skip dump database"
        return 0
    fi

    local BIN
    if has_cmd mysqldump; then BIN=mysqldump; else BIN=mariadb-dump; fi

    local ENVFILE=/var/www/pterodactyl/.env
    local DB_USER="" DB_PASS="" DB_NAME=""

    if [ -r "$ENVFILE" ]; then
        DB_USER=$(grep -E '^DB_USERNAME=' "$ENVFILE" | cut -d= -f2- | tr -d '"' || true)
        DB_PASS=$(grep -E '^DB_PASSWORD=' "$ENVFILE" | cut -d= -f2- | tr -d '"' || true)
        DB_NAME=$(grep -E '^DB_DATABASE=' "$ENVFILE" | cut -d= -f2- | tr -d '"' || true)
    fi

    if [ -z "$DB_USER" ]; then
        read -rp "  user MySQL [root]: " DB_USER
        DB_USER="${DB_USER:-root}"
    fi

    if [ -z "${DB_PASS:-}" ]; then
        read -rsp "  password MySQL (kosongin kalau tanpa password): " DB_PASS
        echo
    fi

    if [ -z "${DB_NAME:-}" ]; then
        read -rp "  nama database Pterodactyl [panel]: " DB_NAME
        DB_NAME="${DB_NAME:-panel}"
    fi

    local AUTH=(-u"$DB_USER")
    [ -n "$DB_PASS" ] && AUTH+=(-p"$DB_PASS")

    log "dump semua database"
    if "$BIN" "${AUTH[@]}" --all-databases --single-transaction --quick \
            --routines --triggers --events \
            >"${out}/mysql-all.sql" 2>"${out}/mysql-all.err"; then
        ok "semua database tersimpan"
    else
        warn "dump --all-databases gagal, coba database ${DB_NAME} aja"
        rm -f "${out}/mysql-all.sql"
        if "$BIN" "${AUTH[@]}" --single-transaction --quick --routines --triggers \
                "$DB_NAME" >"${out}/mysql-${DB_NAME}.sql" 2>>"${out}/mysql-all.err"; then
            ok "database ${DB_NAME} tersimpan"
        else
            warn "dump gagal, cek ${out}/mysql-all.err"
        fi
    fi
}

backup_full() {
    need_root

    local STAMP OUT
    STAMP=$(stamp)
    OUT="${BACKUP_BASE}/full-${STAMP}"
    mkdir -p "$OUT"

    log "folder backup: $OUT"

    log "nyalin file sistem"
    rsync -aHAX --numeric-ids \
        --exclude=/dev/* \
        --exclude=/proc/* \
        --exclude=/sys/* \
        --exclude=/tmp/* \
        --exclude=/run/* \
        --exclude=/mnt/* \
        --exclude=/media/* \
        --exclude=/lost+found \
        --exclude=/var/lib/lxcfs/* \
        --exclude="${BACKUP_BASE}" \
        / "${OUT}/fs/"
    ok "file sistem tersalin"

    log "dump database"
    dump_mysql_all "$OUT"

    if [ -d /var/lib/pterodactyl ]; then
        log "arsip volume server game pterodactyl"
        tar --numeric-owner -cpf "${OUT}/pterodactyl-volumes.tar" \
            -C /var/lib/pterodactyl volumes 2>/dev/null || true
    fi

    if has_cmd docker; then
        log "arsip docker images"
        local imgs
        imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true)
        if [ -n "$imgs" ]; then
            # shellcheck disable=SC2086
            docker save $imgs -o "${OUT}/docker-images.tar" 2>/dev/null || true
        fi
    fi

    log "catat metadata"
    {
        echo "generated: $(date -Is)"
        echo "hostname:  $(hostname)"
        echo "os:        $(. /etc/os-release; echo "$PRETTY_NAME")"
        echo "kernel:    $(uname -r)"
        echo "ip:        $(hostname -I 2>/dev/null || true)"
    } >"${OUT}/metadata.txt"

    ip addr show >"${OUT}/network.txt" 2>/dev/null || true
    df -h >"${OUT}/disk.txt" 2>/dev/null || true
    systemctl list-units --type=service --state=running --no-pager \
        >"${OUT}/services.txt" 2>/dev/null || true
    crontab -l >"${OUT}/crontab-root.txt" 2>/dev/null || true
    [ -d /etc/pterodactyl ] && cp -a /etc/pterodactyl "${OUT}/pterodactyl-config" 2>/dev/null || true

    ok "metadata tersimpan"

    log "kompres arsip, sabar ya"
    local ARCHIVE
    if has_cmd zstd; then
        ARCHIVE="${BACKUP_BASE}/backup-full-${STAMP}.tar.zst"
        tar -C "$(dirname "$OUT")" -cf - "$(basename "$OUT")" | zstd -T0 -10 -o "$ARCHIVE"
    else
        ARCHIVE="${BACKUP_BASE}/backup-full-${STAMP}.tar.gz"
        tar -C "$(dirname "$OUT")" -czf "$ARCHIVE" "$(basename "$OUT")"
    fi

    rm -rf "$OUT"

    ok "backup kelar"
    echo "  arsip : $ARCHIVE"
    echo "  ukuran: $(du -h "$ARCHIVE" | cut -f1)"
}

backup_pterodactyl() {
    need_root
    detect_pterodactyl

    if [ -z "$PTERO_DETECTED" ]; then
        warn "pterodactyl gak kedeteksi di server ini"
        return 0
    fi

    echo
    echo "  kedeteksi: ${PTERO_DETECTED}"
    echo

    local STAMP OUT
    STAMP=$(stamp)
    OUT="${BACKUP_BASE}/pterodactyl-${STAMP}"
    mkdir -p "$OUT"

    if [ -d /var/www/pterodactyl ]; then
        log "backup panel"
        rsync -aHAX --numeric-ids /var/www/pterodactyl/ "${OUT}/panel/"
        ok "panel tersalin"
    fi

    if [ -d /etc/pterodactyl ]; then
        log "backup config wings"
        cp -a /etc/pterodactyl "${OUT}/wings-config"
        ok "config wings tersalin"
    fi

    if [ -d /var/lib/pterodactyl/volumes ]; then
        log "backup volume server game"
        tar --numeric-owner -cpf "${OUT}/volumes.tar" \
            -C /var/lib/pterodactyl volumes 2>/dev/null || warn "gak ada volume"
        ok "volumes tersalin"
    fi

    log "dump database"
    dump_mysql_all "$OUT"

    log "cek service pterodactyl"
    {
        for s in wings pterodactyl-queue pteroq nginx; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${s}"; then
                echo "${s}: $(systemctl is-active "$s" 2>/dev/null || echo unknown)"
            fi
        done
    } >"${OUT}/services.txt"
    cat "${OUT}/services.txt"

    log "kompres arsip"
    local ARCHIVE
    if has_cmd zstd; then
        ARCHIVE="${BACKUP_BASE}/backup-pterodactyl-${STAMP}.tar.zst"
        tar -C "$(dirname "$OUT")" -cf - "$(basename "$OUT")" | zstd -T0 -6 -o "$ARCHIVE"
    else
        ARCHIVE="${BACKUP_BASE}/backup-pterodactyl-${STAMP}.tar.gz"
        tar -C "$(dirname "$OUT")" -czf "$ARCHIVE" "$(basename "$OUT")"
    fi

    rm -rf "$OUT"

    ok "backup pterodactyl kelar"
    echo "  arsip : $ARCHIVE"
    echo "  ukuran: $(du -h "$ARCHIVE" | cut -f1)"
}

restore_pterodactyl() {
    need_root
    echo
    read -rp "  path arsip backup: " ARCHIVE
    [ -f "$ARCHIVE" ] || die "file gak ketemu: $ARCHIVE"

    local TMP
    TMP=$(mktemp -d)

    log "ekstrak ke $TMP"
    case "$ARCHIVE" in
        *.tar.zst) has_cmd zstd || pkg_install zstd; tar --zstd -xf "$ARCHIVE" -C "$TMP" ;;
        *.tar.gz)  tar -xzf "$ARCHIVE" -C "$TMP" ;;
        *)         die "format arsip gak dikenali" ;;
    esac

    local SRC
    SRC=$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -n1)
    [ -n "$SRC" ] || die "isi arsip gak valid"

    echo
    warn "restore bakal nimpa /var/www/pterodactyl, /etc/pterodactyl, /var/lib/pterodactyl"
    read -rp "lanjut? ketik YES: " CONF
    [ "$CONF" = "YES" ] || { rm -rf "$TMP"; warn "dibatalkan"; return 0; }

    if [ -d "${SRC}/panel" ]; then
        log "restore panel"
        mkdir -p /var/www/pterodactyl
        rsync -aHAX --numeric-ids "${SRC}/panel/" /var/www/pterodactyl/
        chown -R www-data:www-data /var/www/pterodactyl 2>/dev/null || true
        ok "panel restored"
    fi

    if [ -d "${SRC}/wings-config" ]; then
        log "restore config wings"
        mkdir -p /etc/pterodactyl
        rsync -aHAX --numeric-ids "${SRC}/wings-config/" /etc/pterodactyl/
        ok "config wings restored"
    fi

    if [ -f "${SRC}/volumes.tar" ]; then
        log "restore volume server game"
        mkdir -p /var/lib/pterodactyl
        tar --numeric-owner -xpf "${SRC}/volumes.tar" -C /var/lib/pterodactyl/
        ok "volumes restored"
    fi

    local SQL
    SQL=$(find "$SRC" -maxdepth 1 -name 'mysql-*.sql' | head -n1 || true)
    if [ -n "$SQL" ]; then
        read -rp "  restore database dari ${SQL##*/}? ketik YES: " YN
        if [ "$YN" = "YES" ]; then
            read -rp "  user MySQL [root]: " DB_USER; DB_USER="${DB_USER:-root}"
            read -rsp "  password MySQL: " DB_PASS; echo
            local AUTH=(-u"$DB_USER")
            [ -n "$DB_PASS" ] && AUTH+=(-p"$DB_PASS")
            if has_cmd mysql; then mysql "${AUTH[@]}" <"$SQL"
            else mariadb "${AUTH[@]}" <"$SQL"; fi
            ok "database restored"
        fi
    fi

    rm -rf "$TMP"

    log "restart service"
    for s in wings nginx pterodactyl-queue pteroq php8.1-fpm php8.2-fpm php8.3-fpm; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${s}" && svc_restart "$s" || true
    done

    ok "restore kelar"
    warn "kalau wings pakai TLS, cek /etc/pterodactyl/config.yml"
}

list_backups() {
    if [ ! -d "$BACKUP_BASE" ]; then
        warn "belum ada backup di $BACKUP_BASE"
        return 0
    fi
    echo
    echo "  lokasi: $BACKUP_BASE"
    echo
    ls -lh "$BACKUP_BASE" 2>/dev/null | awk 'NR>1 {printf "  %-45s %8s  %s %s %s\n", $9, $5, $6, $7, $8}'
}

migrate() {
    need_root
    has_cmd rsync || pkg_install rsync

    echo
    log "konfigurasi VPS sumber"
    read -rp "  IP / hostname  : " SRC_HOST
    read -rp "  port SSH [22]  : " SRC_PORT; SRC_PORT="${SRC_PORT:-22}"
    read -rp "  user SSH [root]: " SRC_USER; SRC_USER="${SRC_USER:-root}"

    [ -n "${SRC_HOST:-}" ] || die "host sumber gak boleh kosong"

    log "test koneksi ssh"
    if ! ssh -p "$SRC_PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
             "${SRC_USER}@${SRC_HOST}" true; then
        die "ssh ke sumber gagal"
    fi
    ok "koneksi ssh ok"

    echo
    warn "proses ini bakal nimpa file di VPS ini sesuai isi VPS sumber"
    read -rp "lanjut? ketik YES: " CONF
    [ "$CONF" = "YES" ] || { warn "dibatalkan"; return 0; }

    local EXCLUDES=(
        "--exclude=/dev/*"
        "--exclude=/proc/*"
        "--exclude=/sys/*"
        "--exclude=/tmp/*"
        "--exclude=/run/*"
        "--exclude=/mnt/*"
        "--exclude=/media/*"
        "--exclude=/lost+found"
        "--exclude=/swapfile"
        "--exclude=/etc/fstab"
        "--exclude=/etc/mtab"
        "--exclude=/etc/resolv.conf"
        "--exclude=/etc/netplan/*"
        "--exclude=/etc/network/interfaces"
        "--exclude=/boot/grub/*"
        "--exclude=${BACKUP_BASE}"
    )

    log "mulai rsync, bisa lama"
    rsync -aHAXxvz --numeric-ids --delete --stats \
        -e "ssh -p ${SRC_PORT} -o StrictHostKeyChecking=accept-new" \
        "${EXCLUDES[@]}" \
        "${SRC_USER}@${SRC_HOST}:/" /

    ok "sinkronisasi file kelar"
    warn "jangan reboot dulu, cek fstab, netplan, sama sshd_config"
}

security() {
    need_root
    detect_os

    case "$OS_ID" in
        ubuntu|debian)
            pkg_install ufw iptables iptables-persistent fail2ban
            ;;
        centos|rhel|rocky|almalinux|fedora)
            pkg_install ufw iptables-services fail2ban
            ;;
        *) die "OS $OS_ID belum disupport" ;;
    esac

    read -rp "SSH port yang dipakai [22]: " SSH_PORT
    SSH_PORT="${SSH_PORT:-22}"

    log "setup ufw"
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow "${SSH_PORT}/tcp" >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 8080/tcp >/dev/null
    ufw allow 2022/tcp >/dev/null
    ufw --force enable >/dev/null

    log "setup iptables"
    iptables -F
    iptables -X
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
    iptables -A INPUT -p tcp --dport 2022 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
    iptables -A INPUT -p tcp --syn -m limit --limit 25/s --limit-burst 50 -j ACCEPT
    iptables -A INPUT -p tcp --syn -j DROP
    iptables -A INPUT -f -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP

    log "tulis sysctl hardening"
    cat >/etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
EOF
    sysctl --system >/dev/null

    log "setup fail2ban"
    mkdir -p /etc/fail2ban
    cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

    svc_enable fail2ban
    svc_restart fail2ban

    log "simpan rules iptables"
    case "$OS_ID" in
        ubuntu|debian)
            mkdir -p /etc/iptables
            iptables-save >/etc/iptables/rules.v4
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if service iptables save >/dev/null 2>&1; then :; fi
            iptables-save >/etc/sysconfig/iptables
            svc_enable iptables
            ;;
    esac

    echo
    ok "hardening kelar"
    echo "  ufw        : $(ufw status | head -n1)"
    echo "  fail2ban   : $(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
    echo "  syncookies : $(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo unknown)"
}

status_all() {
    echo
    echo "--- ufw ---"
    if has_cmd ufw; then ufw status verbose 2>/dev/null | head -n 20
    else echo "  gak terpasang"; fi

    echo
    echo "--- iptables ---"
    if has_cmd iptables; then iptables -L -n --line-numbers 2>/dev/null | head -n 25
    else echo "  gak terpasang"; fi

    echo
    echo "--- fail2ban ---"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        systemctl status fail2ban --no-pager 2>/dev/null | head -n 12
    else echo "  gak aktif"; fi

    echo
    echo "--- syncookies ---"
    sysctl net.ipv4.tcp_syncookies 2>/dev/null || echo "  gak tersedia"

    echo
    echo "--- pterodactyl ---"
    detect_pterodactyl
    if [ -n "$PTERO_DETECTED" ]; then
        echo "  komponen: ${PTERO_DETECTED}"
        for s in wings nginx pterodactyl-queue pteroq; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${s}"; then
                echo "  ${s}: $(systemctl is-active "$s" 2>/dev/null || echo unknown)"
            fi
        done
    else
        echo "  gak terdeteksi"
    fi
}

menu() {
    while true; do
        echo " ----- xyrTools -----"
        echo " -- udah lama lupa push:v --"
        echo "  1) Backup full VPS"
        echo "  2) Backup Pterodactyl"
        echo "  3) Restore Pterodactyl"
        echo "  4) List backup"
        echo "  5) Migrasi VPS"
        echo "  6) Hardening (ufw/iptables/fail2ban)"
        echo "  7) Status layanan"
        echo "  0) Keluar"        
        read -rp "pilih: " CH

        case "$CH" in
            1) backup_full;          pause ;;
            2) backup_pterodactyl;   pause ;;
            3) restore_pterodactyl;  pause ;;
            4) list_backups;         pause ;;
            5) migrate;              pause ;;
            6) security;             pause ;;
            7) status_all;           pause ;;
            0|q|quit) exit 0 ;;
            *) warn "pilihan gak valid"; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    backup)        backup_full ;;
    backup-ptero)  backup_pterodactyl ;;
    restore-ptero) restore_pterodactyl ;;
    list)          list_backups ;;
    migrate)       migrate ;;
    security)      security ;;
    status)        status_all ;;
    ""|menu)       menu ;;
    *) die "aksi gak dikenal: $1" ;;
esac
