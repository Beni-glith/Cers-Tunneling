#!/usr/bin/env bash
# tunnelctl.sh
# Cara menjalankan: chmod +x tunnelctl.sh && ./tunnelctl.sh
# Peringatan: Script ini hanya untuk penggunaan legal pada server yang sah.
# Script ini adalah kontroler utama; gunakan auto-tunnel.sh untuk menginstal ke sistem.

set -euo pipefail

# === Konstanta & Variabel ===
OPENSSH_PORT=22
DROPBEAR_PORT1=143
DROPBEAR_PORT2=109
DROPBEAR_WS_PORT1=443
DROPBEAR_WS_PORT2=109
SSH_UDP_DEFAULT_PORT=5300
OVPN_SSL_PORT=443
OVPN_TCP_PORT=1194
OVPN_UDP_PORT=2200
BADVPN_PORTS=(7100 7300)
SSH_WS_PORTS=(80 8080)
SSH_WS_SSL_PORT=443
XRAY_VMESS_PORT=8443
XRAY_VLESS_PORT=8444
XRAY_TROJAN_PORT=8445
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_CERT_FILE="/etc/ssl/xray.crt"
XRAY_KEY_FILE="/etc/ssl/xray.key"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
PERMISSION_TOKEN=""
AUTO_BACKUP_INTERVAL_HOURS=12
BACKUP_DIR="/var/backups/tunneling"
LOCAL_DB="/var/lib/tunneling/accounts.json"
STATE_DIR="/etc/tunneling"
SSH_UDP_STATE_FILE="$STATE_DIR/ssh_udp_ports"
STATE_FILE="$STATE_DIR/settings.conf"
PERMISSION_FLAG_FILE="$STATE_DIR/.permission_granted"
ACTIVE_DROPBEAR_WS_PORT1="$DROPBEAR_WS_PORT1"
ACTIVE_DROPBEAR_WS_PORT2="$DROPBEAR_WS_PORT2"
ACTIVE_SSH_WS_SSL_PORT="$SSH_WS_SSL_PORT"
VERSION_LABEL="4.0 LTS"
CLIENT_LABEL="PRIVATE"
declare -a ACME_STOPPED_SERVICES=()

# === Utilitas Output ===
info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
error() { echo "[ERROR] $*" >&2; }
line() { printf '%*s\n' "${1:-60}" '' | tr ' ' '='; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { error "Perintah '$1' tidak tersedia."; exit 1; }; }

ensure_port_available() {
  local port=$1 proto=$2 fallback=${3:-}
  local candidate=$port

  if ss -lntup | grep -q ":$port " 2>/dev/null; then
    if [[ -n "$fallback" ]]; then
      candidate=$fallback
      while ss -lntup | grep -q ":$candidate " 2>/dev/null; do
        info "Port $candidate/$proto juga digunakan, mencari port lain..."
        candidate=$(generate_random_port)
      done
      info "Port $port/$proto sedang digunakan, menggunakan port cadangan $candidate."
      echo "$candidate"
    else
      error "Port $port/$proto sedang digunakan."
      return 1
    fi
  else
    echo "$candidate"
  fi
}

# Jalankan jq dan tulis ulang hasilnya ke file tanpa bergantung pada 'sponge'.
jq_overwrite_file() {
  local file=$1
  shift
  local tmp
  tmp=$(mktemp)
  jq "$@" "$file" >"$tmp" && mv "$tmp" "$file"
}

# === Helper ===
generate_uuid() { uuidgen; }
generate_random_password() { head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; }
generate_random_port() { shuf -i 20000-40000 -n 1; }
get_public_ip() { curl -s https://api.ipify.org 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null; }

get_city() {
  curl -s ipinfo.io/city 2>/dev/null || echo "-"
}

get_isp() {
  curl -s ipinfo.io/org 2>/dev/null | cut -d' ' -f2- || echo "-"
}

ping_target() {
  local target=${1:-8.8.8.8}
  local output
  output=$(ping -c1 -W1 "$target" 2>/dev/null || true)
  local latency
  latency=$(echo "$output" | awk -F'/' '/rtt/ {printf "%.2f ms", $5}')
  if [[ -n "$latency" ]]; then
    echo "$latency"
  else
    echo "unreachable"
  fi
}

service_on_off() {
  systemctl is-active --quiet "$1" && echo "ON" || echo "OFF"
}

init_state() {
  mkdir -p "$BACKUP_DIR" "$(dirname "$LOCAL_DB")" "$STATE_DIR"
  if [[ ! -f "$LOCAL_DB" ]]; then
    cat >"$LOCAL_DB" <<'JSON'
{"ssh":[],"vmess":[],"vless":[],"trojan":[]}
JSON
  fi
  [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"
  TELEGRAM_BOT_TOKEN=$(get_state telegram_bot_token "$TELEGRAM_BOT_TOKEN")
  TELEGRAM_CHAT_ID=$(get_state telegram_chat_id "$TELEGRAM_CHAT_ID")
  PERMISSION_TOKEN=$(get_state permission_token "")
}

# === Validasi Awal ===
check_root() {
  if [[ $(id -u) -ne 0 ]]; then
    error "Script harus dijalankan sebagai root."
    exit 1
  fi
}

check_os() {
  if ! grep -qiE "ubuntu|debian" /etc/os-release; then
    error "Hanya mendukung Ubuntu 20.04/22.04 atau Debian 11/12."
    exit 1
  fi
}

check_arch() {
  arch=$(uname -m)
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    error "Hanya mendukung arsitektur x86_64/amd64."
    exit 1
  fi
}

# === Dependency ===
install_dependencies() {
  info "Memperbarui paket dan menginstal dependensi..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    jq moreutils curl wget unzip net-tools openssl iptables-persistent ufw \
    dropbear openvpn easy-rsa socat cron uuid-runtime build-essential cmake git \
    vnstat haproxy nginx || {
      error "Gagal menginstal dependensi."
      exit 1
    }
  ensure_badvpn_binary
  if ! command -v xray >/dev/null 2>&1; then
    info "Xray tidak ditemukan, memasang via installer resmi..."
    bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install || {
      error "Instalasi Xray gagal."
      exit 1
    }
  fi
}

# === Domain & SSL ===
ensure_domain_configured() {
  mkdir -p "$STATE_DIR"
  local domain
  domain=$(cat "$STATE_DIR/domain" 2>/dev/null || true)
  if [[ -z "$domain" ]]; then
    read -rp "Masukkan domain untuk SSL XRAY: " domain
    if [[ -z "$domain" ]]; then
      error "Domain wajib disetel agar SSL dapat dibuat."
      exit 1
    fi
    echo "$domain" >"$STATE_DIR/domain"
    ok "Domain tersimpan: $domain"
  fi
}

service_using_port() {
  local port=$1 proto=$2
  ss -l${proto}np 2>/dev/null | awk -v p=":$port" 'index($0,p)>0 { if (match($0, /users:\(\("([^"]+)"/, m)) { print m[1]; exit } }'
}

ensure_acme_ports_available() {
  ACME_STOPPED_SERVICES=()
  for port in 80 443; do
    ufw allow "$port"/tcp >/dev/null 2>&1 || true
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true

    local svc
    svc=$(service_using_port "$port" t)
    if [[ -n "$svc" ]]; then
      info "Port $port/tcp digunakan oleh layanan $svc; menghentikan sementara untuk penerbitan sertifikat..."
      systemctl stop "$svc" 2>/dev/null || killall -q "$svc" 2>/dev/null || true
      ACME_STOPPED_SERVICES+=("$svc")
    fi
  done
}

restore_acme_services() {
  if (( ${#ACME_STOPPED_SERVICES[@]} == 0 )); then
    return
  fi
  for svc in "${ACME_STOPPED_SERVICES[@]}"; do
    info "Menghidupkan kembali layanan $svc setelah penerbitan sertifikat..."
    systemctl restart "$svc" 2>/dev/null || systemctl start "$svc" 2>/dev/null || true
  done
  ACME_STOPPED_SERVICES=()
}

obtain_ssl_certificate() {
  ensure_domain_configured
  local domain
  domain=$(cat "$STATE_DIR/domain")
  mkdir -p /etc/ssl

  if [[ -f "$XRAY_CERT_FILE" && -f "$XRAY_KEY_FILE" ]]; then
    ok "Sertifikat SSL sudah ada untuk $domain"
    return
  fi

  info "Mengambil sertifikat SSL via acme.sh untuk $domain..."
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    mkdir -p /root/.acme.sh
    curl https://acme-install.netlify.app/acme.sh -o /root/.acme.sh/acme.sh
    chmod +x /root/.acme.sh/acme.sh
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade
  fi

  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ensure_acme_ports_available
  if ! /root/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256; then
    restore_acme_services
    error "Gagal menerbitkan sertifikat. Pastikan port 80/443 dapat diakses dari internet."
    exit 1
  fi
  if ! /root/.acme.sh/acme.sh --installcert -d "$domain" --fullchainpath "$XRAY_CERT_FILE" --keypath "$XRAY_KEY_FILE" --ecc; then
    restore_acme_services
    error "Gagal memasang sertifikat yang telah diterbitkan."
    exit 1
  fi
  restore_acme_services
  chmod 600 "$XRAY_CERT_FILE" "$XRAY_KEY_FILE"
  cat "$XRAY_CERT_FILE" "$XRAY_KEY_FILE" > /etc/ssl/xray.pem
  chmod 600 /etc/ssl/xray.pem
  ok "Sertifikat SSL terpasang di $XRAY_CERT_FILE"
}

# === Firewall ===
open_firewall_ports() {
  local ports=(
    "$OPENSSH_PORT" "$DROPBEAR_PORT1" "$DROPBEAR_PORT2"
    "$ACTIVE_DROPBEAR_WS_PORT1" "$ACTIVE_DROPBEAR_WS_PORT2"
    "$OVPN_SSL_PORT" "$OVPN_TCP_PORT" "$OVPN_UDP_PORT"
    "${BADVPN_PORTS[@]}" "${SSH_WS_PORTS[@]}" "$ACTIVE_SSH_WS_SSL_PORT"
    "$XRAY_VMESS_PORT" "$XRAY_VLESS_PORT" "$XRAY_TROJAN_PORT"
  )
  for p in "${ports[@]}"; do
    ufw allow "$p" >/dev/null 2>&1 || true
    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT || true
    iptables -I INPUT -p udp --dport "$p" -j ACCEPT || true
  done
  if [[ -f "$SSH_UDP_STATE_FILE" ]]; then
    while IFS= read -r udp_port; do
      [[ -z "$udp_port" ]] && continue
      ufw allow "$udp_port"/udp >/dev/null 2>&1 || true
      iptables -I INPUT -p udp --dport "$udp_port" -j ACCEPT || true
    done <"$SSH_UDP_STATE_FILE"
  fi
  netfilter-persistent save >/dev/null 2>&1 || true
}

set_state() {
  local key=$1 value=$2
  if grep -q "^${key}=" "$STATE_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$STATE_FILE"
  else
    echo "${key}=${value}" >>"$STATE_FILE"
  fi
}

get_state() {
  local key=$1 default=${2:-off}
  grep -E "^${key}=" "$STATE_FILE" | tail -n1 | cut -d'=' -f2- || echo "$default"
}

ensure_telegram_configured() {
  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    if [[ -t 0 ]]; then
      info "Konfigurasi Telegram belum lengkap."
      configure_telegram_bot
    else
      error "Konfigurasi Telegram kosong; tidak dapat melanjutkan di mode non-interaktif."
      return 1
    fi
  fi
  return 0
}

ensure_permission() {
  if [[ -z "${PERMISSION_TOKEN:-}" ]]; then
    error "Kode izin belum disetel. Jalankan installer dan masukkan kode izin admin."
    exit 1
  fi

  if [[ -f "$PERMISSION_FLAG_FILE" ]]; then
    local stored
    stored=$(cat "$PERMISSION_FLAG_FILE")
    if [[ "$stored" == "$PERMISSION_TOKEN" ]]; then
      return 0
    fi
  fi

  if [[ -t 0 ]]; then
    local input
    read -rsp "Masukkan kode izin admin: " input
    echo
    if [[ "$input" != "$PERMISSION_TOKEN" ]]; then
      error "Kode izin salah."
      exit 1
    fi
    echo "$PERMISSION_TOKEN" >"$PERMISSION_FLAG_FILE"
    chmod 600 "$PERMISSION_FLAG_FILE"
    ok "Izin diverifikasi."
  else
    error "Izin belum diverifikasi dan tidak dapat meminta input di mode non-interaktif."
    exit 1
  fi
}

# === OpenSSH ===
install_openssh() {
  info "Mengonfigurasi OpenSSH..."
  sed -i "s/^#\?Port .*/Port $OPENSSH_PORT/" /etc/ssh/sshd_config
  systemctl enable ssh
  systemctl restart ssh || systemctl restart sshd
}

create_ssh_user() {
  local user=$1 days=$2
  local pass
  pass=$(generate_random_password)
  local expire_date
  expire_date=$(date -d "+$days days" +%Y-%m-%d)
  useradd -m -s /bin/bash -e "$expire_date" "$user"
  echo "$user:$pass" | chpasswd
  db_upsert_account ssh "$user" "$expire_date" "" "" "false" "active"
  ok "User $user dibuat dengan password $pass (expired $expire_date)"
}

delete_ssh_user() {
  local user=$1
  userdel -r "$user" 2>/dev/null || true
  db_remove_account ssh "$user"
  ok "User $user dihapus."
}

renew_ssh_user() {
  local user=$1 days=$2
  local new_expire
  new_expire=$(date -d "+$days days" +%Y-%m-%d)
  chage -E "$new_expire" "$user"
  db_upsert_account ssh "$user" "$new_expire" "" "" "false" "active"
  ok "User $user diperpanjang sampai $new_expire"
}

lock_ssh_user() {
  local user=$1
  usermod -L "$user"
  db_update_status ssh "$user" "locked"
  ok "User $user dikunci."
}

unlock_ssh_user() {
  local user=$1
  usermod -U "$user"
  db_update_status ssh "$user" "active"
  ok "User $user diaktifkan kembali."
}

edit_ssh_limit_ip() {
  local user=$1 limit=$2
  db_upsert_account ssh "$user" "" "$limit" "" "false" "active"
  ok "Limit IP untuk $user diset ke ${limit:-tidak ada}"
}

toggle_limit_ip() {
  local user=$1 state
  state=$(get_state "limit_ip_${user}" off)
  [[ "$state" == "off" ]] && state="on" || state="off"
  set_state "limit_ip_${user}" "$state"
  ok "Limit IP untuk $user diubah ke $state"
}

auto_kill_multilogin() {
  info "Memeriksa sesi berlebih sesuai limit IP..."
  local entries
  entries=$(jq -c '.ssh[]?' "$LOCAL_DB")
  while read -r row; do
    [[ -z "$row" ]] && continue
    local user limit
    user=$(echo "$row" | jq -r '.user')
    limit=$(echo "$row" | jq -r '.limit_ip')
    [[ -z "$limit" || "$limit" == "null" || "$limit" == "" ]] && continue
    local active
    active=$(who | awk -v u="$user" '$1==u' | wc -l)
    if (( active > limit )); then
      pkill -KILL -u "$user" || true
      ok "User $user dibunuh karena melampaui batas sesi ($active/$limit)"
    fi
  done <<< "$entries"
}

show_account_detail() {
  local user=$1
  jq -r --arg u "$user" '.ssh[]? | select(.user==$u) | "User: \(.user)\nExpire: \(.expire)\nLimit IP: \(.limit_ip)\nLimit BW: \(.limit_bw)\nStatus: \(.status)"' "$LOCAL_DB"
}

recover_account() {
  local user=$1
  local record
  record=$(jq -c --arg u "$user" '.ssh[]? | select(.user==$u)' "$LOCAL_DB")
  if [[ -z "$record" ]]; then
    error "Data akun tidak ditemukan di database lokal."
    return
  fi
  local expire pass
  expire=$(echo "$record" | jq -r '.expire')
  pass=$(generate_random_password)
  if id "$user" &>/dev/null; then
    chage -E "$expire" "$user" 2>/dev/null || true
  else
    useradd -m -s /bin/bash -e "$expire" "$user"
  fi
  echo "$user:$pass" | chpasswd
  ok "Akun $user dipulihkan dengan password baru $pass"
}

check_login_udp() {
  ss -u -a | grep -E "ssh-udp|:${SSH_UDP_DEFAULT_PORT}" || echo "Tidak ada koneksi UDP SSH terdeteksi"
}

list_ssh_logins() {
  who || true
}

list_ssh_members() {
  getent passwd | awk -F: '$3>=1000{print $1}'
}

list_ssh_expired() {
  awk -F: '{print $1" "$8}' /etc/shadow | while read -r user expire; do
    [[ -z "$expire" || "$expire" == "" || "$expire" == "99999" ]] && continue
    if (( expire>0 )); then
      local date
      date=$(date -d "1970-01-01 + $expire days" +%Y-%m-%d)
      if [[ $(date -d "$date" +%s) -lt $(date +%s) ]]; then
        echo "$user (expired: $date)"
      fi
    fi
  done
}

# === Dropbear ===
install_dropbear() {
  info "Mengonfigurasi Dropbear..."
  sed -i "s/^NO_START=.*/NO_START=0/" /etc/default/dropbear
  sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$DROPBEAR_PORT1/" /etc/default/dropbear
  if ! grep -q "DROPBEAR_EXTRA_ARGS" /etc/default/dropbear; then
    echo "DROPBEAR_EXTRA_ARGS=\"-p $DROPBEAR_PORT2\"" >> /etc/default/dropbear
  else
    sed -i "s/^DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS=\"-p $DROPBEAR_PORT2\"/" /etc/default/dropbear
  fi
  systemctl enable dropbear
  systemctl restart dropbear
}

# === Dropbear WebSocket ===
install_dropbear_ws() {
  info "Menyiapkan WebSocket untuk Dropbear..."
  local ws1 ws2
  ws1=$(ensure_port_available "$DROPBEAR_WS_PORT1" tcp "$(generate_random_port)") || return 1
  ws2=$(ensure_port_available "$DROPBEAR_WS_PORT2" tcp "$(generate_random_port)") || return 1
  ACTIVE_DROPBEAR_WS_PORT1="$ws1"
  ACTIVE_DROPBEAR_WS_PORT2="$ws2"
  cat >/etc/systemd/system/dropbear-ws.service <<WS
[Unit]
Description=Dropbear WebSocket Proxy ${ws1}->${DROPBEAR_PORT1}
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${ws1},reuseaddr,fork TCP:127.0.0.1:${DROPBEAR_PORT1}
Restart=always

[Install]
WantedBy=multi-user.target
WS
  cat >/etc/systemd/system/dropbear-ws109.service <<WS2
[Unit]
Description=Dropbear WebSocket Proxy ${ws2}->${DROPBEAR_PORT2}
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${ws2},reuseaddr,fork TCP:127.0.0.1:${DROPBEAR_PORT2}
Restart=always

[Install]
WantedBy=multi-user.target
WS2
  systemctl daemon-reload
  systemctl enable dropbear-ws dropbear-ws109
  systemctl restart dropbear-ws dropbear-ws109
}

# === SSH over UDP ===
install_ssh_udp_template() {
  cat >/etc/systemd/system/ssh-udp@.service <<UDP
[Unit]
Description=SSH over UDP Forwarder on port %i
After=network.target

[Service]
ExecStart=/usr/bin/socat UDP-LISTEN:%i,reuseaddr,fork TCP:127.0.0.1:${OPENSSH_PORT}
Restart=always

[Install]
WantedBy=multi-user.target
UDP
  systemctl daemon-reload
}

start_ssh_udp() {
  local port=$1
  local chosen
  chosen=$(ensure_port_available "$port" udp) || return 1
  echo "$chosen" >>"$SSH_UDP_STATE_FILE"
  systemctl enable ssh-udp@"$chosen"
  systemctl restart ssh-udp@"$chosen"
  ok "SSH over UDP aktif di port $chosen"
}

configure_ssh_udp_menu() {
  install_ssh_udp_template
  line; echo "SSH over UDP"; line
  echo "1. Aktifkan pada port default ($SSH_UDP_DEFAULT_PORT)"
  echo "2. Aktifkan pada port tertentu"
  echo "3. Nonaktifkan semua"
  read -rp "Pilih: " opt
  case $opt in
    1) start_ssh_udp "$SSH_UDP_DEFAULT_PORT" ;;
    2) read -rp "Port atau range (contoh 5300-5302): " pr;
       if [[ $pr == *-* ]]; then
         local start end
         start=${pr%-*}; end=${pr#*-}
         for p in $(seq "$start" "$end"); do start_ssh_udp "$p"; done
       else
         start_ssh_udp "$pr"
       fi
       ;;
    3)
       if [[ -f "$SSH_UDP_STATE_FILE" ]]; then
         while IFS= read -r p; do
           systemctl disable --now ssh-udp@"$p" 2>/dev/null || true
         done <"$SSH_UDP_STATE_FILE"
         >"$SSH_UDP_STATE_FILE"
       fi
       ok "SSH over UDP dinonaktifkan"
       ;;
  esac
}

# === XRAY ===
install_xray() {
  info "Mengonfigurasi Xray..."
  ensure_domain_configured
  obtain_ssl_certificate
  local domain
  domain=$(cat "$STATE_DIR/domain")

  mkdir -p /usr/local/etc/xray /var/log/xray
  cat >"$XRAY_CONFIG" <<JSON
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${XRAY_VMESS_PORT},
      "protocol": "vmess",
      "tag": "vmess-ws",
      "settings": {"clients": []},
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{"certificateFile": "${XRAY_CERT_FILE}", "keyFile": "${XRAY_KEY_FILE}"}],
          "serverName": "${domain}"
        },
        "wsSettings": {"path": "/vmess", "headers": {"Host": "${domain}"}}
      }
    },
    {
      "port": ${XRAY_VLESS_PORT},
      "protocol": "vless",
      "tag": "vless-ws",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{"certificateFile": "${XRAY_CERT_FILE}", "keyFile": "${XRAY_KEY_FILE}"}],
          "serverName": "${domain}"
        },
        "wsSettings": {"path": "/vless", "headers": {"Host": "${domain}"}}
      }
    },
    {
      "port": ${XRAY_TROJAN_PORT},
      "protocol": "trojan",
      "tag": "trojan-tcp",
      "settings": {"clients": []},
      "streamSettings": {
        "security": "tls",
        "tlsSettings": {
          "certificates": [{"certificateFile": "${XRAY_CERT_FILE}", "keyFile": "${XRAY_KEY_FILE}"}],
          "serverName": "${domain}"
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
JSON
  systemctl enable xray
  systemctl restart xray
  configure_haproxy "$domain"
  configure_nginx "$domain"
}

reload_xray() {
  systemctl restart xray
}

resolve_xray_credential() {
  local protocol=$1 user=$2
  local cred
  cred=$(db_get_account_field "$protocol" "$user" "credential")
  if [[ -z "$cred" || "$cred" == "null" ]]; then
    case $protocol in
      vmess|vless)
        cred=$(jq -r --arg proto "$protocol" --arg email "$user" '.inbounds[] | select(.protocol==$proto) | .settings.clients[] | select(.email==$email) | .id' "$XRAY_CONFIG")
        ;;
      trojan)
        cred=$(jq -r --arg email "$user" '.inbounds[] | select(.protocol=="trojan") | .settings.clients[] | select(.email==$email) | .password' "$XRAY_CONFIG")
        ;;
    esac
  fi
  echo "$cred"
}

add_xray_client() {
  local protocol=$1 user=$2 id_or_pass=$3
  local expire=$4
  jq_overwrite_file "$XRAY_CONFIG" \
    --arg proto "$protocol" --arg email "$user" --arg cred "$id_or_pass" '
      (.inbounds[] | select(.protocol==$proto) | .settings.clients) |= (
        map(select(.email!=$email)) + [
          if $proto=="trojan" then {"password":$cred,"email":$email}
          else {"id":$cred,"email":$email}
          end
        ]
      )
    '
  db_upsert_account "$protocol" "$user" "$expire" "" "" "false" "active" "$id_or_pass"
  reload_xray
}

recover_xray_account() {
  local protocol=$1 user=$2
  local cred exp
  cred=$(db_get_account_field "$protocol" "$user" "credential")
  exp=$(db_get_account_field "$protocol" "$user" "expire")
  if [[ -z "$cred" || "$cred" == "null" ]]; then
    error "Tidak ada data credential untuk $user ($protocol)."
    return 1
  fi
  add_xray_client "$protocol" "$user" "$cred" "$exp"
  ok "Akun $user ($protocol) dipulihkan ke konfigurasi XRAY"
}

remove_xray_client() {
  local protocol=$1 user=$2
  jq_overwrite_file "$XRAY_CONFIG" --arg proto "$protocol" --arg email "$user" \
    '(.inbounds[] | select(.protocol==$proto) | .settings.clients) |= map(select(.email!=$email))'
  db_remove_account "$protocol" "$user"
  reload_xray
}

renew_xray_client() {
  local protocol=$1 user=$2 days=$3
  local new_expire
  new_expire=$(date -d "+$days days" +%Y-%m-%d)
  local cred
  cred=$(resolve_xray_credential "$protocol" "$user")
  if [[ -z "$cred" || "$cred" == "null" ]]; then
    error "Credential untuk $user ($protocol) tidak ditemukan di database ataupun config."
    return 1
  fi
  add_xray_client "$protocol" "$user" "$cred" "$new_expire"
  ok "Akun $user ($protocol) diperpanjang sampai $new_expire"
}

show_xray_config_account() {
  local protocol=$1 user=$2
  local domain
  domain=$(cat "$STATE_DIR/domain" 2>/dev/null || get_public_ip)
  case $protocol in
    vmess)
      local id
      id=$(jq -r --arg email "$user" '.inbounds[] | select(.protocol=="vmess") | .settings.clients[] | select(.email==$email) | .id' "$XRAY_CONFIG")
      [[ -z "$id" ]] && { error "User tidak ditemukan"; return; }
      local json
      json=$(cat <<CFG
{
  "v": "2",
  "ps": "$user",
  "add": "${domain}",
  "port": ${XRAY_VMESS_PORT},
  "id": "$id",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "${domain}",
  "path": "/vmess",
  "tls": "tls"
}
CFG
)
      echo "Link VMESS: vmess://$(echo -n "$json" | base64 -w0)"
      ;;
    vless)
      local id
      id=$(jq -r --arg email "$user" '.inbounds[] | select(.protocol=="vless") | .settings.clients[] | select(.email==$email) | .id' "$XRAY_CONFIG")
      [[ -z "$id" ]] && { error "User tidak ditemukan"; return; }
      echo "URL VLESS: vless://$id@${domain}:${XRAY_VLESS_PORT}?encryption=none&security=tls&type=ws&path=/vless&sni=${domain}&host=${domain}#${user}"
      ;;
    trojan)
      local pwd
      pwd=$(jq -r --arg email "$user" '.inbounds[] | select(.protocol=="trojan") | .settings.clients[] | select(.email==$email) | .password' "$XRAY_CONFIG")
      [[ -z "$pwd" ]] && { error "User tidak ditemukan"; return; }
      echo "URL TROJAN: trojan://${pwd}@${domain}:${XRAY_TROJAN_PORT}?sni=${domain}#${user}"
      ;;
  esac
}

# === OpenVPN ===
setup_easy_rsa() {
  mkdir -p /etc/openvpn/easy-rsa
  if [[ ! -d /etc/openvpn/easy-rsa/pki ]]; then
    make-cadir /etc/openvpn/easy-rsa >/dev/null 2>&1 || true
    cd /etc/openvpn/easy-rsa
    ./easyrsa init-pki
    echo | ./easyrsa build-ca nopass
    ./easyrsa gen-dh
    ./easyrsa build-server-full server nopass
    ./easyrsa build-client-full client nopass
    openvpn --genkey --secret pki/ta.key
  fi
}

generate_client_config() {
  local proto=$1 port=$2 out=$3
  cat >"$out" <<OVPN
client
dev tun
proto $proto
remote $(curl -s ifconfig.me || echo your-server) $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3
<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>
key-direction 1
<tls-auth>
$(cat /etc/openvpn/easy-rsa/pki/ta.key)
</tls-auth>
OVPN
}

install_openvpn() {
  info "Menyiapkan OpenVPN..."
  setup_easy_rsa
  mkdir -p /etc/openvpn/server
  cat >/etc/openvpn/server/tcp.conf <<OVPN
port $OVPN_TCP_PORT
proto tcp
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
tls-auth /etc/openvpn/easy-rsa/pki/ta.key 0
server 10.8.0.0 255.255.255.0
keepalive 10 120
persist-key
persist-tun
verb 3
status /var/log/openvpn-tcp-status.log
log-append /var/log/openvpn-tcp.log
OVPN
  cat >/etc/openvpn/server/udp.conf <<OVPN
port $OVPN_UDP_PORT
proto udp
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
tls-auth /etc/openvpn/easy-rsa/pki/ta.key 0
server 10.9.0.0 255.255.255.0
keepalive 10 120
persist-key
persist-tun
verb 3
status /var/log/openvpn-udp-status.log
log-append /var/log/openvpn-udp.log
OVPN
  cat >/etc/openvpn/server/ssl.conf <<OVPN
port $OVPN_SSL_PORT
proto tcp
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
tls-auth /etc/openvpn/easy-rsa/pki/ta.key 0
server 10.10.0.0 255.255.255.0
keepalive 10 120
persist-key
persist-tun
verb 3
status /var/log/openvpn-ssl-status.log
log-append /var/log/openvpn-ssl.log
OVPN
  systemctl enable openvpn-server@tcp openvpn-server@udp openvpn-server@ssl || true
  systemctl restart openvpn-server@tcp openvpn-server@udp openvpn-server@ssl || true
  generate_client_config tcp "$OVPN_TCP_PORT" /etc/openvpn/client-tcp.ovpn
  generate_client_config udp "$OVPN_UDP_PORT" /etc/openvpn/client-udp.ovpn
  generate_client_config tcp "$OVPN_SSL_PORT" /etc/openvpn/client-ssl.ovpn
}

update_script() {
  info "Memperbarui layanan dan dependensi..."
  "$(readlink -f "$0")" install
}

openvpn_control() {
  case $1 in
    start) systemctl start openvpn-server@tcp openvpn-server@udp openvpn-server@ssl 2>/dev/null || true ;;
    stop) systemctl stop openvpn-server@tcp openvpn-server@udp openvpn-server@ssl 2>/dev/null || true ;;
    restart) systemctl restart openvpn-server@tcp openvpn-server@udp openvpn-server@ssl 2>/dev/null || true ;;
  esac
  ok "OpenVPN $1 diproses"
}

list_openvpn_clients() {
  ls /etc/openvpn/easy-rsa/pki/issued 2>/dev/null || echo "Belum ada sertifikat client tambahan"
}

regenerate_openvpn_clients() {
  generate_client_config tcp "$OVPN_TCP_PORT" /etc/openvpn/client-tcp.ovpn
  generate_client_config udp "$OVPN_UDP_PORT" /etc/openvpn/client-udp.ovpn
  generate_client_config tcp "$OVPN_SSL_PORT" /etc/openvpn/client-ssl.ovpn
  ok "File client OpenVPN diperbarui"
}

# === BadVPN ===
ensure_badvpn_binary() {
  if command -v badvpn-udpgw >/dev/null 2>&1; then
    return
  fi

  info "Binary badvpn-udpgw tidak ditemukan, mengompilasi dari sumber..."
  tmpdir=$(mktemp -d)
  git clone --depth=1 https://github.com/ambrop72/badvpn.git "$tmpdir" >/dev/null 2>&1
  cmake -S "$tmpdir" -B "$tmpdir/build" -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null
  cmake --build "$tmpdir/build" >/dev/null
  install -m 0755 "$tmpdir/build/udpgw/badvpn-udpgw" /usr/local/bin/badvpn-udpgw
  rm -rf "$tmpdir"
}

install_badvpn() {
  info "Menjalankan BadVPN UDPGW..."
  ensure_badvpn_binary
  local badvpn_bin
  badvpn_bin=$(command -v badvpn-udpgw || echo /usr/local/bin/badvpn-udpgw)
  for p in "${BADVPN_PORTS[@]}"; do
    cat >/etc/systemd/system/badvpn@$p.service <<BAD
[Unit]
Description=BadVPN UDPGW on port $p
After=network.target

[Service]
ExecStart=${badvpn_bin} --listen-addr 0.0.0.0:$p --max-clients 2048
Restart=always

[Install]
WantedBy=multi-user.target
BAD
    systemctl enable badvpn@$p
    systemctl restart badvpn@$p
  done
}

# === WebSocket SSH ===
install_websocket_services() {
  info "Menyiapkan SSH WebSocket..."
  local wss_port
  wss_port=$(ensure_port_available "$SSH_WS_SSL_PORT" tcp) || return 1
  ACTIVE_SSH_WS_SSL_PORT="$wss_port"
  for port in "${SSH_WS_PORTS[@]}"; do
    cat >/etc/systemd/system/ssh-ws@$port.service <<WSS
[Unit]
Description=SSH WebSocket on port $port
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:$port,reuseaddr,fork TCP:127.0.0.1:$OPENSSH_PORT
Restart=always

[Install]
WantedBy=multi-user.target
WSS
    systemctl enable ssh-ws@$port
    systemctl restart ssh-ws@$port
  done
  cat >/etc/systemd/system/ssh-wss.service <<WSL
[Unit]
Description=SSH WebSocket TLS
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:$wss_port,reuseaddr,fork TCP:127.0.0.1:$OPENSSH_PORT
Restart=always

[Install]
WantedBy=multi-user.target
WSL
  systemctl enable ssh-wss
  systemctl restart ssh-wss
}

# === Database util ===
get_service_key() {
  case $1 in
    ssh|vmess|vless|trojan) echo "$1" ;;
    *) error "Service tidak dikenal"; return 1;;
  esac
}

db_upsert_account() {
  local service=$1 user=$2 expire=$3 limit_ip=$4 limit_bw=$5 locked=$6 status=$7 credential=${8:-}
  local key
  key=$(get_service_key "$service")
  if [[ -z "$credential" ]]; then
    credential=$(db_get_account_field "$service" "$user" "credential")
  fi
  jq_overwrite_file "$LOCAL_DB" --arg srv "$key" --arg user "$user" --arg exp "$expire" --arg lip "$limit_ip" --arg lbw "$limit_bw" --arg locked "$locked" --arg status "$status" --arg cred "$credential" '
    .[$srv] = (.[$srv] // [])
    | .[$srv] |= map(select(.user!=$user))
    | .[$srv] += [{"user":$user,"expire":$exp,"limit_ip":$lip,"limit_bw":$lbw,"locked":$locked,"status":$status,"credential":$cred}]
  '
}

db_remove_account() {
  local service=$1 user=$2
  local key
  key=$(get_service_key "$service")
  jq_overwrite_file "$LOCAL_DB" --arg srv "$key" --arg user "$user" '.[$srv] = (.[$srv] // []) | .[$srv] |= map(select(.user!=$user))'
}

db_get_account_field() {
  local service=$1 user=$2 field=$3
  local key
  key=$(get_service_key "$service")
  jq -r --arg srv "$key" --arg user "$user" --arg field "$field" '.[$srv][]? | select(.user==$user) | .[$field]' "$LOCAL_DB"
}

db_update_status() {
  local service=$1 user=$2 status=$3
  local key
  key=$(get_service_key "$service")
  jq_overwrite_file "$LOCAL_DB" --arg srv "$key" --arg user "$user" --arg status "$status" '.[$srv] = (.[$srv] // []) | .[$srv] |= map(if .user==$user then .status=$status else . end)'
}

list_db_accounts() {
  local service=$1
  local key
  key=$(get_service_key "$service")
  jq -r --arg srv "$key" '.[$srv][]? | "\(.user) (expire: \(.expire)) status: \(.status)"' "$LOCAL_DB"
}

db_count_accounts() {
  local service=$1
  local key
  key=$(get_service_key "$service")
  jq -r --arg srv "$key" '.[$srv] // [] | length' "$LOCAL_DB"
}

db_prune_expired() {
  local today
  today=$(date +%s)
  tmp=$(mktemp)
  jq --argjson now "$today" '
    to_entries
    | map(.value |= map(select(.expire == "" or ((try (.expire | fromdateiso8601) catch 0) >= $now))))
    | from_entries
  ' "$LOCAL_DB" >"$tmp" && mv "$tmp" "$LOCAL_DB"
  ok "Data akun kedaluwarsa dibersihkan dari database lokal."
}

# === Backup & Restore ===
backup_configs() {
  mkdir -p "$BACKUP_DIR"
  tar czf "$BACKUP_DIR/backup-$(date +%F-%H%M).tar.gz" /etc/ssh /etc/dropbear "$XRAY_CONFIG" /etc/openvpn "$LOCAL_DB" "$STATE_DIR" || {
    error "Backup gagal."
    return 1
  }
  ok "Backup selesai."
}

restore_configs() {
  local file=$1
  if [[ -f "$file" ]]; then
    tar xzf "$file" -C /
    ok "Restore selesai."
  else
    error "File backup tidak ditemukan."
  fi
}

send_backup_to_telegram() {
  ensure_telegram_configured || return 1
  local latest
  latest=$(ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -n1)
  [[ -z "$latest" ]] && { error "Tidak ada backup"; return 1; }
  curl -s -F chat_id="$TELEGRAM_CHAT_ID" -F document=@"$latest" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" >/dev/null || error "Kirim backup gagal"
}

configure_telegram_bot() {
  read -rp "Masukkan TELEGRAM_BOT_TOKEN: " TELEGRAM_BOT_TOKEN
  read -rp "Masukkan TELEGRAM_CHAT_ID: " TELEGRAM_CHAT_ID
  set_state telegram_bot_token "$TELEGRAM_BOT_TOKEN"
  set_state telegram_chat_id "$TELEGRAM_CHAT_ID"
  ok "Konfigurasi Telegram disimpan."
}

auto_backup_setup() {
  ensure_permission
  ensure_telegram_configured || return 1
  mkdir -p "$BACKUP_DIR"
  cat >/etc/cron.d/auto-backup-tunnel <<CRON
0 */$AUTO_BACKUP_INTERVAL_HOURS * * * root $(readlink -f "$0") --auto-backup
CRON
  systemctl restart cron
  ok "Auto backup dijadwalkan tiap $AUTO_BACKUP_INTERVAL_HOURS jam"
}

# === Monitoring & Utilitas ===
check_service_status() {
  systemctl is-active --quiet "$1" && ok "$1 aktif" || error "$1 tidak aktif"
}

show_service_info() {
  line
  echo "Info Service Port"
  line
  echo "OpenSSH        : $OPENSSH_PORT"
  echo "Dropbear       : $DROPBEAR_PORT1, $DROPBEAR_PORT2"
  echo "Dropbear WS    : $ACTIVE_DROPBEAR_WS_PORT1, $ACTIVE_DROPBEAR_WS_PORT2"
  echo "SSH over UDP   : $(tr '\n' ' ' <"$SSH_UDP_STATE_FILE" 2>/dev/null || echo "$SSH_UDP_DEFAULT_PORT")"
  echo "OpenVPN SSL    : $OVPN_SSL_PORT"
  echo "OpenVPN TCP    : $OVPN_TCP_PORT"
  echo "OpenVPN UDP    : $OVPN_UDP_PORT"
  echo "BadVPN UDPGW   : ${BADVPN_PORTS[*]}"
  echo "SSH WS         : ${SSH_WS_PORTS[*]}"
  echo "SSH WS SSL     : $ACTIVE_SSH_WS_SSL_PORT"
  echo "XRAY (VMESS)   : $XRAY_VMESS_PORT"
  echo "XRAY (VLESS)   : $XRAY_VLESS_PORT"
  echo "XRAY (TROJAN)  : $XRAY_TROJAN_PORT"
  line
}

information_system() {
  line; echo "Information System"; line
  echo "OS      : $(lsb_release -sd 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d'=' -f2- | tr -d '"')"
  echo "Kernel  : $(uname -r)"
  echo "CPU     : $(lscpu | awk -F: '/Model name/ {print $2; exit}' | xargs)"
  echo "RAM     : $(free -m | awk '/Mem:/ {print $2" MB"}')"
  echo "Disk    : $(df -h / | awk 'NR==2 {print $3"/"$2" ("$5")"}')"
  echo "Uptime  : $(uptime -p | cut -d' ' -f2-)"
  echo "IP      : $(hostname -I | awk '{print $1}')"
  echo "CITY    : $(get_city)"
  echo "ISP     : $(get_isp)"
}

list_open_source_info() {
  line; echo "Open Source & Sewa Script"; line
  echo "Sumber script diadaptasi untuk kebutuhan legal administrasi server."
  echo "Anda dapat menyesuaikan lisensi/klien di $STATE_FILE (CLIENT_LABEL/VERSION_LABEL)."
}

troubleshooting_menu() {
  line
  echo "Troubleshooting"
  line
  for svc in ssh dropbear xray openvpn-server@tcp openvpn-server@udp openvpn-server@ssl ssh-ws@80 ssh-wss; do
    check_service_status "$svc"
  done
  echo "Port listening:"; ss -tulwn | grep -E "(:22|:143|:109|:443|:1194|:2200|:7100|:7300|:80|:8080)" || true
  if command -v jq >/dev/null; then
    jq empty "$XRAY_CONFIG" && ok "Konfig Xray valid" || error "Konfig Xray bermasalah"
  fi
  tail -n 10 /var/log/xray/access.log 2>/dev/null || true
  tail -n 10 /var/log/auth.log 2>/dev/null || true
  journalctl -u openvpn-server@tcp -n 5 --no-pager 2>/dev/null || true
}

logs_menu() {
  echo "Log Xray:"; tail -n 20 /var/log/xray/error.log 2>/dev/null
  echo "Log SSH:"; tail -n 20 /var/log/auth.log 2>/dev/null
  echo "Log OpenVPN:"; journalctl -u openvpn-server@tcp -n 20 --no-pager 2>/dev/null
}

running_services() {
  line; echo "Running Service"; line
  local services=(ssh dropbear xray openvpn-server@tcp openvpn-server@udp openvpn-server@ssl ssh-ws@80 ssh-ws@8080 ssh-wss dropbear-ws dropbear-ws109 badvpn@7100 badvpn@7300)
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc"; then
      ok "$svc aktif"
    else
      error "$svc tidak aktif"
    fi
  done
  echo "Port penting:"; ss -tulwn | grep -E "(:22|:143|:109|:${ACTIVE_DROPBEAR_WS_PORT1}|:${ACTIVE_DROPBEAR_WS_PORT2}|:443|:1194|:2200|:7100|:7300|:80|:8080)" || true
}

restart_all_services() {
  line; echo "Restart semua layanan"; line
  local services=(ssh dropbear xray openvpn-server@tcp openvpn-server@udp openvpn-server@ssl ssh-ws@80 ssh-ws@8080 ssh-wss dropbear-ws dropbear-ws109 badvpn@7100 badvpn@7300)
  for svc in "${services[@]}"; do
    systemctl restart "$svc" 2>/dev/null && ok "$svc direstart" || error "$svc gagal direstart atau tidak ada"
  done
}

configure_autoreboot() {
  read -rp "Jadwalkan reboot setiap berapa jam? (mis. 12): " hours
  [[ -z "$hours" ]] && return
  cat >/etc/cron.d/autoreboot-tunnel <<CRON
0 */$hours * * * root /sbin/reboot
CRON
  systemctl restart cron
  set_state "autoreboot" "setiap ${hours} jam"
  ok "Autoreboot dijadwalkan tiap $hours jam"
}

run_speedtest() {
  if ! command -v speedtest-cli >/dev/null 2>&1; then
    info "Menginstal speedtest-cli..."
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest-cli || { error "Gagal memasang speedtest-cli"; return 1; }
  fi
  speedtest-cli --simple || error "Speedtest gagal dijalankan"
}

monitoring_info() {
  line; echo "Monitoring"; line
  echo "Load Average : $(uptime | awk -F'load average:' '{print $2}')"
  free -m | awk '/Mem:/ {print "Memory Used : "$3"MB/"$2"MB"}'
  df -h / | awk 'NR==2 {print "Disk Root   : "$3"/"$2" ("$5")"}'
  ps -eo pid,comm,%mem,%cpu --sort=-%cpu | head -n 6
}

change_banner() {
  read -rp "Masukkan teks banner baru: " banner
  [[ -z "$banner" ]] && return
  echo "$banner" >/etc/issue
  echo "$banner" >/etc/motd
  ok "Banner diubah."
}

add_domain() {
  read -rp "Masukkan domain: " domain
  [[ -z "$domain" ]] && return
  echo "$domain" >"$STATE_DIR/domain"
  ok "Domain tersimpan di $STATE_DIR/domain"
}

fix_haproxy() {
  if systemctl list-unit-files | grep -q '^haproxy'; then
    systemctl restart haproxy && ok "HAProxy direstart" || error "Gagal restart HAProxy"
  else
    error "HAProxy tidak terpasang"
  fi
}

fix_nginx() {
  if systemctl list-unit-files | grep -q '^nginx'; then
    nginx -t && systemctl restart nginx && ok "Nginx dicek & direstart" || error "Nginx gagal diperbaiki"
  else
    error "Nginx tidak terpasang"
  fi
}

configure_haproxy() {
  local domain=$1
  if ! command -v haproxy >/dev/null 2>&1; then
    error "HAProxy belum terpasang; jalankan 'tunnelctl install' untuk memasang dependensi."
    return 1
  fi

  cat >/etc/haproxy/haproxy.cfg <<HAP
global
  log /dev/log    local0
  log /dev/log    local1 notice
  chroot /var/lib/haproxy
  stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
  stats timeout 30s
  user haproxy
  group haproxy
  daemon

defaults
  log     global
  mode    http
  option  httplog
  option  dontlognull
  timeout connect 5s
  timeout client  50s
  timeout server  50s

frontend https_in
  bind *:443 ssl crt /etc/ssl/xray.pem alpn h2,http/1.1
  http-request set-header X-Forwarded-Proto https
  http-request set-header X-Forwarded-Host %[req.hdr(host)]
  acl is_vmess path_beg -i /vmess
  acl is_vless path_beg -i /vless
  use_backend vmess_ws if is_vmess
  use_backend vless_ws if is_vless
  default_backend vmess_ws

frontend http_in
  bind *:80
  mode http
  http-request set-header X-Forwarded-Proto http
  http-request redirect scheme https code 301 if !{ ssl_fc }

backend vmess_ws
  option http-server-close
  server xray_vmess 127.0.0.1:${XRAY_VMESS_PORT} ssl verify none alpn h2,http/1.1

backend vless_ws
  option http-server-close
  server xray_vless 127.0.0.1:${XRAY_VLESS_PORT} ssl verify none alpn h2,http/1.1
HAP

  systemctl enable haproxy
  systemctl restart haproxy
  ok "Konfigurasi HAProxy diterapkan untuk domain ${domain}"
}

configure_nginx() {
  local domain=$1
  if ! command -v nginx >/dev/null 2>&1; then
    error "Nginx belum terpasang; jalankan 'tunnelctl install' untuk memasang dependensi."
    return 1
  fi

  cat >/etc/nginx/sites-available/tunnel <<NGX
server {
  listen 80 default_server;
  server_name ${domain} _;

  location /health {
    return 200 'ok';
    add_header Content-Type text/plain;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}
NGX

  ln -sf /etc/nginx/sites-available/tunnel /etc/nginx/sites-enabled/tunnel
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  ok "Konfigurasi Nginx diterapkan untuk domain ${domain}"
}

fix_xray_service() {
  systemctl restart xray && ok "XRAY direstart" || error "XRAY gagal direstart"
}

fix_ws_layer() {
  systemctl restart dropbear-ws dropbear-ws109 ssh-ws@80 ssh-ws@8080 ssh-wss 2>/dev/null || true
  ok "Layanan WebSocket dicoba perbaiki."
}

fix_domain_layer() {
  if [[ -f "$STATE_DIR/domain" ]]; then
    local domain
    domain=$(cat "$STATE_DIR/domain")
    if ! grep -q "$domain" /etc/hosts; then
      echo "127.0.0.1 ${domain}" >>/etc/hosts
    fi
    ok "Entry domain diperbarui"
  else
    error "Belum ada domain yang tersimpan"
  fi
}

clear_cache() {
  apt-get clean >/dev/null 2>&1 || true
  journalctl --rotate >/dev/null 2>&1 || true
  ok "Cache package dan jurnal diputar."
}

clear_logs() {
  : >/var/log/xray/access.log 2>/dev/null || true
  : >/var/log/xray/error.log 2>/dev/null || true
  : >/var/log/auth.log 2>/dev/null || true
  ok "Log utama dibersihkan."
}

clear_cache_files() {
  rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
  ok "Cache file sementara dibersihkan."
}

apply_anti_ddos() {
  cat >/etc/sysctl.d/99-tunnel-anti-ddos.conf <<SYS
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
SYS
  sysctl -p /etc/sysctl.d/99-tunnel-anti-ddos.conf >/dev/null 2>&1 || true
  iptables -I INPUT -p tcp --syn -m limit --limit 50/s -j ACCEPT || true
  iptables -I INPUT -p icmp -m limit --limit 10/s -j ACCEPT || true
  set_state anti_ddos on
  ok "Rule anti-DDoS dasar diterapkan."
}

limit_speed_control() {
  read -rp "Batasi kecepatan (Mbps, kosong untuk hapus): " speed
  if [[ -z "$speed" ]]; then
    tc qdisc del dev eth0 root 2>/dev/null || true
    set_state limit_speed off
    ok "Limit speed dinonaktifkan"
  else
    tc qdisc replace dev eth0 root tbf rate ${speed}mbit burst 32kbit latency 400ms 2>/dev/null || true
    set_state limit_speed "${speed}Mbps"
    ok "Limit speed diset ke ${speed}Mbps"
  fi
}

limit_xray_toggle() {
  local state
  state=$(get_state limit_conn_xray off)
  [[ "$state" == "on" ]] && state="off" || state="on"
  set_state limit_conn_xray "$state"
  ok "Limit koneksi XRAY diubah ke $state"
}

booster_cpu() {
  cat >/etc/sysctl.d/99-tunnel-bbr.conf <<SYS
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
  sysctl -p /etc/sysctl.d/99-tunnel-bbr.conf >/dev/null 2>&1 || true
  set_state limit_conn_multi on
  ok "Booster CPU/BBR diaktifkan (jika kernel mendukung)."
}

delete_all_expired_accounts() {
  db_prune_expired
  local today
  today=$(date +%s)
  awk -F: '{print $1" "$8}' /etc/shadow | while read -r user expire; do
    [[ -z "$expire" || "$expire" == "" || "$expire" == "99999" ]] && continue
    if (( expire>0 )); then
      local date
      date=$(date -d "1970-01-01 + $expire days" +%s)
      if (( date < today )); then
        userdel -r "$user" 2>/dev/null || true
        ok "User $user dihapus karena kadaluarsa"
      fi
    fi
  done
}

admin_features_menu() {
  while true; do
    line; echo "FEATURES ADMIN"; line
    echo "1. Anti-DDoS Protection ($(get_state anti_ddos off))"
    echo "2. Limit Speed ($(get_state limit_speed off))"
    echo "3. Limit Quota ($(get_state limit_quota off))"
    echo "4. Limit Conn XRAY ($(get_state limit_conn_xray off))"
    echo "5. Limit Conn UDP ($(get_state limit_conn_udp off))"
    echo "6. Multi-threading Guard ($(get_state limit_conn_multi off))"
    echo "b. Kembali"
    echo "x. Keluar"
    read -rp "Pilih: " opt
    case $opt in
      1) apply_anti_ddos;;
      2) limit_speed_control;;
      3) set_state limit_quota on; ok "Limit quota dicatat (implementasi sederhana).";;
      4) limit_xray_toggle;;
      5) set_state limit_conn_udp on; ok "Limit koneksi UDP dicatat.";;
      6) booster_cpu;;
      b|B) return;;
      x|X) exit 0;;
    esac
  done
}

stub_slowdns() { info "SLOWDNS belum tersedia, menu disiapkan untuk kompatibilitas."; }
stub_noobzvpn() { info "NOOBZVPNS belum tersedia, siapkan script tambahan bila diperlukan."; }
stub_ssr() { info "SS-R belum dikonfigurasi, gunakan stub ini untuk integrasi selanjutnya."; }

show_dashboard() {
  while true; do
    local os ram uptime_info ip domain city isp ping_value proxy_stat nginx_stat xray_stat goodbad bandwidth yesterday today monthly expiry
    os=$(lsb_release -sd 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d'=' -f2- | tr -d '"')
    ram=$(free -m | awk '/Mem:/ {print $2 " MB"}')
    uptime_info=$(uptime -p | cut -d' ' -f2-)
    ip=$(hostname -I | awk '{print $1}')
    domain=$(cat "$STATE_DIR/domain" 2>/dev/null || echo "-")
    city=$(get_city)
    isp=$(get_isp)
    ping_value=$(ping_target "$domain")
    proxy_stat=$(service_on_off ssh-ws@80)
    nginx_stat=$(service_on_off nginx)
    xray_stat=$(service_on_off xray)
    goodbad=$([[ "$xray_stat" == "ON" ]] && echo "GOOD" || echo "BAD")
    if command -v vnstat >/dev/null 2>&1; then
      bandwidth=$(vnstat --oneline 2>/dev/null)
      yesterday=$(echo "$bandwidth" | awk -F';' '{print $9}')
      today=$(echo "$bandwidth" | awk -F';' '{print $10}')
      monthly=$(echo "$bandwidth" | awk -F';' '{print $12}')
    else
      yesterday=tbd; today=tbd; monthly=tbd
    fi
    expiry=$(get_state license_expiry "-")

    line; echo ":::. AUTO TUNNEL MANAGER .:::"; line
    echo "SYSTEM    : ${os:-N/A}"
    echo "RAM       : ${ram:-N/A}"
    echo "UPTIME    : ${uptime_info:-N/A}"
    echo "IP VPS    : ${ip:-N/A}"
    echo "CITY      : ${city:-N/A}"
    echo "ISP       : ${isp:-N/A}"
    echo "DOMAIN    : ${domain}"
    echo "YOUR PING : ${ping_value}"
    line
    echo "PROXY : ${proxy_stat} | NGINX : ${nginx_stat} | XRAY : ${xray_stat} | ${goodbad}"
    echo "SSH/OPENVPN : $(db_count_accounts ssh) | VLESS XRAY : $(db_count_accounts vless) | VMESS XRAY : $(db_count_accounts vmess) | TROJAN XRAY : $(db_count_accounts trojan) | SSR-LIBEV : 0"
    echo "VERSION : ${VERSION_LABEL} | CLIENTS : ${CLIENT_LABEL} | Expiry In : ${expiry}"
    echo "KEMARIN : ${yesterday} | HARI INI : ${today} | BULANAN : ${monthly}"
    line
    cat <<MENU
[01] SSH/OPENVPN
[02] XRAY MANAGER
[03] XRAY TROJAN
[04] SLOWDNS
[05] NOOBZVPNS
[06] SS-R
[07] BOT TELEGRAM
[08] UPDATE SCRIPT
[09] BACKUP RESTORE
[10] FEATURES
[11] FEATURES ADMIN
[x ] EXIT
MENU
    read -rp "Pilih: " opt
    case $opt in
      1|01) show_ssh_menu ;;
      2|02) show_xray_menu ;;
      3|03) show_trojan_menu ;;
      4|04) stub_slowdns ;;
      5|05) stub_noobzvpn ;;
      6|06) stub_ssr ;;
      7|07) configure_telegram_bot ;;
      8|08) update_script ;;
      9|09) show_backup_menu ;;
      10) show_features_menu ;;
      11) admin_features_menu ;;
      x|X) exit 0 ;;
      *) echo "Pilihan tidak dikenal" ;;
    esac
  done
}

# === Menu Akun SSH/Dropbear ===
show_ssh_menu() {
  line; echo "Menu SSH/Dropbear"; line
  cat <<MENU
1. Check Users Login
2. Create Accounts
3. Delete Accounts
4. Renew Accounts
5. Trial Accounts (1 hari)
6. List Member Accounts
7. List Expired Accounts
8. Lock Accounts
9. Unlock Accounts
10. Edit Limit IP Account
11. Limit IP On Off Accounts
12. Auto Kill Accounts
13. Detail Accounts
14. Recovery Accounts
15. Check Login UDP
16. Back to Menu
OVPN-A. Start OpenVPN
OVPN-B. Stop OpenVPN
OVPN-C. Restart OpenVPN
OVPN-D. List OpenVPN Clients
OVPN-E. Regenerate Client Configs
x. Exit
MENU
  read -rp "Pilih: " choice
  case $choice in
    1) list_ssh_logins;;
    2) read -rp "Username: " u; read -rp "Masa aktif (hari): " d; create_ssh_user "$u" "$d";;
    3) read -rp "Username: " u; delete_ssh_user "$u";;
    4) read -rp "Username: " u; read -rp "Perpanjang (hari): " d; renew_ssh_user "$u" "$d";;
    5) read -rp "Username: " u; create_ssh_user "$u" 1;;
    6) list_ssh_members;;
    7) list_ssh_expired;;
    8) read -rp "Username: " u; lock_ssh_user "$u";;
    9) read -rp "Username: " u; unlock_ssh_user "$u";;
    10) read -rp "Username: " u; read -rp "Limit IP: " l; edit_ssh_limit_ip "$u" "$l";;
    11) read -rp "Username: " u; toggle_limit_ip "$u";;
    12) auto_kill_multilogin;;
    13) read -rp "Username: " u; show_account_detail "$u";;
    14) read -rp "Username: " u; recover_account "$u";;
    15) check_login_udp;;
    16) return;;
    OVPN-A|ovpn-a) openvpn_control start;;
    OVPN-B|ovpn-b) openvpn_control stop;;
    OVPN-C|ovpn-c) openvpn_control restart;;
    OVPN-D|ovpn-d) list_openvpn_clients;;
    OVPN-E|ovpn-e) regenerate_openvpn_clients;;
    x|X) exit 0;;
  esac
}

# === Menu XRAY VMESS/VLESS ===
show_xray_menu() {
  line; echo "Menu XRAY VMESS/VLESS"; line
  cat <<MENU
1. Check Users Login
2. List Member
3. Create Account Vmess
4. Trial Account Vmess
5. Delete Account Vmess
6. Renew Account Vmess
7. Check Config Account
8. Recovery Account
9. Edit Limit IP Account (DB only)
10. Edit Limit Bandwidth Account (DB only)
11. Lock Account (DB only)
12. Unlock Account
13. Create Account Vless
14. Trial Account Vless
15. Delete Account Vless
16. Renew Account Vless
17. Check Config Account
18. Recovery Account
19. Edit Limit IP Account (DB only)
20. Edit Limit Bandwidth Account (DB only)
21. Lock Account (DB only)
22. Unlock Account
23. Back to Menu
x. Exit
MENU
  read -rp "Pilih: " choice
  case $choice in
    1) journalctl -u xray -n 20 --no-pager | grep "accepted" || true ;;
    2) list_db_accounts vmess; list_db_accounts vless;;
    3) read -rp "Username: " u; read -rp "Masa aktif (hari): " d; add_xray_client vmess "$u" "$(generate_uuid)" "$(date -d "+$d days" +%Y-%m-%d)";;
    4) read -rp "Username: " u; add_xray_client vmess "$u" "$(generate_uuid)" "$(date -d "+1 day" +%Y-%m-%d)";;
    5) read -rp "Username: " u; remove_xray_client vmess "$u";;
    6) read -rp "Username: " u; read -rp "Perpanjang (hari): " d; renew_xray_client vmess "$u" "$d";;
    7) read -rp "Username: " u; show_xray_config_account vmess "$u";;
    8) read -rp "Username: " u; recover_xray_account vmess "$u";;
    9) read -rp "Username: " u; read -rp "Limit IP: " l; db_upsert_account vmess "$u" "" "$l" "" "false" "active";;
    10) read -rp "Username: " u; read -rp "Limit Bandwidth: " l; db_upsert_account vmess "$u" "" "" "$l" "false" "active";;
    11) read -rp "Username: " u; db_update_status vmess "$u" "locked";;
    12) read -rp "Username: " u; db_update_status vmess "$u" "active";;
    13) read -rp "Username: " u; read -rp "Masa aktif (hari): " d; add_xray_client vless "$u" "$(generate_uuid)" "$(date -d "+$d days" +%Y-%m-%d)";;
    14) read -rp "Username: " u; add_xray_client vless "$u" "$(generate_uuid)" "$(date -d "+1 day" +%Y-%m-%d)";;
    15) read -rp "Username: " u; remove_xray_client vless "$u";;
    16) read -rp "Username: " u; read -rp "Perpanjang (hari): " d; renew_xray_client vless "$u" "$d";;
    17) read -rp "Username: " u; show_xray_config_account vless "$u";;
    18) read -rp "Username: " u; recover_xray_account vless "$u";;
    19) read -rp "Username: " u; read -rp "Limit IP: " l; db_upsert_account vless "$u" "" "$l" "" "false" "active";;
    20) read -rp "Username: " u; read -rp "Limit Bandwidth: " l; db_upsert_account vless "$u" "" "" "$l" "false" "active";;
    21) read -rp "Username: " u; db_update_status vless "$u" "locked";;
    22) read -rp "Username: " u; db_update_status vless "$u" "active";;
    23) return;;
    x|X) exit 0;;
  esac
}

# === Menu XRAY TROJAN ===
show_trojan_menu() {
  line; echo "Menu XRAY TROJAN"; line
  cat <<MENU
1. Check Users Login
2. List Member Trojan
3. Create Account Trojan
4. Trial Account Trojan
5. Delete Account Trojan
6. Renew Account Trojan
7. Check Config Account
8. Recovery Account
9. Edit Limit IP Account (DB only)
10. Edit Limit Bandwidth Account (DB only)
11. Lock Account (DB only)
12. Unlock Account
13. Back to Menu
x. Exit
MENU
  read -rp "Pilih: " choice
  case $choice in
    1) journalctl -u xray -n 20 --no-pager | grep "accepted" || true ;;
    2) list_db_accounts trojan;;
    3) read -rp "Username: " u; read -rp "Masa aktif (hari): " d; add_xray_client trojan "$u" "$(generate_random_password)" "$(date -d "+$d days" +%Y-%m-%d)";;
    4) read -rp "Username: " u; add_xray_client trojan "$u" "$(generate_random_password)" "$(date -d "+1 day" +%Y-%m-%d)";;
    5) read -rp "Username: " u; remove_xray_client trojan "$u";;
    6) read -rp "Username: " u; read -rp "Perpanjang (hari): " d; renew_xray_client trojan "$u" "$d";;
    7) read -rp "Username: " u; show_xray_config_account trojan "$u";;
    8) read -rp "Username: " u; recover_xray_account trojan "$u";;
    9) read -rp "Username: " u; read -rp "Limit IP: " l; db_upsert_account trojan "$u" "" "$l" "" "false" "active";;
    10) read -rp "Username: " u; read -rp "Limit Bandwidth: " l; db_upsert_account trojan "$u" "" "" "$l" "false" "active";;
    11) read -rp "Username: " u; db_update_status trojan "$u" "locked";;
    12) read -rp "Username: " u; db_update_status trojan "$u" "active";;
    13) return;;
    x|X) exit 0;;
  esac
}

show_backup_menu() {
  line; echo "Menu Backup/Restore"; line
  cat <<MENU
1. Backup Configs
2. Restore Configs
3. Kirim Backup ke Telegram
4. Jadwalkan Auto Backup
5. Back to Menu
MENU
  read -rp "Pilih: " choice
  case $choice in
    1) backup_configs;;
    2) read -rp "File: " f; restore_configs "$f";;
    3) send_backup_to_telegram;;
    4) auto_backup_setup;;
    5) return;;
    x|X) exit 0;;
  esac
}

show_information_menu() {
  show_service_info
}

show_features_menu() {
  line; echo "Fitur"; line
  cat <<MENU
1. Running Service
2. Restart Service
3. Auto Reboot
4. Monitoring
5. SpeedTest
6. Delete All Account Exp
7. Change Banner
8. Change Domain
9. Fixx Haproxy
10. Fixx Nginx
11. Fixx WS ePRO
12. Fixx Domain
13. Fixx Xray
14. Clear Cache
15. Clear Logs
16. Clear Cache File
17. Info Service Port
18. Information System
19. List Open Source & List Sewa Script
20. Anti-DDoS Protection
21. Script Other
22. Limit Speed
23. Limit-on-off XRAY
24. Booster CPU (multi-threading)
25. Back to Menu
x. Exit
MENU
  read -rp "Pilih: " choice
  case $choice in
    1) running_services;;
    2) restart_all_services;;
    3) configure_autoreboot;;
    4) monitoring_info;;
    5) run_speedtest;;
    6) delete_all_expired_accounts;;
    7) change_banner;;
    8) add_domain;;
    9) fix_haproxy;;
    10) fix_nginx;;
    11) fix_ws_layer;;
    12) fix_domain_layer;;
    13) fix_xray_service;;
    14) clear_cache;;
    15) clear_logs;;
    16) clear_cache_files;;
    17) show_service_info;;
    18) information_system;;
    19) list_open_source_info;;
    20) apply_anti_ddos;;
    21) configure_ssh_udp_menu;;
    22) limit_speed_control;;
    23) limit_xray_toggle;;
    24) booster_cpu;;
    25) return;;
    x|X) exit 0;;
  esac
}

show_main_menu() { show_dashboard; }

# === Entry Point ===
case "${1:-menu}" in
  --auto-backup)
    check_root; check_os; check_arch; init_state; ensure_permission; ensure_telegram_configured
    backup_configs && send_backup_to_telegram
    ;;
  install)
    check_root; check_os; check_arch; init_state; ensure_permission
    install_dependencies
    install_openssh
    install_dropbear
    install_dropbear_ws
    install_ssh_udp_template
    start_ssh_udp "$SSH_UDP_DEFAULT_PORT"
    install_xray
    install_openvpn
    install_badvpn
    install_websocket_services
    open_firewall_ports
    ok "Instalasi selesai."
    ;;
  menu|*)
    check_root; check_os; check_arch; init_state; ensure_permission
    show_dashboard
    ;;
esac
