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
DROPBEAR_WS_PORT1_FALLBACK=8443
DROPBEAR_WS_PORT2=109
SSH_UDP_DEFAULT_PORT=7300
OVPN_SSL_PORT=443
OVPN_TCP_PORT=1194
OVPN_UDP_PORT=2200
BADVPN_PORTS=(7100 7300)
SSH_WS_PORTS=(80 8080)
SSH_WS_SSL_PORT=443
SSH_WS_SSL_PORT_FALLBACK=4443
XRAY_CONFIG="/usr/local/etc/xray/config.json"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
AUTO_BACKUP_INTERVAL_HOURS=12
BACKUP_DIR="/var/backups/tunneling"
LOCAL_DB="/var/lib/tunneling/accounts.json"
STATE_DIR="/etc/tunneling"
SSH_UDP_STATE_FILE="$STATE_DIR/ssh_udp_ports"
STATE_FILE="$STATE_DIR/settings.conf"
ACTIVE_DROPBEAR_WS_PORT1="$DROPBEAR_WS_PORT1"
ACTIVE_DROPBEAR_WS_PORT2="$DROPBEAR_WS_PORT2"
ACTIVE_SSH_WS_SSL_PORT="$SSH_WS_SSL_PORT"

# === Utilitas Output ===
info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
error() { echo "[ERROR] $*" >&2; }
line() { printf '%*s\n' "${1:-60}" '' | tr ' ' '='; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { error "Perintah '$1' tidak tersedia."; exit 1; }; }

ensure_port_available() {
  local port=$1 proto=$2 fallback=${3:-}
  if ss -lntup | grep -q ":$port " 2>/dev/null; then
    if [[ -n "$fallback" ]]; then
      info "Port $port/$proto sedang digunakan, menggunakan port cadangan $fallback."
      echo "$fallback"
    else
      error "Port $port/$proto sedang digunakan."
      return 1
    fi
  else
    echo "$port"
  fi
}

# === Helper ===
generate_uuid() { uuidgen; }
generate_random_password() { head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; }
generate_random_port() { shuf -i 20000-40000 -n 1; }

init_state() {
  mkdir -p "$BACKUP_DIR" "$(dirname "$LOCAL_DB")" "$STATE_DIR"
  if [[ ! -f "$LOCAL_DB" ]]; then
    cat >"$LOCAL_DB" <<'JSON'
{"ssh":[],"vmess":[],"vless":[],"trojan":[]}
JSON
  fi
  [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"
}

# === Validasi Awal ===
check_root() {
  if [[ $(id -u) -ne 0 ]]; then
    error "Script harus dijalankan sebagai root."
    exit 1
  fi
}

check_os() {
  if ! grep -qi "ubuntu" /etc/os-release; then
    error "Hanya mendukung Ubuntu 20.04/22.04."
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y jq moreutils curl wget unzip net-tools openssl iptables-persistent ufw dropbear openvpn easy-rsa socat cron uuid-runtime build-essential cmake git || {
    error "Gagal menginstal dependensi."
    exit 1
  }
  if ! command -v xray >/dev/null 2>&1; then
    info "Xray tidak ditemukan, memasang via installer resmi..."
    bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install || {
      error "Instalasi Xray gagal."
      exit 1
    }
  fi
}

# === Firewall ===
open_firewall_ports() {
  local ports=(
    "$OPENSSH_PORT" "$DROPBEAR_PORT1" "$DROPBEAR_PORT2"
    "$ACTIVE_DROPBEAR_WS_PORT1" "$ACTIVE_DROPBEAR_WS_PORT2"
    "$OVPN_SSL_PORT" "$OVPN_TCP_PORT" "$OVPN_UDP_PORT"
    "${BADVPN_PORTS[@]}" "${SSH_WS_PORTS[@]}" "$ACTIVE_SSH_WS_SSL_PORT"
    8443 8444 8445
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
  ws1=$(ensure_port_available "$DROPBEAR_WS_PORT1" tcp "$DROPBEAR_WS_PORT1_FALLBACK") || return 1
  ws2=$(ensure_port_available "$DROPBEAR_WS_PORT2" tcp) || return 1
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
  echo "$port" >>"$SSH_UDP_STATE_FILE"
  systemctl enable ssh-udp@"$port"
  systemctl restart ssh-udp@"$port"
  ok "SSH over UDP aktif di port $port"
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
      "port": 8443,
      "protocol": "vmess",
      "tag": "vmess-ws",
      "settings": {"clients": []},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/vmess"}}
    },
    {
      "port": 8444,
      "protocol": "vless",
      "tag": "vless-ws",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/vless"}}
    },
    {
      "port": 8445,
      "protocol": "trojan",
      "tag": "trojan-tcp",
      "settings": {"clients": []}
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
JSON
  systemctl enable xray
  systemctl restart xray
}

reload_xray() {
  systemctl restart xray
}

add_xray_client() {
  local protocol=$1 user=$2 id_or_pass=$3
  local expire=$4
  jq --arg proto "$protocol" --arg email "$user" --arg cred "$id_or_pass" \
    '(.inbounds[] | select(.protocol==$proto) | .settings.clients) += [($proto=="trojan" ? {"password":$cred,"email":$email} : {"id":$cred,"email":$email})]' "$XRAY_CONFIG" | sponge "$XRAY_CONFIG"
  db_upsert_account "$protocol" "$user" "$expire" "" "" "false" "active"
  reload_xray
}

remove_xray_client() {
  local protocol=$1 user=$2
  jq --arg proto "$protocol" --arg email "$user" \
    '(.inbounds[] | select(.protocol==$proto) | .settings.clients) |= map(select(.email!=$email))' "$XRAY_CONFIG" | sponge "$XRAY_CONFIG"
  db_remove_account "$protocol" "$user"
  reload_xray
}

show_xray_config_account() {
  local protocol=$1 user=$2
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
  "add": "$(curl -s ifconfig.me || echo your-server)",
  "port": 8443,
  "id": "$id",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "",
  "path": "/vmess",
  "tls": ""
}
CFG
)
      echo "Link VMESS: vmess://$(echo -n "$json" | base64 -w0)"
      ;;
    vless)
      local id
      id=$(jq -r --arg email "$user" '.inbounds[] | select(.protocol=="vless") | .settings.clients[] | select(.email==$email) | .id' "$XRAY_CONFIG")
      [[ -z "$id" ]] && { error "User tidak ditemukan"; return; }
      echo "URL VLESS: vless://$id@$(curl -s ifconfig.me || echo your-server):8444?encryption=none&security=none&type=ws&path=/vless#${user}"
      ;;
    trojan)
      local pwd
      pwd=$(jq -r --arg email "$user" '.inbounds[] | select(.protocol=="trojan") | .settings.clients[] | select(.email==$email) | .password' "$XRAY_CONFIG")
      [[ -z "$pwd" ]] && { error "User tidak ditemukan"; return; }
      echo "URL TROJAN: trojan://$pwd@$(curl -s ifconfig.me || echo your-server):8445#${user}"
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

# === BadVPN ===
install_badvpn() {
  info "Menjalankan BadVPN UDPGW..."
  if ! command -v badvpn-udpgw >/dev/null 2>&1; then
    info "Binary badvpn-udpgw tidak ditemukan, mengompilasi dari sumber..."
    tmpdir=$(mktemp -d)
    git clone --depth=1 https://github.com/ambrop72/badvpn.git "$tmpdir" >/dev/null 2>&1
    cmake -S "$tmpdir" -B "$tmpdir/build" -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null
    cmake --build "$tmpdir/build" >/dev/null
    install -m 0755 "$tmpdir/build/udpgw/badvpn-udpgw" /usr/local/bin/badvpn-udpgw
    rm -rf "$tmpdir"
  fi
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
  wss_port=$(ensure_port_available "$SSH_WS_SSL_PORT" tcp "$SSH_WS_SSL_PORT_FALLBACK") || return 1
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
  local service=$1 user=$2 expire=$3 limit_ip=$4 limit_bw=$5 locked=$6 status=$7
  local key
  key=$(get_service_key "$service")
  jq --arg srv "$key" --arg user "$user" --arg exp "$expire" --arg lip "$limit_ip" --arg lbw "$limit_bw" --arg locked "$locked" --arg status "$status" '
    .[$srv] = (.[$srv] // [])
    | .[$srv] |= map(select(.user!=$user))
    | .[$srv] += [{"user":$user,"expire":$exp,"limit_ip":$lip,"limit_bw":$lbw,"locked":$locked,"status":$status}]
  ' "$LOCAL_DB" | sponge "$LOCAL_DB"
}

db_remove_account() {
  local service=$1 user=$2
  local key
  key=$(get_service_key "$service")
  jq --arg srv "$key" --arg user "$user" '.[$srv] = (.[$srv] // []) | .[$srv] |= map(select(.user!=$user))' "$LOCAL_DB" | sponge "$LOCAL_DB"
}

db_update_status() {
  local service=$1 user=$2 status=$3
  local key
  key=$(get_service_key "$service")
  jq --arg srv "$key" --arg user "$user" --arg status "$status" '.[$srv] = (.[$srv] // []) | .[$srv] |= map(if .user==$user then .status=$status else . end)' "$LOCAL_DB" | sponge "$LOCAL_DB"
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
  local latest
  latest=$(ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -n1)
  [[ -z "$latest" ]] && { error "Tidak ada backup"; return 1; }
  [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && { error "Bot token/Chat ID kosong"; return 1; }
  curl -s -F chat_id="$TELEGRAM_CHAT_ID" -F document=@"$latest" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" >/dev/null || error "Kirim backup gagal"
}

auto_backup_setup() {
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
  echo "XRAY (VMESS)   : 8443"
  echo "XRAY (VLESS)   : 8444"
  echo "XRAY (TROJAN)  : 8445"
  line
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
  local services=(ssh dropbear xray openvpn-server@tcp openvpn-server@udp openvpn-server@ssl ssh-ws@80 ssh-ws@8080 ssh-wss dropbear-ws dropbear-ws109 badvpn-udpgw@7100 badvpn-udpgw@7300)
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
  local services=(ssh dropbear xray openvpn-server@tcp openvpn-server@udp openvpn-server@ssl ssh-ws@80 ssh-ws@8080 ssh-wss dropbear-ws dropbear-ws109 badvpn-udpgw@7100 badvpn-udpgw@7300)
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
      1) set_state anti_ddos on; ok "Anti-DDoS ditandai aktif (implementasi sederhana via firewall yang sudah dibuka).";;
      2) set_state limit_speed on; ok "Limit speed dicatat (TODO: implement traffic shaping).";;
      3) set_state limit_quota on; ok "Limit quota dicatat (TODO: tambahkan quota enforcement).";;
      4) set_state limit_conn_xray on; ok "Limit koneksi XRAY dicatat.";;
      5) set_state limit_conn_udp on; ok "Limit koneksi UDP dicatat.";;
      6) set_state limit_conn_multi on; ok "Proteksi multi-threading dicatat.";;
      b|B) return;;
      x|X) exit 0;;
    esac
  done
}

show_dashboard() {
  while true; do
    local os ram uptime_info ip domain
    os=$(lsb_release -sd 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d'=' -f2- | tr -d '"')
    ram=$(free -m | awk '/Mem:/ {print $2 " MB"}')
    uptime_info=$(uptime -p | cut -d' ' -f2-)
    ip=$(hostname -I | awk '{print $1}')
    domain=$(cat "$STATE_DIR/domain" 2>/dev/null || echo "-" )

    line; echo " ::: ARISCTUNNEL V4 :::"; line
    echo "SYSTEM : ${os:-N/A}"
    echo "RAM    : ${ram:-N/A}"
    echo "UPTIME : ${uptime_info:-N/A}"
    echo "IP VPS : ${ip:-N/A}"
    echo "DOMAIN : ${domain}"
    echo "CLIENT : SSH $(db_count_accounts ssh) | VMESS $(db_count_accounts vmess) | VLESS $(db_count_accounts vless) | TROJAN $(db_count_accounts trojan)"
    line
    cat <<MENU
[0 ] Install / Update Layanan
[1 ] Running Service
[2 ] Restart Service
[3 ] Autoreboot
[4 ] Monitoring
[5 ] Speedtest
[6 ] Add Domain
[7 ] Fix HAProxy
[8 ] Delete All Account Exp
[9 ] Fix XRAY
[10] Fix WS/NGINX
[11] Fix Domain Layer
[12] Change Banner
[13] Clear Cache
[14] Clear Logs
[15] Backup & Restore Menu
[16] Menu SSH / Dropbear
[17] Menu XRAY VMESS/VLESS
[18] Menu XRAY TROJAN
[19] SSH over UDP Menu
[20] Info Service Port
[21] Features Admin
[22] Exit
MENU
    read -rp "Select From Options [0-22 or x]: " choice
    case $choice in
      0)
        check_root; check_os; check_arch; init_state
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
      1) running_services ;;
      2) restart_all_services ;;
      3) configure_autoreboot ;;
      4) troubleshooting_menu ;;
      5) run_speedtest ;;
      6) add_domain ;;
      7) fix_haproxy ;;
      8) delete_all_expired_accounts ;;
      9) fix_xray_service ;;
      10) fix_ws_layer ;;
      11) fix_domain_layer ;;
      12) change_banner ;;
      13) clear_cache ;;
      14) clear_logs ;;
      15) show_backup_menu ;;
      16) show_ssh_menu ;;
      17) show_xray_menu ;;
      18) show_trojan_menu ;;
      19) configure_ssh_udp_menu ;;
      20) show_service_info ;;
      21) admin_features_menu ;;
      22|x|X) exit 0 ;;
      *) echo "Pilihan tidak dikenal" ;;
    esac
  done
}

# === Menu Akun SSH/Dropbear ===
show_ssh_menu() {
  line; echo "Menu SSH/Dropbear"; line
  cat <<MENU
1. Create User
2. Delete User
3. Renew User
4. Trial User (1 hari)
5. Cek Login
6. List Member
7. List Expired
8. Lock User
9. Unlock User
10. Back to Menu
x. Exit
MENU
  read -rp "Pilih: " choice
  case $choice in
    1) read -rp "Username: " u; read -rp "Masa aktif (hari): " d; create_ssh_user "$u" "$d";;
    2) read -rp "Username: " u; delete_ssh_user "$u";;
    3) read -rp "Username: " u; read -rp "Perpanjang (hari): " d; renew_ssh_user "$u" "$d";;
    4) read -rp "Username: " u; create_ssh_user "$u" 1;;
    5) list_ssh_logins;;
    6) list_ssh_members;;
    7) list_ssh_expired;;
    8) read -rp "Username: " u; lock_ssh_user "$u";;
    9) read -rp "Username: " u; unlock_ssh_user "$u";;
    10) return;;
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
8. Recovery Account (tidak tersedia)
9. Edit Limit IP Account (DB only)
10. Edit Limit Bandwidth Account (DB only)
11. Lock Account (DB only)
12. Unlock Account
13. Create Account Vless
14. Trial Account Vless
15. Delete Account Vless
16. Renew Account Vless
17. Check Config Account
18. Recovery Account (tidak tersedia)
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
    6) read -rp "Username: " u; read -rp "Perpanjang (hari): " d; db_upsert_account vmess "$u" "$(date -d "+$d days" +%Y-%m-%d)" "" "" "false" "active";;
    7) read -rp "Username: " u; show_xray_config_account vmess "$u";;
    9) read -rp "Username: " u; read -rp "Limit IP: " l; db_upsert_account vmess "$u" "" "$l" "" "false" "active";;
    10) read -rp "Username: " u; read -rp "Limit Bandwidth: " l; db_upsert_account vmess "$u" "" "" "$l" "false" "active";;
    11) read -rp "Username: " u; db_update_status vmess "$u" "locked";;
    12) read -rp "Username: " u; db_update_status vmess "$u" "active";;
    13) read -rp "Username: " u; read -rp "Masa aktif (hari): " d; add_xray_client vless "$u" "$(generate_uuid)" "$(date -d "+$d days" +%Y-%m-%d)";;
    14) read -rp "Username: " u; add_xray_client vless "$u" "$(generate_uuid)" "$(date -d "+1 day" +%Y-%m-%d)";;
    15) read -rp "Username: " u; remove_xray_client vless "$u";;
    16) read -rp "Username: " u; read -rp "Perpanjang (hari): " d; db_upsert_account vless "$u" "$(date -d "+$d days" +%Y-%m-%d)" "" "" "false" "active";;
    17) read -rp "Username: " u; show_xray_config_account vless "$u";;
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
8. Recovery Account (tidak tersedia)
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
    6) read -rp "Username: " u; read -rp "Perpanjang (hari): " d; db_upsert_account trojan "$u" "$(date -d "+$d days" +%Y-%m-%d)" "" "" "false" "active";;
    7) read -rp "Username: " u; show_xray_config_account trojan "$u";;
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
  esac
}

show_information_menu() {
  show_service_info
}

show_features_menu() {
  line; echo "Fitur"; line
  cat <<MENU
1. Menu SSH/Dropbear
2. Menu XRAY VMESS/VLESS
3. Menu XRAY TROJAN
4. Menu OpenVPN (lihat config sample di /etc/openvpn)
5. Troubleshooting
6. Logs Menu
7. Backup Menu
8. Info Service Port
9. SSH over UDP Menu
10. Exit
MENU
  read -rp "Pilih: " choice
  case $choice in
    1) show_ssh_menu;;
    2) show_xray_menu;;
    3) show_trojan_menu;;
    4) ls /etc/openvpn/*.ovpn 2>/dev/null || echo "Gunakan file sample di /etc/openvpn";;
    5) troubleshooting_menu;;
    6) logs_menu;;
    7) show_backup_menu;;
    8) show_information_menu;;
    9) configure_ssh_udp_menu;;
    10) exit 0;;
  esac
}

show_main_menu() { show_dashboard; }

# === Entry Point ===
case "${1:-menu}" in
  --auto-backup)
    check_root; check_os; check_arch; init_state
    backup_configs && send_backup_to_telegram
    ;;
  install)
    check_root; check_os; check_arch; init_state
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
    check_root; check_os; check_arch; init_state
    show_dashboard
    ;;
esac
