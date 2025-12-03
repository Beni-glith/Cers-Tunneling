#!/usr/bin/env bash
# Instalasi sekali perintah untuk Cers-Tunneling
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "[ERROR] Jalankan script ini sebagai root." >&2
  exit 1
fi

if ! grep -qiE "ubuntu|debian" /etc/os-release; then
  echo "[ERROR] Hanya mendukung Ubuntu/Debian." >&2
  exit 1
fi

# Pastikan alat unduhan tersedia agar perintah satu baris berjalan mulus di VPS baru.
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "[INFO] Menginstal curl dan wget..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget
fi

REPO_SLUG=${REPO_SLUG:-Cers-Tunneling/Cers-Tunneling}
REPO_BRANCH=${REPO_BRANCH:-main}
RAW_BASE_URL=${RAW_BASE_URL:-"https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}"}

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

AUTO_SCRIPT_PATH="$TMP_DIR/auto-tunnel.sh"
DOWNLOAD_URL="${RAW_BASE_URL}/auto-tunnel.sh"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$DOWNLOAD_URL" -o "$AUTO_SCRIPT_PATH"
else
  wget -q "$DOWNLOAD_URL" -O "$AUTO_SCRIPT_PATH"
fi

chmod +x "$AUTO_SCRIPT_PATH"

# Jalankan installer utama.
"$AUTO_SCRIPT_PATH"

cat <<MSG
[OK] Instalasi selesai. Jika menggunakan GitHub, contoh perintah satu baris:
  bash -c "$(command -v curl >/dev/null 2>&1 && echo "curl -fsSL" || echo "wget -qO-") https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}/install.sh | bash"
MSG
