#!/usr/bin/env bash
# auto-tunnel.sh
# Cara menjalankan: chmod +x auto-tunnel.sh && ./auto-tunnel.sh
# Peringatan: Script ini hanya untuk penggunaan legal pada server yang sah.

set -euo pipefail

# === Konstanta & Variabel ===
OPENSSH_PORT=22
DROPBEAR_PORT1=143
DROPBEAR_PORT2=109
DROPBEAR_WS_PORT1=443
DROPBEAR_WS_PORT2=109
SSH_UDP_PORT_RANGE="1-65535"
OVPN_SSL_PORT=443
OVPN_TCP_PORT=1194
OVPN_UDP_PORT=2200
BADVPN_PORTS=(7100 7300)
SSH_WS_PORTS=(80 8080)
SSH_WS_SSL_PORT=443
XRAY_CONFIG="/usr/local/etc/xray/config.json"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
AUTO_BACKUP_INTERVAL_HOURS=12
BACKUP_DIR="/var/backups/tunneling"
LOCAL_DB="/var/lib/tunneling/accounts.db"

# === Utilitas Output ===
info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
error() { echo "[ERROR] $*" >&2; }
line() { printf '%*s\n' "${1:-60}" '' | tr ' ' '='; }

# === Helper ===
generate_uuid() { uuidgen; }
generate_random_password() { head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; }
generate_random_port() { shuf -i 20000-40000 -n 1; }

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
  apt-get update && apt-get install -y jq curl wget unzip net-tools openssl iptables-persistent ufw dropbear openvpn easy-rsa xray socat cron || {
    error "Gagal menginstal dependensi."
    exit 1
  }
}

# === Firewall ===
open_firewall_ports() {
  local ports=("$OPENSSH_PORT" "$DROPBEAR_PORT1" "$DROPBEAR_PORT2" "$DROPBEAR_WS_PORT1" "$DROPBEAR_WS_PORT2" "$OVPN_SSL_PORT" "$OVPN_TCP_PORT" "$OVPN_UDP_PORT" "${BADVPN_PORTS[@]}" "${SSH_WS_PORTS[@]}" "$SSH_WS_SSL_PORT")
  for p in "${ports[@]}"; do
    ufw allow "$p" >/dev/null 2>&1 || true
    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT || true
    iptables -I INPUT -p udp --dport "$p" -j ACCEPT || true
  done
  netfilter-persistent save >/dev/null 2>&1 || true
}

# === OpenSSH ===
install_openssh() {
  info "Mengonfigurasi OpenSSH..."
  sed -i "s/^#Port .*/Port $OPENSSH_PORT/" /etc/ssh/sshd_config
  systemctl enable ssh
  systemctl restart ssh || systemctl restart sshd
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
  cat >/etc/systemd/system/dropbear-ws.service <<WS
[Unit]
Description=Dropbear WebSocket Proxy
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:$DROPBEAR_WS_PORT1,reuseaddr,fork TCP:127.0.0.1:$DROPBEAR_PORT1
Restart=always

[Install]
WantedBy=multi-user.target
WS
  systemctl daemon-reload
  systemctl enable dropbear-ws
  systemctl restart dropbear-ws
}

# === SSH over UDP (placeholder) ===
install_ssh_udp() {
  info "Menyiapkan SSH over UDP (placeholder)."
  cat >/etc/systemd/system/ssh-udp.service <<UDP
[Unit]
Description=SSH over UDP Forwarder
After=network.target

[Service]
ExecStart=/usr/bin/socat UDP-LISTEN:${SSH_UDP_PORT_RANGE%%-*},reuseaddr,fork TCP:127.0.0.1:$OPENSSH_PORT
Restart=always

[Install]
WantedBy=multi-user.target
UDP
  systemctl daemon-reload
  systemctl enable ssh-udp
  systemctl restart ssh-udp
}

# === XRAY ===
install_xray() {
  info "Mengonfigurasi Xray..."
  mkdir -p /usr/local/etc/xray
  cat >"$XRAY_CONFIG" <<JSON
{
  "log": {"access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning"},
  "inbounds": [
    {"port": 8443, "protocol": "vmess", "settings": {"clients": [{"id": "$(generate_uuid)", "alterId": 0}]}, "streamSettings": {"network": "ws", "wsSettings": {"path": "/vmess"}}},
    {"port": 8444, "protocol": "vless", "settings": {"clients": [{"id": "$(generate_uuid)"}], "decryption": "none"}, "streamSettings": {"network": "ws", "wsSettings": {"path": "/vless"}}},
    {"port": 8445, "protocol": "trojan", "settings": {"clients": [{"password": "$(generate_random_password)"}]}}
  ],
  "outbounds": [{"protocol": "freedom"}]
}
JSON
  systemctl enable xray
  systemctl restart xray
}

# === OpenVPN ===
install_openvpn() {
  info "Menyiapkan OpenVPN (ringkas)..."
  mkdir -p /etc/openvpn/server
  cat >/etc/openvpn/server/server.conf <<OVPN
port $OVPN_TCP_PORT
dev tun
proto tcp
server 10.8.0.0 255.255.255.0
keepalive 10 120
persist-key
persist-tun
verb 3
OVPN
  systemctl enable openvpn-server@server || true
  systemctl restart openvpn-server@server || true
  # TODO: Tambahkan konfigurasi SSL/UDP dan pembuatan sertifikat otomatis
}

# === BadVPN ===
install_badvpn() {
  info "Menjalankan BadVPN UDPGW..."
  for p in "${BADVPN_PORTS[@]}"; do
    cat >/etc/systemd/system/badvpn@$p.service <<BAD
[Unit]
Description=BadVPN UDPGW on port $p
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 0.0.0.0:$p --max-clients 2048
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
  # SSL WS
  cat >/etc/systemd/system/ssh-wss.service <<WSL
[Unit]
Description=SSH WebSocket TLS
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:$SSH_WS_SSL_PORT,reuseaddr,fork TCP:127.0.0.1:$OPENSSH_PORT
Restart=always

[Install]
WantedBy=multi-user.target
WSL
  systemctl enable ssh-wss
  systemctl restart ssh-wss
}

# === Backup & Restore ===
backup_configs() {
  mkdir -p "$BACKUP_DIR"
  tar czf "$BACKUP_DIR/backup-$(date +%F-%H%M).tar.gz" /etc/ssh /etc/dropbear "$XRAY_CONFIG" /etc/openvpn || {
    error "Backup gagal."
    return 1
  }
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
  echo "Dropbear WS    : $DROPBEAR_WS_PORT1, $DROPBEAR_WS_PORT2"
  echo "SSH over UDP   : $SSH_UDP_PORT_RANGE"
  echo "OpenVPN SSL    : $OVPN_SSL_PORT"
  echo "OpenVPN TCP    : $OVPN_TCP_PORT"
  echo "OpenVPN UDP    : $OVPN_UDP_PORT"
  echo "BadVPN UDPGW   : ${BADVPN_PORTS[*]}"
  echo "SSH WS         : ${SSH_WS_PORTS[*]}"
  echo "SSH WS SSL     : $SSH_WS_SSL_PORT"
  echo "XRAY (VMESS)   : 8443"
  echo "XRAY (VLESS)   : 8444"
  echo "XRAY (TROJAN)  : 8445"
  line
}

troubleshooting_menu() {
  line
  echo "Troubleshooting"
  line
  for svc in ssh dropbear xray openvpn-server@server ssh-ws@80 ssh-wss; do
    check_service_status "$svc"
  done
  echo "Port listening:"; ss -tulwn | grep -E "(:22|:143|:109|:443|:1194|:2200|:7100|:7300|:80|:8080)" || true
  if command -v jq >/dev/null; then
    jq empty "$XRAY_CONFIG" && ok "Konfig Xray valid" || error "Konfig Xray bermasalah"
  fi
  tail -n 10 /var/log/xray/access.log 2>/dev/null || true
  tail -n 10 /var/log/auth.log 2>/dev/null || true
}

logs_menu() {
  echo "Log Xray:"; tail -n 20 /var/log/xray/error.log 2>/dev/null
  echo "Log SSH:"; tail -n 20 /var/log/auth.log 2>/dev/null
  echo "Log OpenVPN:"; journalctl -u openvpn-server@server -n 20 --no-pager 2>/dev/null
}

# === Menu Akun Placeholder ===
show_ssh_menu() {
  line; echo "Menu SSH/Dropbear"; line
  cat <<MENU
1. Create User
2. Delete User
3. Renew User
4. Trial User
5. Cek Login
6. List Member
7. List Expired
8. Limit User
9. Auto Kill Accounts
10. Detail Accounts
11. Recovery Accounts
12. Check Login UDP
16. Back to Menu
x. Exit
MENU
  # TODO: Implementasi setiap opsi dengan update database lokal
}

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
9. Edit Limit IP Account
10. Edit Limit Bandwidth Account
11. Lock Account
12. Unlock Account
13. Create Account Vless
14. Trial Account Vless
15. Delete Account Vless
16. Renew Account Vless
17. Check Config Account
18. Recovery Account
19. Edit Limit IP Account
20. Edit Limit Bandwidth Account
21. Lock Account
22. Unlock Account
23. Back to Menu
x. Exit
MENU
  # TODO: Implementasi CRUD akun dan update database lokal
}

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
9. Edit Limit IP Account
10. Edit Limit Bandwidth Account
11. Lock Account
12. Unlock Account
13. Back to Menu
x. Exit
MENU
  # TODO: Implementasi CRUD akun Trojan dan update database lokal
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
4. Menu OpenVPN (TODO)
5. Troubleshooting
6. Logs Menu
7. Backup Menu
8. Info Service Port
9. Exit
MENU
  read -rp "Pilih: " choice
  case $choice in
    1) show_ssh_menu;;
    2) show_xray_menu;;
    3) show_trojan_menu;;
    4) echo "TODO OpenVPN menu";;
    5) troubleshooting_menu;;
    6) logs_menu;;
    7) show_backup_menu;;
    8) show_information_menu;;
    9) exit 0;;
  esac
}

show_main_menu() {
  while true; do
    line; echo "AUTO TUNNELING MENU"; line
    cat <<MENU
1. Install/Update Semua Layanan
2. Info Service Port
3. Menu Fitur
4. Backup Menu
5. Troubleshooting
x. Exit
MENU
    read -rp "Pilih: " choice
    case $choice in
      1)
        check_root; check_os; check_arch
        install_dependencies
        install_openssh
        install_dropbear
        install_dropbear_ws
        install_ssh_udp
        install_xray
        install_openvpn
        install_badvpn
        install_websocket_services
        open_firewall_ports
        ok "Instalasi selesai."
        ;;
      2) show_service_info ;;
      3) show_features_menu ;;
      4) show_backup_menu ;;
      5) troubleshooting_menu ;;
      x|X) exit 0 ;;
      *) echo "Pilihan tidak valid" ;;
    esac
  done
}

# === Entry Point ===
if [[ "${1:-}" == "--auto-backup" ]]; then
  backup_configs && send_backup_to_telegram
  exit 0
fi

show_main_menu
