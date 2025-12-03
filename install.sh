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

REPO_SLUG=${REPO_SLUG:-Beni-glith/Cers-Tunneling}
REPO_BRANCH=${REPO_BRANCH:-codex/fix-missing-sponge-command-error}
RAW_BASE_URL=${RAW_BASE_URL:-"https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}"}

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

FILES=(auto-tunnel.sh tunnelctl.sh allowed_ips.conf)
for file in "${FILES[@]}"; do
  url="${RAW_BASE_URL}/${file}"
  dest="$TMP_DIR/$file"
  echo "[INFO] Mengunduh $file dari $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -q "$url" -O "$dest"
  fi
done

chmod +x "$TMP_DIR/auto-tunnel.sh"

# Jalankan installer utama dari bundle unduhan sementara.
"$TMP_DIR/auto-tunnel.sh"

cat <<MSG
[OK] Instalasi selesai. Contoh perintah satu baris dari GitHub:
  bash -c "$(command -v curl >/dev/null 2>&1 && echo "curl -fsSL" || echo "wget -qO-") https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}/install.sh | bash"
MSG
