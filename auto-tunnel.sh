#!/usr/bin/env bash
# auto-tunnel.sh
# Cara menjalankan: chmod +x auto-tunnel.sh && ./auto-tunnel.sh
# Peringatan: Script ini hanya untuk penggunaan legal pada server yang sah.
# Skrip ini hanya bertugas memasang pengelola tunneling (tunnelctl) ke sistem.

set -euo pipefail

INSTALL_DIR="/usr/local/share/cers-tunneling"
BIN_PATH="/usr/local/bin/tunnelctl"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/etc/tunneling"
STATE_FILE="$STATE_DIR/settings.conf"
PERMISSION_FLAG_FILE="$STATE_DIR/.permission_granted"
IP_ALLOWLIST_FILE="$STATE_DIR/allowed_ips"
ALLOWLIST_TEMPLATE="$SOURCE_DIR/allowed_ips.conf"
BACKUP_CRON="/etc/cron.d/auto-backup-tunnel"

info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
error() { echo "[ERROR] $*" >&2; }

check_root() {
  if [[ $(id -u) -ne 0 ]]; then
    error "Script harus dijalankan sebagai root."
    exit 1
  fi
}

check_requirements() {
  if ! grep -qi "ubuntu" /etc/os-release; then
    error "Hanya mendukung Ubuntu 20.04/22.04."
    exit 1
  fi
  local arch
  arch=$(uname -m)
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    error "Hanya mendukung arsitektur x86_64/amd64."
    exit 1
  fi
}

set_state() {
  local key=$1 value=$2
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"
  if grep -q "^${key}=" "$STATE_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$STATE_FILE"
  else
    echo "${key}=${value}" >>"$STATE_FILE"
  fi
}

configure_authorization() {
  read -rp "Masukkan KODE IZIN ADMIN: " permission_token
  if [[ -z "$permission_token" ]]; then
    error "Kode izin wajib diisi untuk melanjutkan instalasi."
    exit 1
  fi
  set_state permission_token "$permission_token"
  mkdir -p "$STATE_DIR"
  echo "$permission_token" >"$PERMISSION_FLAG_FILE"
  chmod 600 "$PERMISSION_FLAG_FILE"
  ok "Izin disimpan; kode akan diverifikasi pada penggunaan pertama."
}

detect_public_ip() {
  local ip
  ip=$(curl -s https://api.ipify.org 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    ip=$(curl -s https://ifconfig.me 2>/dev/null || true)
  fi
  echo "$ip"
}

configure_ip_allowlist() {
  mkdir -p "$STATE_DIR"
  local from_template=false
  if [[ -s "$ALLOWLIST_TEMPLATE" ]]; then
    info "Menyalin daftar izin IP dari template $ALLOWLIST_TEMPLATE."
    install -m 0600 "$ALLOWLIST_TEMPLATE" "$IP_ALLOWLIST_FILE"
    from_template=true
  else
    : >"$IP_ALLOWLIST_FILE"
  fi

  local current_ip ip_list existing_count
  current_ip=$(detect_public_ip)
  existing_count=$(grep -Evc '^(#|\s*$)' "$IP_ALLOWLIST_FILE")
  if [[ "$existing_count" -eq 0 ]]; then
    info "IP publik terdeteksi: ${current_ip:-tidak terdeteksi}"
    read -rp "Daftar IP yang diizinkan (pisahkan dengan spasi) [default: ${current_ip:-wajib isi}]: " ip_list
    if [[ -z "$ip_list" && -n "$current_ip" ]]; then
      ip_list="$current_ip"
    fi
    if [[ -z "$ip_list" ]]; then
      error "Minimal satu IP harus dicantumkan dalam daftar izin."
      exit 1
    fi
    tr ' ' '\n' <<<"$ip_list" | sed '/^$/d' | sort -u >>"$IP_ALLOWLIST_FILE"
  fi

  chmod 600 "$IP_ALLOWLIST_FILE"
  if $from_template; then
    ok "Daftar izin IP diimpor dari template dan disimpan di $IP_ALLOWLIST_FILE. Edit file ini untuk menambah atau mencabut izin."
  else
    ok "Daftar izin IP disimpan di $IP_ALLOWLIST_FILE. Edit file ini untuk menambah atau mencabut izin."
  fi
}

configure_telegram() {
  read -rp "Masukkan TOKEN BOT TELEGRAM ADMIN: " bot
  read -rp "Masukkan CHAT ID TELEGRAM ADMIN: " chat
  if [[ -z "$bot" || -z "$chat" ]]; then
    error "Token bot dan Chat ID wajib diisi agar auto-backup dapat berjalan."
    exit 1
  fi
  set_state telegram_bot_token "$bot"
  set_state telegram_chat_id "$chat"
  ok "Konfigurasi Telegram disimpan."
}

setup_auto_backup_cron() {
  mkdir -p /var/backups/tunneling /var/lib/tunneling "$STATE_DIR"
  cat >"$BACKUP_CRON" <<CRON
0 */12 * * * root $BIN_PATH --auto-backup
CRON
  systemctl restart cron
  ok "Auto backup aktif dan terjadwal setiap 12 jam ke bot Telegram admin."
}

install_files() {
  info "Menyalin berkas tunnelctl..."
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$SOURCE_DIR/tunnelctl.sh" "$INSTALL_DIR/tunnelctl.sh"
  if [[ -d "$SOURCE_DIR/modules" ]]; then
    mkdir -p "$INSTALL_DIR/modules"
    cp -r "$SOURCE_DIR/modules/"* "$INSTALL_DIR/modules/" 2>/dev/null || true
    chmod -R 0755 "$INSTALL_DIR/modules"
  fi
  ln -sf "$INSTALL_DIR/tunnelctl.sh" "$BIN_PATH"
  ok "Berkas terpasang. Gunakan perintah 'tunnelctl' untuk membuka menu."
}

main() {
  check_root
  check_requirements
  install_files
  configure_ip_allowlist
  configure_authorization
  configure_telegram
  setup_auto_backup_cron
  info "Mengirimkan backup awal ke bot Telegram admin..."
  if ! $BIN_PATH --auto-backup; then
    error "Backup awal gagal. Pastikan izin dan konfigurasi sudah benar lalu jalankan 'tunnelctl --auto-backup' secara manual."
  fi
  info "Jalankan 'tunnelctl install' untuk memprovisioning layanan, atau 'tunnelctl' untuk menu penuh."
}

main "$@"
