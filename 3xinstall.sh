#!/bin/bash

INSTALL_WARP=false
EXTENDED_SETUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --warp)
            INSTALL_WARP=true
            shift
            ;;
        --extend)
            EXTENDED_SETUP=true
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&3
            exit 1
            ;;
    esac
done

if command -v x-ui &> /dev/null; then
    echo "Обнаружена установленная панель 3x-ui."
    read -p "Вы хотите переустановить x-ui? [y/N]: " confirm
    confirm=${confirm,,}
    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        echo "Отмена. Скрипт завершает работу."
        exit 1
    fi
    echo "Удаление x-ui и очистка процессов..."
    systemctl stop x-ui 2>/dev/null
    systemctl disable x-ui 2>/dev/null
    killall -9 x-ui 2>/dev/null
    killall -9 xray-linux-amd64 2>/dev/null
    rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service
    systemctl daemon-reexec
    systemctl daemon-reload
    rm -f /root/3x-ui.txt
    echo "x-ui успешно удалена. Продолжаем выполнение скрипта..."
fi

exec 3>&1
LOG_FILE="/var/log/3x-ui_install_log.txt"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
cyan='\033[0;36m'
plain='\033[0m'

if [[ "$EXTENDED_SETUP" == true ]]; then
    read -rp $'\033[0;33mВведите порт для панели (Enter для 8080): \033[0m' USER_PORT
    PORT=${USER_PORT:-8080}
else
    PORT=8080
    echo -e "${yellow}Порт панели по умолчанию: ${PORT}${plain}" >&3
fi

echo -e "Лог установки: ${cyan}${LOG_FILE}${plain}" >&3
echo -e "\n\033[1;34mИдёт установка... Пожалуйста, не закрывайте терминал.\033[0m"

gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}

USERNAME=$(gen_random_string 10)
PASSWORD=$(gen_random_string 10)
WEBPATH=$(gen_random_string 18)

VLESS_PORTS=(8443 4443)
INBOUND_PORT=${VLESS_PORTS[$RANDOM % ${#VLESS_PORTS[@]}]}

HY2_PORTS=(4433 8444 2083)
HY2_PORT=${HY2_PORTS[$RANDOM % ${#HY2_PORTS[@]}]}

BEST_DOMAIN="ozon.ru"
CLIENT_EMAIL=$(gen_random_string 10)

CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
CLIENT_PASS=$(gen_random_string 14)
CLIENT_SUB_ID=$(gen_random_string 16)
HY2_AUTH=$(gen_random_string 16)
SALAMANDER_PASS=$(gen_random_string 16)

echo -e "${green}VLESS инбаунд: in-${INBOUND_PORT}-tcp → порт ${INBOUND_PORT}${plain}" >&3
echo -e "${green}Hysteria2 инбаунд: in-${HY2_PORT}-udp → порт ${HY2_PORT}${plain}" >&3
echo -e "${green}SNI / DEST: ${BEST_DOMAIN}${plain}" >&3

if [[ $EUID -ne 0 ]]; then
    echo -e "${red}Ошибка:${plain} скрипт нужно запускать от root" >&3
    exit 1
fi

echo -e "${yellow}Настройка TCP BBR и сетевых буферов...${plain}" >&3
KERNEL_VERSION=$(uname -r | cut -d. -f1-2 | tr -d '.')
if [[ "$KERNEL_VERSION" -ge 49 ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    SYSCTL_CONF="/etc/sysctl.d/99-bbr-optimize.conf"
    cat > "$SYSCTL_CONF" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.core.rmem_default=26214400
net.core.wmem_default=26214400
net.core.netdev_max_backlog=250000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
EOF
    sysctl -p "$SYSCTL_CONF" >>"$LOG_FILE" 2>&1
fi

apt-get update -y >/dev/null 2>&1 || yum update -y >/dev/null 2>&1
apt-get install -y curl jq tar qrencode openssl >/dev/null 2>&1 || yum install -y curl jq tar qrencode openssl >/dev/null 2>&1

SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)

CERT_DIR="/root/cert/ip"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "${CERT_DIR}/privkey.pem" \
    -out "${CERT_DIR}/fullchain.pem" \
    -days 3650 \
    -subj "/CN=${SERVER_IP}" \
    -addext "subjectAltName=IP:${SERVER_IP}" >>"$LOG_FILE" 2>&1

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | arm64 | aarch64) echo 'arm64' ;;
        armv7* | arm) echo 'armv7' ;;
        armv6*) echo 'armv6' ;;
        armv5*) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo "unknown" ;;
    esac
}
ARCH=$(arch)

echo -e "${yellow}Скачивание и установка 3x-ui версии v3.6.0...${plain}" >&3
cd /usr/local/ || exit 1
VERSION="v3.6.0"
URL1="https://github.com/MHSanaei/3x-ui/releases/download/${VERSION}/x-ui-linux-${ARCH}.tar.gz"
FILE="x-ui-linux-${ARCH}.tar.gz"

if ! wget -q -O "$FILE" "$URL1"; then
    echo -e "${red}Ошибка: не удалось скачать 3x-ui версии ${VERSION}${plain}" >&3
    exit 1
fi

tar -xzf "$FILE"
rm -f "$FILE"

cd x-ui || exit 1
chmod +x x-ui
[[ "$ARCH" == armv* ]] && mv bin/xray-linux-${ARCH} bin/xray-linux-arm && chmod +x bin/xray-linux-arm
chmod +x x-ui bin/xray-linux-${ARCH}

mkdir -p /etc/x-ui/

cat > /etc/systemd/system/x-ui.service <<EOF
[Unit]
Description=3x-ui Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/x-ui/
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

URL_SH="https://raw.githubusercontent.com/MHSanaei/3x-ui/${VERSION}/x-ui.sh"
FILE_SH="/usr/bin/x-ui"
wget -q -O "$FILE_SH" "$URL_SH" || true
chmod +x /usr/local/x-ui/x-ui.sh /usr/bin/x-ui 2>/dev/null || true

cd /usr/local/x-ui/ || exit 1
# Прямая запись пути без слэшей, панель 3x-ui сама добавит их при запуске
./x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "${WEBPATH}" >>"$LOG_FILE" 2>&1
./x-ui migrate >>"$LOG_FILE" 2>&1

systemctl daemon-reload >>"$LOG_FILE" 2>&1
systemctl enable x-ui >>"$LOG_FILE" 2>&1
systemctl start x-ui >>"$LOG_FILE" 2>&1

echo -e "${yellow}Ожидаем запуска панели...${plain}" >&3
PANEL_READY=false

for i in {1..20}; do
    sleep 2
    # Проверяем код ответа сервера, разрешая редиректы (-L)
    HTTP_CODE=$(curl -s -L -o /dev/null -w "%{http_code}" -m 2 "http://127.0.0.1:${PORT}/${WEBPATH}/")
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "401" ]]; then
        echo -e "${green}Панель готова.${plain}" >&3
        PANEL_READY=true
        break
    fi
done

if [[ "$PANEL_READY" == false ]]; then
    echo -e "${red}Критическая ошибка: панель 3x-ui не ответила на порту ${PORT}!${plain}" >&3
    echo -e "${yellow}Последние логи из systemd:${plain}" >&3
    journalctl -u x-ui --no-pager -n 15 >&3
    exit 1
fi

if [[ "$INSTALL_WARP" == true ]]; then
    echo -e "${yellow}Установка Cloudflare WARP...${plain}" >&3
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/warp_menu.sh >/dev/null 2>&1
    echo -e "1\n40000\n" | bash /tmp/warp_menu.sh c >/dev/null 2>&1 || true
    rm -f /tmp/warp_menu.sh
fi

XRAY_BIN="/usr/local/x-ui/bin/xray-linux-${ARCH}"
chmod +x "$XRAY_BIN" 2>/dev/null
KEYS=$("$XRAY_BIN" x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | sed -E 's/.*Key:\s*//')
PUBLIC_KEY=$(echo "$KEYS" | grep -i "Password" | sed -E 's/.*Password:\s*//')
SHORT_ID=$(head -c 8 /dev/urandom | xxd -p)

COOKIE_JAR=$(mktemp)
API_BASE_URL="http://127.0.0.1:${PORT}/${WEBPATH}"

LOGIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -X POST "${API_BASE_URL}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${USERNAME}\", \"password\": \"${PASSWORD}\"}")

if ! echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    echo -e "${red}Ошибка авторизации в 3x-ui API. Учетные данные не подошли.${plain}" >&3
    exit 1
fi

VLESS_TAG="in-${INBOUND_PORT}-tcp"
HY2_TAG="in-${HY2_PORT}-udp"

VLESS_SETTINGS_JSON=$(jq -nc \
  --arg uuid "$CLIENT_UUID" \
  --arg email "$CLIENT_EMAIL" \
  --arg pass "$CLIENT_PASS" \
  --arg sub "$CLIENT_SUB_ID" \
  --arg hyauth "$HY2_AUTH" '{
  clients: [{
    id: $uuid,
    password: $pass,
    email: $email,
    subId: $sub,
    hysteria: {auth: $hyauth},
    flow: "xtls-rprx-vision",
    enable: true
  }],
  decryption: "none"
}')

VLESS_STREAM_SETTINGS_JSON=$(jq -nc \
  --arg pbk "$PUBLIC_KEY" \
  --arg prk "$PRIVATE_KEY" \
  --arg sid "$SHORT_ID" \
  --arg dest "${BEST_DOMAIN}:443" \
  --arg sni "$BEST_DOMAIN" '{
  network: "tcp",
  security: "reality",
  realitySettings: {
    show: false,
    dest: $dest,
    xver: 0,
    serverNames: [$sni],
    privateKey: $prk,
    settings: {publicKey: $pbk},
    shortIds: [$sid]
  }
}')

SNIFFING_JSON=$(jq -nc '{enabled: true, destOverride: ["http", "tls"]}')

curl -s -b "$COOKIE_JAR" -X POST "${API_BASE_URL}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --argjson settings "$VLESS_SETTINGS_JSON" \
    --argjson stream "$VLESS_STREAM_SETTINGS_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    --arg tag "$VLESS_TAG" \
    --argjson port "$INBOUND_PORT" \
    '{enable: true, remark: $tag, listen: "", port: $port, protocol: "vless", tag: $tag,
      settings: ($settings | tostring), streamSettings: ($stream | tostring), sniffing: ($sniffing | tostring)}')" >>"$LOG_FILE" 2>&1

HY2_SETTINGS_JSON=$(jq -nc \
  --arg uuid "$CLIENT_UUID" \
  --arg email "$CLIENT_EMAIL" \
  --arg pass "$CLIENT_PASS" \
  --arg sub "$CLIENT_SUB_ID" \
  --arg hyauth "$HY2_AUTH" '{
  clients: [{
    id: $uuid,
    password: $pass,
    email: $email,
    subId: $sub,
    hysteria: {auth: $hyauth},
    enable: true
  }]
}')

HY2_STREAM_SETTINGS_JSON=$(jq -nc \
  --arg cert "${CERT_DIR}/fullchain.pem" \
  --arg key "${CERT_DIR}/privkey.pem" \
  --arg sni "$BEST_DOMAIN" \
  --arg salpass "$SALAMANDER_PASS" '{
  network: "udp",
  security: "tls",
  tlsSettings: {
    certificates: [{certificateFile: $cert, keyFile: $key}],
    serverName: $sni,
    alpn: ["h3"]
  },
  hysteriaSettings: {
    version: 2,
    udpMasks: [{type: "salamander", salamander: {password: $salpass}}]
  }
}')

curl -s -b "$COOKIE_JAR" -X POST "${API_BASE_URL}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --argjson settings "$HY2_SETTINGS_JSON" \
    --argjson stream "$HY2_STREAM_SETTINGS_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    --arg tag "$HY2_TAG" \
    --argjson port "$HY2_PORT" \
    '{enable: true, remark: $tag, listen: "", port: $port, protocol: "hysteria", tag: $tag,
      settings: ($settings | tostring), streamSettings: ($stream | tostring), sniffing: ($sniffing | tostring)}')" >>"$LOG_FILE" 2>&1

if [[ "$INSTALL_WARP" == true ]]; then
    XRAY_CONFIG=$(jq -nc --arg vlesstag "$VLESS_TAG" '{
      log: {access: "none", dnsLog: false, error: "", loglevel: "warning", maskAddress: ""},
      api: {tag: "api", services: ["HandlerService", "LoggerService", "StatsService"]},
      inbounds: [{tag: "api", listen: "127.0.0.1", port: 62789, protocol: "dokodemo-door", settings: {address: "127.0.0.1"}}],
      outbounds: [
        {tag: "direct", protocol: "freedom", settings: {domainStrategy: "AsIs", redirect: "", noises: []}},
        {tag: "blocked", protocol: "blackhole", settings: {}},
        {tag: "warp", protocol: "socks", settings: {servers: [{address: "127.0.0.1", port: 40000, users: []}]}}
      ],
      policy: {
        levels: {"0": {statsUserDownlink: true, statsUserUplink: true}},
        system: {statsInboundDownlink: true, statsInboundUplink: true, statsOutboundDownlink: false, statsOutboundUplink: false}
      },
      routing: {
        domainStrategy: "AsIs",
        rules: [
          {type: "field", inboundTag: ["api"], outboundTag: "api"},
          {type: "field", outboundTag: "blocked", ip: ["geoip:private"]},
          {type: "field", outboundTag: "blocked", protocol: ["bittorrent"]},
          {type: "field", inboundTag: [$vlesstag], outboundTag: "warp"}
        ]
      },
      stats: {},
      metrics: {tag: "metrics_out", listen: "127.0.0.1:11111"}
    }')

    XRAY_CONFIG_ENCODED=$(echo "$XRAY_CONFIG" | jq -sRr @uri)

    curl -s -b "$COOKIE_JAR" -X POST "${API_BASE_URL}/panel/xray/update" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-raw "xraySetting=${XRAY_CONFIG_ENCODED}" >>"$LOG_FILE" 2>&1
fi

curl -s -b "$COOKIE_JAR" -X POST "${API_BASE_URL}/server/restartXrayService" >>"$LOG_FILE" 2>&1
rm -f "$COOKIE_JAR"

if [[ "$INSTALL_WARP" == true ]]; then
    VLESS_TITLE="VLESS Reality (С поддержкой WARP)"
    VLESS_MARK="VLESS-WARP"
else
    VLESS_TITLE="VLESS Reality"
    VLESS_MARK="VLESS"
fi

VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:${INBOUND_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${BEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${VLESS_MARK}-${CLIENT_EMAIL}"
HY2_LINK="hysteria2://${HY2_AUTH}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=${BEST_DOMAIN}&obfs=salamander&obfs-password=${SALAMANDER_PASS}#Hysteria2-${CLIENT_EMAIL}"

echo -e "\n\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "\033[1;32m  ${VLESS_TITLE}\033[0m" >&3
echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "${cyan}${VLESS_LINK}${plain}" >&3
echo ""
qrencode -t ANSIUTF8 "$VLESS_LINK"
echo ""

echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "\033[1;32m  Hysteria2\033[0m" >&3
echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "${cyan}${HY2_LINK}${plain}" >&3
echo ""
qrencode -t ANSIUTF8 "$HY2_LINK"
echo ""

echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "\033[1;32m  Панель 3X-UI (v3.6.0)\033[0m" >&3
echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "Адрес:  ${cyan}http://${SERVER_IP}:${PORT}/${WEBPATH}/${plain}" >&3
echo -e "Логин:  \033[1;33m${USERNAME}\033[0m" >&3
echo -e "Пароль: \033[1;33m${PASSWORD}\033[0m" >&3
echo ""
echo -e "Данные сохранены: ${cyan}cat /root/3x-ui.txt${plain}" >&3

{
echo "======================================"
echo "  ${VLESS_TITLE}"
echo "======================================"
echo "$VLESS_LINK"
echo ""
echo "Инбаунд: in-${INBOUND_PORT}-tcp | Порт: ${INBOUND_PORT} | SNI: ${BEST_DOMAIN}"
echo ""
echo "======================================"
echo "  Hysteria2"
echo "======================================"
echo "$HY2_LINK"
echo ""
echo "Инбаунд: in-${HY2_PORT}-udp | Порт: ${HY2_PORT} | SNI: ${BEST_DOMAIN}"
echo ""
echo "======================================"
echo "  Панель 3X-UI (v3.6.0)"
echo "======================================"
echo "Адрес:  http://${SERVER_IP}:${PORT}/${WEBPATH}/"
echo "Логин:  ${USERNAME}"
echo "Пароль: ${PASSWORD}"
} >> /root/3x-ui.txt
