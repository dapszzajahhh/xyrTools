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
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

stamp() {
    date +%Y%m%d-%H%M%S
}

pause() {
    echo
    read -rp "enter buat lanjut..." _ || true
}

confirm_yes() {
    local ANSWER
    read -rp "$1 ketik YES: " ANSWER
    [ "$ANSWER" = "YES" ]
}

pkg_install() {
    detect_os

    case "$OS_ID" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                "$@"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if has_cmd dnf; then
                dnf install -y "$@"
            elif has_cmd yum; then
                yum install -y "$@"
            else
                die "package manager tidak ditemukan"
            fi
            ;;
        *)
            die "OS $OS_ID belum disupport"
            ;;
    esac
}

ensure_cmd() {
    local CMD="$1"
    local PKG="${2:-$1}"

    if ! has_cmd "$CMD"; then
        warn "$CMD belum terpasang"
        log "install $PKG"
        pkg_install "$PKG"
    fi
}

svc_enable() {
    local SERVICE="$1"

    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}"; then
        warn "service $SERVICE tidak ditemukan"
        return 1
    fi

    if systemctl enable --now "$SERVICE" >/dev/null 2>&1; then
        ok "$SERVICE aktif"
        return 0
    fi

    warn "$SERVICE gagal diaktifkan"
    return 1
}

svc_restart() {
    local SERVICE="$1"

    if systemctl restart "$SERVICE" >/dev/null 2>&1; then
        ok "$SERVICE berhasil restart"
        return 0
    fi

    warn "$SERVICE gagal restart"
    return 1
}

PTERO_DETECTED=""

detect_pterodactyl() {
    PTERO_DETECTED=""

    [ -d /var/www/pterodactyl ] &&
        PTERO_DETECTED="${PTERO_DETECTED} panel"

    [ -d /var/lib/pterodactyl ] &&
        PTERO_DETECTED="${PTERO_DETECTED} wings"

    [ -d /etc/pterodactyl ] &&
        PTERO_DETECTED="${PTERO_DETECTED} wings-config"

    PTERO_DETECTED="${PTERO_DETECTED# }"
}

read_ptero_db() {
    local ENVFILE="/var/www/pterodactyl/.env"

    DB_USER=""
    DB_PASS=""
    DB_NAME=""

    if [ -r "$ENVFILE" ]; then
        DB_USER=$(grep -E '^DB_USERNAME=' "$ENVFILE" | cut -d= -f2- | tr -d '"' || true)
        DB_PASS=$(grep -E '^DB_PASSWORD=' "$ENVFILE" | cut -d= -f2- | tr -d '"' || true)
        DB_NAME=$(grep -E '^DB_DATABASE=' "$ENVFILE" | cut -d= -f2- | tr -d '"' || true)
    fi
}

dump_mysql_all() {
    local OUT="$1"

    if ! has_cmd mysqldump && ! has_cmd mariadb-dump; then
        warn "mysqldump/mariadb-dump tidak ditemukan"
        return 1
    fi

    local BIN

    if has_cmd mysqldump; then
        BIN="mysqldump"
    else
        BIN="mariadb-dump"
    fi

    read_ptero_db

    if [ -z "$DB_USER" ]; then
        read -rp "  user MySQL [root]: " DB_USER
        DB_USER="${DB_USER:-root}"
    fi

    if [ -z "${DB_PASS:-}" ]; then
        read -rsp "  password MySQL (kosongkan jika tanpa password): " DB_PASS
        echo
    fi

    if [ -z "${DB_NAME:-}" ]; then
        read -rp "  nama database Pterodactyl [panel]: " DB_NAME
        DB_NAME="${DB_NAME:-panel}"
    fi

    local AUTH=(-u"$DB_USER")

    if [ -n "$DB_PASS" ]; then
        AUTH+=(-p"$DB_PASS")
    fi

    log "dump semua database"

    if "$BIN" "${AUTH[@]}" \
        --all-databases \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        >"${OUT}/mysql-all.sql" \
        2>"${OUT}/mysql-all.err"; then

        ok "semua database tersimpan"
        echo "database: ALL" >"${OUT}/database-status.txt"
        return 0
    fi

    warn "dump semua database gagal"

    rm -f "${OUT}/mysql-all.sql"

    log "mencoba database ${DB_NAME}"

    if "$BIN" "${AUTH[@]}" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        "$DB_NAME" \
        >"${OUT}/mysql-${DB_NAME}.sql" \
        2>>"${OUT}/mysql-all.err"; then

        ok "database ${DB_NAME} tersimpan"
        echo "database: ${DB_NAME}" >"${OUT}/database-status.txt"
        return 0
    fi

    warn "backup database gagal"
    echo "database: FAILED" >"${OUT}/database-status.txt"

    return 1
}

create_checksum() {
    local ARCHIVE="$1"

    if has_cmd sha256sum; then
        sha256sum "$ARCHIVE" >"${ARCHIVE}.sha256"
        ok "checksum SHA-256 dibuat"
    else
        warn "sha256sum tidak tersedia"
    fi
}

verify_checksum() {
    local ARCHIVE="$1"

    if [ ! -f "${ARCHIVE}.sha256" ]; then
        warn "file checksum tidak ditemukan"
        return 0
    fi

    if sha256sum -c "${ARCHIVE}.sha256" >/dev/null 2>&1; then
        ok "checksum archive valid"
        return 0
    fi

    die "checksum archive TIDAK VALID"
}

write_metadata() {
    local OUT="$1"

    {
        echo "generated: $(date -Is)"
        echo "hostname:  $(hostname)"
        echo "os:        $OS_NAME"
        echo "kernel:    $(uname -r)"
        echo "ip:        $(hostname -I 2>/dev/null || true)"
        echo "arch:      $(uname -m)"
    } >"${OUT}/metadata.txt"

    ip addr show >"${OUT}/network.txt" 2>/dev/null || true
    df -h >"${OUT}/disk.txt" 2>/dev/null || true

    systemctl list-units \
        --type=service \
        --state=running \
        --no-pager \
        >"${OUT}/services.txt" 2>/dev/null || true

    crontab -l >"${OUT}/crontab-root.txt" 2>/dev/null || true

    if [ -d /etc/pterodactyl ]; then
        cp -a /etc/pterodactyl \
            "${OUT}/pterodactyl-config" \
            2>/dev/null || true
    fi
}

backup_full() {
    need_root
    detect_os

    ensure_cmd rsync rsync
    ensure_cmd tar tar

    mkdir -p "$BACKUP_BASE"

    local STAMP OUT ARCHIVE
    STAMP=$(stamp)
    OUT="${BACKUP_BASE}/full-${STAMP}"

    mkdir -p "$OUT"

    trap 'rm -rf "$OUT"' RETURN

    log "folder backup: $OUT"

    log "menyalin file sistem"

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

    log "backup database"

    if dump_mysql_all "$OUT"; then
        echo "database_status=OK" >"${OUT}/backup-status.txt"
    else
        echo "database_status=FAILED" >"${OUT}/backup-status.txt"
        warn "backup tetap dilanjutkan, tetapi database gagal"
    fi

    if [ -d /var/lib/pterodactyl/volumes ]; then
        log "backup volume Pterodactyl"

        if tar --numeric-owner \
            -cpf "${OUT}/pterodactyl-volumes.tar" \
            -C /var/lib/pterodactyl \
            volumes; then

            ok "volume Pterodactyl tersimpan"
        else
            warn "backup volume Pterodactyl gagal"
        fi
    fi

    if has_cmd docker; then
        log "backup Docker images"

        mapfile -t IMAGES < <(
            docker images \
                --format '{{.Repository}}:{{.Tag}}' |
            grep -v '<none>' || true
        )

        if [ "${#IMAGES[@]}" -gt 0 ]; then
            if docker save \
                "${IMAGES[@]}" \
                -o "${OUT}/docker-images.tar"; then

                ok "Docker images tersimpan"
            else
                warn "backup Docker images gagal"
            fi
        else
            warn "tidak ada Docker image"
        fi
    fi

    write_metadata "$OUT"

    ok "metadata tersimpan"

    log "membuat archive"

    if has_cmd zstd; then
        ARCHIVE="${BACKUP_BASE}/backup-full-${STAMP}.tar.zst"

        tar -C "$(dirname "$OUT")" \
            -cf - \
            "$(basename "$OUT")" |
            zstd -T0 -10 -o "$ARCHIVE"
    else
        ARCHIVE="${BACKUP_BASE}/backup-full-${STAMP}.tar.gz"

        tar -C "$(dirname "$OUT")" \
            -czf "$ARCHIVE" \
            "$(basename "$OUT")"
    fi

    rm -rf "$OUT"
    trap - RETURN

    create_checksum "$ARCHIVE"

    ok "backup full VPS selesai"
    echo
    echo "  archive : $ARCHIVE"
    echo "  ukuran  : $(du -h "$ARCHIVE" | cut -f1)"
    echo "  checksum: ${ARCHIVE}.sha256"
}

backup_pterodactyl() {
    need_root

    detect_pterodactyl

    [ -n "$PTERO_DETECTED" ] ||
        die "Pterodactyl tidak terdeteksi"

    mkdir -p "$BACKUP_BASE"

    echo
    echo "  terdeteksi: $PTERO_DETECTED"
    echo

    local STAMP OUT ARCHIVE
    STAMP=$(stamp)
    OUT="${BACKUP_BASE}/pterodactyl-${STAMP}"

    mkdir -p "$OUT"

    trap 'rm -rf "$OUT"' RETURN

    if [ -d /var/www/pterodactyl ]; then
        log "backup panel"

        rsync -aHAX --numeric-ids \
            /var/www/pterodactyl/ \
            "${OUT}/panel/"

        ok "panel tersimpan"
    fi

    if [ -d /etc/pterodactyl ]; then
        log "backup config Wings"

        cp -a /etc/pterodactyl \
            "${OUT}/wings-config"

        ok "config Wings tersimpan"
    fi

    if [ -d /var/lib/pterodactyl/volumes ]; then
        log "backup volume game"

        if tar --numeric-owner \
            -cpf "${OUT}/volumes.tar" \
            -C /var/lib/pterodactyl \
            volumes; then

            ok "volume tersimpan"
        else
            warn "backup volume gagal"
        fi
    fi

    log "backup database"

    if dump_mysql_all "$OUT"; then
        echo "database_status=OK" >"${OUT}/backup-status.txt"
    else
        echo "database_status=FAILED" >"${OUT}/backup-status.txt"
        warn "database gagal dibackup"
    fi

    {
        for SVC in wings pterodactyl-queue pteroq nginx; do
            if systemctl list-unit-files 2>/dev/null |
                grep -q "^${SVC}"; then

                echo "${SVC}: $(systemctl is-active "$SVC" 2>/dev/null || echo unknown)"
            fi
        done
    } >"${OUT}/services.txt"

    log "membuat archive"

    if has_cmd zstd; then
        ARCHIVE="${BACKUP_BASE}/backup-pterodactyl-${STAMP}.tar.zst"

        tar -C "$(dirname "$OUT")" \
            -cf - \
            "$(basename "$OUT")" |
            zstd -T0 -6 -o "$ARCHIVE"
    else
        ARCHIVE="${BACKUP_BASE}/backup-pterodactyl-${STAMP}.tar.gz"

        tar -C "$(dirname "$OUT")" \
            -czf "$ARCHIVE" \
            "$(basename "$OUT")"
    fi

    rm -rf "$OUT"
    trap - RETURN

    create_checksum "$ARCHIVE"

    ok "backup Pterodactyl selesai"

    echo
    echo "  archive : $ARCHIVE"
    echo "  ukuran  : $(du -h "$ARCHIVE" | cut -f1)"
}

restore_pterodactyl() {
    need_root

    echo
    read -rp "  path archive backup: " ARCHIVE

    [ -f "$ARCHIVE" ] ||
        die "file tidak ditemukan: $ARCHIVE"

    verify_checksum "$ARCHIVE"

    local TMP
    TMP=$(mktemp -d)

    trap 'rm -rf "$TMP"' RETURN

    log "validasi dan ekstrak archive"

    case "$ARCHIVE" in
        *.tar.zst)
            ensure_cmd zstd zstd
            tar --zstd -tf "$ARCHIVE" >/dev/null
            tar --zstd -xf "$ARCHIVE" -C "$TMP"
            ;;
        *.tar.gz)
            tar -tzf "$ARCHIVE" >/dev/null
            tar -xzf "$ARCHIVE" -C "$TMP"
            ;;
        *)
            die "format archive tidak dikenali"
            ;;
    esac

    local SRC
    SRC=$(find "$TMP" \
        -maxdepth 1 \
        -mindepth 1 \
        -type d |
        head -n1)

    [ -n "$SRC" ] ||
        die "isi archive tidak valid"

    ok "archive valid"

    echo
    warn "restore akan mengubah:"
    echo "  /var/www/pterodactyl"
    echo "  /etc/pterodactyl"
    echo "  /var/lib/pterodactyl"
    echo

    confirm_yes "lanjut restore?" ||
        {
            warn "restore dibatalkan"
            return 0
        }

    if [ -d "${SRC}/panel" ]; then
        log "restore panel"

        mkdir -p /var/www/pterodactyl

        rsync -aHAX --numeric-ids \
            "${SRC}/panel/" \
            /var/www/pterodactyl/

        chown -R www-data:www-data \
            /var/www/pterodactyl \
            2>/dev/null || true

        ok "panel restored"
    fi

    if [ -d "${SRC}/wings-config" ]; then
        log "restore config Wings"

        mkdir -p /etc/pterodactyl

        rsync -aHAX --numeric-ids \
            "${SRC}/wings-config/" \
            /etc/pterodactyl/

        ok "config Wings restored"
    fi

    if [ -f "${SRC}/volumes.tar" ]; then
        log "restore volume"

        mkdir -p /var/lib/pterodactyl

        tar --numeric-owner \
            -xpf "${SRC}/volumes.tar" \
            -C /var/lib/pterodactyl/

        ok "volume restored"
    fi

    local SQL=""
    SQL=$(find "$SRC" \
        -maxdepth 1 \
        -name 'mysql-*.sql' |
        head -n1 || true)

    if [ -n "$SQL" ]; then
        echo
        if confirm_yes "restore database ${SQL##*/}?"; then

            read -rp "  user MySQL [root]: " DB_USER
            DB_USER="${DB_USER:-root}"

            read -rsp "  password MySQL: " DB_PASS
            echo

            local AUTH=(-u"$DB_USER")

            [ -n "$DB_PASS" ] &&
                AUTH+=(-p"$DB_PASS")

            if has_cmd mysql; then
                mysql "${AUTH[@]}" <"$SQL"
            elif has_cmd mariadb; then
                mariadb "${AUTH[@]}" <"$SQL"
            else
                warn "mysql/mariadb tidak ditemukan"
            fi

            ok "database restored"
        fi
    fi

    rm -rf "$TMP"
    trap - RETURN

    log "restart service"

    for SVC in \
        wings \
        nginx \
        pterodactyl-queue \
        pteroq \
        php8.1-fpm \
        php8.2-fpm \
        php8.3-fpm \
        php8.4-fpm; do

        if systemctl list-unit-files 2>/dev/null |
            grep -q "^${SVC}"; then
            svc_restart "$SVC" || true
        fi
    done

    ok "restore selesai"

    warn "cek config.yml Wings dan koneksi database sebelum menjalankan server game"
}

list_backups() {
    if [ ! -d "$BACKUP_BASE" ]; then
        warn "belum ada backup"
        return 0
    fi

    echo
    echo "  lokasi: $BACKUP_BASE"
    echo

    find "$BACKUP_BASE" \
        -maxdepth 1 \
        -type f \
        \( -name '*.tar.zst' -o -name '*.tar.gz' \) \
        -printf '%f\n' |
        sort |
        while read -r FILE; do
            local SIZE
            SIZE=$(du -h "$BACKUP_BASE/$FILE" |
                cut -f1)

            if [ -f "$BACKUP_BASE/$FILE.sha256" ]; then
                echo "  [SHA] $FILE ($SIZE)"
            else
                echo "  [---] $FILE ($SIZE)"
            fi
        done
}

migrate() {
    need_root
    ensure_cmd rsync rsync
    ensure_cmd ssh openssh-client

    echo
    log "konfigurasi VPS sumber"

    read -rp "  IP / hostname  : " SRC_HOST
    read -rp "  port SSH [22]  : " SRC_PORT
    SRC_PORT="${SRC_PORT:-22}"

    read -rp "  user SSH [root]: " SRC_USER
    SRC_USER="${SRC_USER:-root}"

    [ -n "$SRC_HOST" ] ||
        die "host sumber tidak boleh kosong"

    log "test koneksi SSH"

    ssh \
        -p "$SRC_PORT" \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        "${SRC_USER}@${SRC_HOST}" \
        true ||
        die "SSH ke sumber gagal"

    ok "koneksi SSH berhasil"

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

    echo
    log "DRY-RUN migrasi"
    echo "  belum ada file yang diubah."
    echo

    rsync \
        -aHAXxvz \
        --numeric-ids \
        --delete \
        --dry-run \
        --itemize-changes \
        -e "ssh -p ${SRC_PORT} -o StrictHostKeyChecking=accept-new" \
        "${EXCLUDES[@]}" \
        "${SRC_USER}@${SRC_HOST}:/" /

    echo
    warn "DRY-RUN selesai."
    echo "  Periksa daftar perubahan di atas."
    echo

    confirm_yes "jalankan migrasi sebenarnya?" ||
        {
            warn "migrasi dibatalkan"
            return 0
        }

    log "mulai migrasi"

    rsync \
        -aHAXxvz \
        --numeric-ids \
        --delete \
        --stats \
        -e "ssh -p ${SRC_PORT} -o StrictHostKeyChecking=accept-new" \
        "${EXCLUDES[@]}" \
        "${SRC_USER}@${SRC_HOST}:/" /

    ok "sinkronisasi selesai"

    warn "jangan langsung reboot."
    warn "cek SSH, network, fstab, netplan, Docker, dan service terlebih dahulu."
}

firewall_backup() {
    local DIR="$1"

    mkdir -p "$DIR"

    if has_cmd ufw; then
        ufw status verbose >"${DIR}/ufw-before.txt" 2>&1 || true
    fi

    if has_cmd iptables-save; then
        iptables-save >"${DIR}/iptables-before.rules" 2>/dev/null || true
    fi

    if has_cmd ip6tables-save; then
        ip6tables-save >"${DIR}/ip6tables-before.rules" 2>/dev/null || true
    fi

    ok "backup firewall tersimpan di $DIR"
}

get_ssh_port() {
    local PORT=""

    if has_cmd sshd; then
        PORT=$(sshd -T 2>/dev/null |
            awk '$1=="port"{print $2; exit}' || true)
    fi

    if [ -z "$PORT" ]; then
        PORT=$(grep -E '^[[:space:]]*Port[[:space:]]+' \
            /etc/ssh/sshd_config 2>/dev/null |
            awk '{print $2}' |
            head -n1 || true)
    fi

    echo "${PORT:-22}"
}

security() {
    need_root
    detect_os

    ensure_cmd iptables iptables
    ensure_cmd ufw ufw

    case "$OS_ID" in
        ubuntu|debian)
            pkg_install iptables-persistent fail2ban
            ;;
        centos|rhel|rocky|almalinux|fedora)
            pkg_install iptables-services fail2ban
            ;;
        *)
            die "OS $OS_ID belum disupport"
            ;;
    esac

    local SSH_DEFAULT
    SSH_DEFAULT=$(get_ssh_port)

    echo
    read -rp "SSH port yang dipakai [${SSH_DEFAULT}]: " SSH_PORT
    SSH_PORT="${SSH_PORT:-$SSH_DEFAULT}"

    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] ||
        die "SSH port tidak valid"

    [ "$SSH_PORT" -ge 1 ] &&
    [ "$SSH_PORT" -le 65535 ] ||
        die "SSH port harus 1-65535"

    echo
    echo "Port yang akan dibuka:"
    echo "  SSH : $SSH_PORT"
    echo "  HTTP: 80"
    echo "  HTTPS: 443"
    echo "  Pterodactyl: 8080"
    echo "  Wings: 2022"
    echo

    warn "Pastikan port di atas memang sesuai server kamu."

    confirm_yes "terapkan hardening?" ||
        {
            warn "hardening dibatalkan"
            return 0
        }

    local FW_BACKUP
    FW_BACKUP="${BACKUP_BASE}/firewall-$(stamp)"

    firewall_backup "$FW_BACKUP"

    log "konfigurasi UFW"

    ufw allow "${SSH_PORT}/tcp" >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 8080/tcp >/dev/null
    ufw allow 2022/tcp >/dev/null

    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    ufw --force enable >/dev/null

    log "konfigurasi iptables"

    iptables -F
    iptables -X

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT \
        -m conntrack \
        --ctstate ESTABLISHED,RELATED \
        -j ACCEPT

    iptables -A INPUT \
        -p tcp \
        --dport "$SSH_PORT" \
        -j ACCEPT

    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
    iptables -A INPUT -p tcp --dport 2022 -j ACCEPT

    iptables -A INPUT \
        -p icmp \
        --icmp-type echo-request \
        -m limit \
        --limit 1/s \
        -j ACCEPT

    iptables -A INPUT \
        -p tcp \
        --syn \
        -m limit \
        --limit 25/s \
        --limit-burst 50 \
        -j ACCEPT

    iptables -A INPUT \
        -p tcp \
        --syn \
        -j DROP

    iptables -A INPUT -f -j DROP

    iptables -A INPUT \
        -p tcp \
        --tcp-flags ALL NONE \
        -j DROP

    iptables -A INPUT \
        -p tcp \
        --tcp-flags ALL ALL \
        -j DROP

    log "sysctl hardening"

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

    log "konfigurasi Fail2Ban"

    mkdir -p /etc/fail2ban

    cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
EOF

    svc_enable fail2ban || true
    svc_restart fail2ban || true

    log "simpan rules"

    mkdir -p /etc/iptables

    if has_cmd iptables-save; then
        iptables-save >/etc/iptables/rules.v4
    fi

    if has_cmd ip6tables-save; then
        ip6tables-save >/etc/iptables/rules.v6
    fi

    echo
    ok "hardening selesai"

    echo
    echo "  firewall backup : $FW_BACKUP"
    echo "  SSH port        : $SSH_PORT"
    echo "  fail2ban        : $(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
    echo "  syncookies      : $(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo unknown)"
}

status_all() {
    echo
    echo "--- UFW ---"

    if has_cmd ufw; then
        ufw status verbose 2>/dev/null |
            head -n 20
    else
        echo "  tidak terpasang"
    fi

    echo
    echo "--- IPTABLES ---"

    if has_cmd iptables; then
        iptables -L -n --line-numbers 2>/dev/null |
            head -n 25
    else
        echo "  tidak terpasang"
    fi

    echo
    echo "--- FAIL2BAN ---"

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        systemctl status fail2ban \
            --no-pager 2>/dev/null |
            head -n 12
    else
        echo "  tidak aktif"
    fi

    echo
    echo "--- SYN COOKIES ---"

    sysctl net.ipv4.tcp_syncookies 2>/dev/null ||
        echo "  tidak tersedia"

    echo
    echo "--- PTERODACTYL ---"

    detect_pterodactyl

    if [ -n "$PTERO_DETECTED" ]; then
        echo "  komponen: $PTERO_DETECTED"

        for SVC in wings nginx pterodactyl-queue pteroq; do
            if systemctl list-unit-files 2>/dev/null |
                grep -q "^${SVC}"; then

                echo "  ${SVC}: $(systemctl is-active "$SVC" 2>/dev/null || echo unknown)"
            fi
        done
    else
        echo "  tidak terdeteksi"
    fi

    echo
    echo "--- SYSTEM ---"
    echo "  hostname : $(hostname)"
    echo "  OS       : $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "  kernel   : $(uname -r)"
    echo "  uptime   : $(uptime -p 2>/dev/null || true)"
    echo "  RAM      : $(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}')"
    echo "  disk /   : $(df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
}

menu() {
    while true; do
        echo "----- xyrTools v1 -----"
        echo "---- Kalau Mau NIMPA, Mikir Mas ----"

        echo "  1) Backup full VPS"
        echo "  2) Backup Pterodactyl"
        echo "  3) Restore Pterodactyl"
        echo "  4) List backup"
        echo "  5) Migrasi VPS"
        echo "  6) Hardening"
        echo "  7) Status layanan"
        echo "  0) Keluar"

        read -rp "pilih: " CH

        case "$CH" in
            1)
                backup_full
                pause
                ;;
            2)
                backup_pterodactyl
                pause
                ;;
            3)
                restore_pterodactyl
                pause
                ;;
            4)
                list_backups
                pause
                ;;
            5)
                migrate
                pause
                ;;
            6)
                security
                pause
                ;;
            7)
                status_all
                pause
                ;;
            0|q|quit)
                exit 0
                ;;
            *)
                warn "pilihan tidak valid"
                sleep 1
                ;;
        esac
    done
}

case "${1:-}" in
    backup)
        backup_full
        ;;
    backup-ptero)
        backup_pterodactyl
        ;;
    restore-ptero)
        restore_pterodactyl
        ;;
    list)
        list_backups
        ;;
    migrate)
        migrate
        ;;
    security)
        security
        ;;
    status)
        status_all
        ;;
    ""|menu)
        menu
        ;;
    *)
        die "aksi tidak dikenal: $1"
        ;;
esac
