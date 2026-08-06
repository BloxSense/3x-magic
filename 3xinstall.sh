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

# Проверяем наличие команды x-ui
if command -v x-ui &> /dev/null; then
    echo "Обнаружена установленная панель x-ui."
    read -p "Вы хотите переустановить x-ui? [y/N]: " confirm
    confirm=${confirm,,}
    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        echo "Отмена. Скрипт завершает работу."
        exit 1
    fi
    echo "Удаление x-ui..."
    systemctl stop x-ui 2>/dev/null || true
    systemctl unmask x-ui &>/dev/null || true
    /usr/local/x-ui/x-ui uninstall -y &>/dev/null || true
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
    echo -e "\n${yellow}Хотите установить SelfSNI?${plain}"
    read -rp $'\033[0;36mВведите y для установки или нажмите Enter для пропуска: \033[0m' INSTALL_SELFSNI
    if [[ "$INSTALL_SELFSNI" == "y" || "$INSTALL_SELFSNI" == "Y" ]]; then
        echo -e "${green}Устанавливается SelfSNI...${plain}" >&3
        bash <(curl -Ls https://raw.githubusercontent.com/YukiKras/vless-scripts/refs/heads/main/fakesite.sh)
    else
        echo -e "${yellow}SelfSNI пропущен.${plain}" >&3
    fi
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
WEBPATH_RAW=$(gen_random_string 18)
WEBPATH="/${WEBPATH_RAW}/"
CLEAN_PATH="$WEBPATH_RAW"
INBOUND_REMARK=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | fold -w 10 | head -n 1)
HY2_PASSWORD=$(gen_random_string 16)

VLESS_PORTS=(8443)
INBOUND_PORT=${VLESS_PORTS[$RANDOM % ${#VLESS_PORTS[@]}]}

HY2_PORTS=(8444)
HY2_PORT=${HY2_PORTS[$RANDOM % ${#HY2_PORTS[@]}]}

BEST_DOMAIN="ozon.ru"

echo -e "${green}VLESS инбаунд: ${INBOUND_REMARK} → порт ${INBOUND_PORT}${plain}" >&3
echo -e "${green}Hysteria2 порт: ${HY2_PORT}${plain}" >&3
echo -e "${green}SNI / DEST: ${BEST_DOMAIN}${plain}" >&3

if [[ $EUID -ne 0 ]]; then
    echo -e "${red}Ошибка:${plain} скрипт нужно запускать от root" >&3
    exit 1
fi

# === BBR + оптимизация ===
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
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$CURRENT_CC" == "bbr" ]]; then
        echo -e "${green}TCP BBR включён.${plain}" >&3
    else
        echo -e "${yellow}BBR не применился (текущий: ${CURRENT_CC}).${plain}" >&3
    fi
else
    echo -e "${yellow}Ядро не поддерживает BBR. Пропускаем.${plain}" >&3
fi

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
else
    echo "Не удалось определить ОС" >&3
    exit 1
fi

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

# === Зависимости ===
case "${release}" in
    ubuntu | debian | armbian)
        apt-get update > /dev/null 2>&1
        apt-get install -y -q wget curl tar tzdata jq xxd qrencode openssl > /dev/null 2>&1 ;;
    centos | rhel | almalinux | rocky | ol)
        yum -y update > /dev/null 2>&1
        yum install -y -q wget curl tar tzdata jq xxd qrencode openssl > /dev/null 2>&1 ;;
    fedora | amzn | virtuozzo)
        dnf -y update > /dev/null 2>&1
        dnf install -y -q wget curl tar tzdata jq xxd qrencode openssl > /dev/null 2>&1 ;;
    arch | manjaro | parch)
        pacman -Syu --noconfirm > /dev/null 2>&1
        pacman -S --noconfirm wget curl tar tzdata jq xxd qrencode openssl > /dev/null 2>&1 ;;
    opensuse-tumbleweed)
        zypper refresh > /dev/null 2>&1
        zypper install -y wget curl tar timezone jq xxd qrencode openssl > /dev/null 2>&1 ;;
    *)
        apt-get update > /dev/null 2>&1
        apt-get install -y wget curl tar tzdata jq xxd qrencode openssl > /dev/null 2>&1 ;;
esac

# === 3x-ui ===
cd /usr/local/ || exit 1
FILE="x-ui-linux-${ARCH}.tar.gz"
URL1="https://github.com/MHSanaei/3x-ui/releases/download/v3.6.0/${FILE}"

if ! wget -q -O "$FILE" "$URL1"; then
    echo "Не удалось скачать с GitHub, пробую зеркало..."
fi

systemctl stop x-ui 2>/dev/null
rm -rf /usr/local/x-ui/
if ! tar -xzf "x-ui-linux-${ARCH}.tar.gz"; then
    echo -e "${red}Ошибка распаковки архива 3x-ui${plain}" >&3
    exit 1
fi
rm -f "x-ui-linux-${ARCH}.tar.gz"

cd x-ui || exit 1
chmod +x x-ui
[[ "$ARCH" == armv* ]] && mv bin/xray-linux-${ARCH} bin/xray-linux-arm && chmod +x bin/xray-linux-arm
chmod +x x-ui bin/xray-linux-${ARCH}

systemctl unmask x-ui &>/dev/null || true

if [[ -s x-ui.service ]]; then
    cp -f x-ui.service /etc/systemd/system/
else
    echo -e "${yellow}x-ui.service отсутствует в архиве, использую встроенный шаблон${plain}" >&3
    cat > /etc/systemd/system/x-ui.service <<'EOF'
[Unit]
Description=x-ui Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/x-ui/
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
fi
systemctl unmask x-ui &>/dev/null || true

URL1="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh"
URL2="https://files.yukikras.net/3x-ui/x-ui.sh"
FILE="/usr/bin/x-ui"
if ! wget -q -O "$FILE" "$URL1"; then
    wget -q -O "$FILE" "$URL2" || { echo "Ошибка: не удалось скачать x-ui.sh"; exit 1; }
fi
chmod +x /usr/local/x-ui/x-ui.sh /usr/bin/x-ui

/usr/local/x-ui/x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "$WEBPATH" >>"$LOG_FILE" 2>&1
/usr/local/x-ui/x-ui migrate >>"$LOG_FILE" 2>&1
systemctl daemon-reload >>"$LOG_FILE" 2>&1
systemctl enable x-ui >>"$LOG_FILE" 2>&1
systemctl start x-ui >>"$LOG_FILE" 2>&1

# Ждём пока панель поднимется
echo -e "${yellow}Ожидаем запуска панели...${plain}" >&3
for i in {1..15}; do
    sleep 2
    if curl -s --max-time 2 "http://127.0.0.1:${PORT}/${CLEAN_PATH}/login" | grep -q "html" 2>/dev/null; then
        echo -e "${green}Панель готова.${plain}" >&3
        break
    fi
    if [[ $i -eq 15 ]]; then
        echo -e "${yellow}Панель долго стартует, продолжаем...${plain}" >&3
    fi
done

# === Reality ключи ===
KEYS=$(/usr/local/x-ui/bin/xray-linux-${ARCH} x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | sed -E 's/.*Key:\s*//')
PUBLIC_KEY=$(echo "$KEYS" | grep -i "Password" | sed -E 's/.*Password:\s*//')
SHORT_IDS_JSON="[]"
for len in 2 4 6 8 10 12 14 16; do
    sid=$(head -c $((len/2)) /dev/urandom | xxd -p)
    SHORT_IDS_JSON=$(echo "$SHORT_IDS_JSON" | jq --arg s "$sid" '. + [$s]')
done
SHORT_ID=$(echo "$SHORT_IDS_JSON" | jq -r '.[0]')
SPIDER_X="/$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)"
UUID=$(cat /proc/sys/kernel/random/uuid)
EMAIL=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)

# === API авторизация ===
COOKIE_JAR=$(mktemp)

# Получаем CSRF-токен и стартовую сессионную cookie через GET на страницу логина
LOGIN_PAGE=$(curl -s -c "$COOKIE_JAR" "http://127.0.0.1:${PORT}/${CLEAN_PATH}/")
CSRF_TOKEN=$(echo "$LOGIN_PAGE" | grep -oP 'name="csrf-token" content="\K[^"]+')

if [[ -z "$CSRF_TOKEN" ]]; then
    echo -e "${red}Не удалось получить CSRF-токен со страницы логина.${plain}" >&3
    exit 1
fi

LOGIN_RESPONSE=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/login" \
  -H "Content-Type: application/json" \
  -H "X-CSRF-Token: ${CSRF_TOKEN}" \
  -d "{\"username\": \"${USERNAME}\", \"password\": \"${PASSWORD}\"}")

if ! echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    echo -e "${red}Ошибка авторизации.${plain}" >&3
    echo "$LOGIN_RESPONSE" >&3
    exit 1
fi

SETTINGS_JSON=$(jq -nc --arg uuid "$UUID" --arg email "$EMAIL" '{
  clients: [{id: $uuid, flow: "xtls-rprx-vision", email: $email, enable: true}],
  decryption: "none"
}')

# СТАЛО:
STREAM_SETTINGS_JSON=$(jq -nc \
  --arg pbk "$PUBLIC_KEY" --arg prk "$PRIVATE_KEY" \
  --argjson sids "$SHORT_IDS_JSON" \
  --arg dest "${BEST_DOMAIN}:443" --arg domain "$BEST_DOMAIN" \
  --arg spx "$SPIDER_X" '{
  network: "tcp",
  tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } },
  security: "reality",
  realitySettings: {
    show: false, xver: 0, target: $dest,
    serverNames: [("www." + $domain), $domain],
    privateKey: $prk, minClientVer: "", maxClientVer: "", maxTimediff: 0,
    shortIds: $sids, mldsa65Seed: "",
    limitFallbackUpload: { afterBytes: 0, bytesPerSec: 0, burstBytesPerSec: 0 },
    limitFallbackDownload: { afterBytes: 0, bytesPerSec: 0, burstBytesPerSec: 0 },
    settings: {
      publicKey: $pbk, fingerprint: "firefox", serverName: "",
      spiderX: $spx, mldsa65Verify: ""
    }
  }
}')

SNIFFING_JSON=$(jq -nc '{enabled: true, destOverride: ["http", "tls"]}')

ADD_RESULT=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -H "X-CSRF-Token: ${CSRF_TOKEN}" \
  -d "$(jq -nc \
    --argjson settings "$SETTINGS_JSON" \
    --argjson stream "$STREAM_SETTINGS_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    --arg remark "$INBOUND_REMARK" \
    --argjson port "$INBOUND_PORT" \
    '{enable: true, remark: $remark, listen: "", port: $port, protocol: "vless",
      settings: ($settings | tostring), streamSettings: ($stream | tostring), sniffing: ($sniffing | tostring)}')")

if echo "$ADD_RESULT" | grep -q '"success":true'; then
    echo -e "${green}VLESS Reality инбаунд добавлен.${plain}" >&3
    systemctl restart x-ui >>"$LOG_FILE" 2>&1
else
    echo -e "${red}Ошибка при добавлении VLESS инбаунда:${plain}" >&3
    echo "$ADD_RESULT" >&3
fi

# ============================================================
# === HYSTERIA 2 (как инбаунд внутри x-ui) ===
# ============================================================
echo -e "\n${yellow}Добавление Hysteria2 в x-ui...${plain}" >&3

HY2_CERT_DIR="/root/cert/ip"
mkdir -p "$HY2_CERT_DIR"

SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)

if [[ ! -s "${HY2_CERT_DIR}/fullchain.pem" || ! -s "${HY2_CERT_DIR}/privkey.pem" ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${HY2_CERT_DIR}/privkey.pem" \
        -out "${HY2_CERT_DIR}/fullchain.pem" \
        -days 3650 \
        -subj "/CN=${BEST_DOMAIN}" \
        -addext "subjectAltName=IP:${SERVER_IP}" \
        >>"$LOG_FILE" 2>&1
fi

SALAMANDER_PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)

HY2_EMAIL=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
HY2_SETTINGS_JSON=$(jq -nc --arg auth "$HY2_PASSWORD" --arg email "$HY2_EMAIL" '{
  clients: [
    { auth: $auth, email: $email, limitIp: 0, totalGB: 0, expiryTime: 0,
      enable: true, tgId: 0, subId: "", comment: "", reset: 0 }
  ],
  version: 2
}')

HY2_STREAM_JSON=$(jq -nc \
  --arg domain "$BEST_DOMAIN" \
  --arg cert "${HY2_CERT_DIR}/fullchain.pem" \
  --arg key "${HY2_CERT_DIR}/privkey.pem" \
  --arg salpass "$SALAMANDER_PASSWORD" '{
  network: "hysteria",
  hysteriaSettings: { version: 2, udpIdleTimeout: 60 },
  security: "tls",
  tlsSettings: {
    serverName: $domain, minVersion: "1.2", maxVersion: "1.3",
    cipherSuites: "", rejectUnknownSni: false, disableSystemRoot: false,
    enableSessionResumption: false,
    certificates: [{ certificateFile: $cert, keyFile: $key, ocspStapling: 0,
      oneTimeLoading: false, usage: "encipherment", buildChain: false, useFile: true }],
    alpn: ["h3"], echServerKeys: "",
    settings: { fingerprint: "firefox", echConfigList: "", pinnedPeerCertSha256: [], verifyPeerCertByName: "" }
  },
  finalmask: { udp: [{ type: "salamander", settings: { password: $salpass } }] }
}')

ADD_HY2_RESULT=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -H "X-CSRF-Token: ${CSRF_TOKEN}" \
  -d "$(jq -nc \
    --argjson settings "$HY2_SETTINGS_JSON" \
    --argjson stream "$HY2_STREAM_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    --arg port "$HY2_PORT" \
    '{enable: true, remark: "Hysteria2", listen: "", port: ($port|tonumber),
      protocol: "hysteria", tag: ("in-" + $port + "-udp"),
      settings: ($settings | tostring), streamSettings: ($stream | tostring),
      sniffing: ($sniffing | tostring)}')")

if echo "$ADD_HY2_RESULT" | grep -q '"success":true'; then
    echo -e "${green}Hysteria2 инбаунд добавлен в x-ui.${plain}" >&3
    HY2_OK=true
else
    echo -e "${red}Ошибка добавления Hysteria2:${plain}" >&3
    echo "$ADD_HY2_RESULT" >&3
    HY2_OK=false
fi

# === WARP ===
if [[ "$INSTALL_WARP" == true ]]; then
    if command -v warp-cli &>/dev/null && warp-cli status 2>/dev/null | grep -q "Connected"; then
        echo -e "${green}WARP уже установлен и подключён, пропускаем установку.${plain}" >&3
        WARP_ALREADY_OK=true
    else
        echo -e "${yellow}Установка WARP...${plain}" >&3
        wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/warp_menu.sh >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo -e "1\n" | bash /tmp/warp_menu.sh c >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
            echo -e "${green}WARP установлен.${plain}" >&3
            XRAY_CONFIG=$(jq -nc --arg inbound_tag "inbound-${INBOUND_PORT}" '{
  "log": {"access": "none", "dnsLog": false, "error": "", "loglevel": "warning", "maskAddress": ""},
  "api": {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]},
  "inbounds": [{"tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "AsIs", "redirect": "", "noises": []}},
    {"tag": "blocked", "protocol": "blackhole", "settings": {}},
    {"tag": "WARP", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": 40000, "users": []}]}}
  ],
  "policy": {
    "levels": {"0": {"statsUserDownlink": true, "statsUserUplink": true}},
    "system": {"statsInboundDownlink": true, "statsInboundUplink": true, "statsOutboundDownlink": false, "statsOutboundUplink": false}
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
      {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
      {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]},
      {"type": "field", "inboundTag": [$inbound_tag], "outboundTag": "WARP"}
    ]
  },
  "stats": {},
  "metrics": {"tag": "metrics_out", "listen": "127.0.0.1:11111"}
}')
            XRAY_CONFIG_ENCODED=$(echo "$XRAY_CONFIG" | jq -sRr @uri)
            UPDATE_RESPONSE=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/panel/xray/update" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                -H "X-CSRF-Token: ${CSRF_TOKEN}" \
                --data-raw "xraySetting=${XRAY_CONFIG_ENCODED}")
            if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
                curl -s -b "$COOKIE_JAR" -H "X-CSRF-Token: ${CSRF_TOKEN}" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/server/restartXrayService" >>"$LOG_FILE" 2>&1
                echo -e "${green}WARP подключён к VLESS инбаунду.${plain}" >&3
            else
                echo -e "${red}Ошибка обновления конфига Xray для WARP.${plain}" >&3
            fi
        else
            echo -e "${red}Ошибка при установке WARP.${plain}" >&3
        fi
        rm -f /tmp/warp_menu.sh
    else
        echo -e "${red}Не удалось загрузить скрипт WARP.${plain}" >&3
    fi
fi

rm -f "$COOKIE_JAR"

# ============================================================
# === ИТОГОВЫЙ ВЫВОД ===
# ============================================================
SERVER_IP=${SERVER_IP:-$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)}

SPX_ENCODED=$(printf '%s' "$SPIDER_X" | sed 's/\//%2F/g')
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${INBOUND_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${BEST_DOMAIN}&fp=firefox&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=${SPX_ENCODED}#${INBOUND_REMARK}"
HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=${BEST_DOMAIN}#hy2-${INBOUND_REMARK}"

echo -e "\n\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "\033[1;32m  VLESS Reality\033[0m" >&3
echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "${cyan}${VLESS_LINK}${plain}" >&3
echo ""
qrencode -t ANSIUTF8 "$VLESS_LINK"
echo ""

if [[ "$HY2_OK" == "true" ]]; then
    echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
    echo -e "\033[1;32m  Hysteria2\033[0m" >&3
    echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
    echo -e "${cyan}${HY2_LINK}${plain}" >&3
    echo ""
    qrencode -t ANSIUTF8 "$HY2_LINK"
    echo ""
fi

echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "\033[1;32m  Панель 3X-UI\033[0m" >&3
echo -e "\033[1;32m══════════════════════════════════════\033[0m" >&3
echo -e "Адрес:  ${cyan}http://${SERVER_IP}:${PORT}/${CLEAN_PATH}${plain}" >&3
echo -e "Логин:  \033[1;33m${USERNAME}\033[0m" >&3
echo -e "Пароль: \033[1;33m${PASSWORD}\033[0m" >&3
echo ""
echo -e "Данные сохранены: ${cyan}cat /root/3x-ui.txt${plain}" >&3

{
echo "======================================"
echo "  VLESS Reality"
echo "======================================"
echo "$VLESS_LINK"
echo ""
echo "Инбаунд: ${INBOUND_REMARK} | Порт: ${INBOUND_PORT} | SNI: ${BEST_DOMAIN}"
echo ""
if [[ "$HY2_OK" == "true" ]]; then
echo "======================================"
echo "  Hysteria2"
echo "======================================"
echo "$HY2_LINK"
echo ""
echo "Порт: ${HY2_PORT} | Пароль: ${HY2_PASSWORD}"
echo ""
fi
echo "======================================"
echo "  Панель 3X-UI"
echo "======================================"
echo "Адрес:  http://${SERVER_IP}:${PORT}/${CLEAN_PATH}"
echo "Логин:  ${USERNAME}"
echo "Пароль: ${PASSWORD}"
} >> /root/3x-ui.txt
