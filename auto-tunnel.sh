#!/usr/bin/env bash
# auto-tunnel.sh
# Cara menjalankan: chmod +x auto-tunnel.sh && ./auto-tunnel.sh
# Peringatan: Script ini hanya untuk penggunaan legal pada server yang sah.
# Skrip ini hanya bertugas memasang pengelola tunneling (tunnelctl) ke sistem.

set -euo pipefail

INSTALL_DIR="/usr/local/share/cers-tunneling"
BIN_PATH="/usr/local/bin/tunnelctl"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  info "Jalankan 'tunnelctl install' untuk memprovisioning layanan, atau 'tunnelctl' untuk menu penuh."
}

main "$@"
