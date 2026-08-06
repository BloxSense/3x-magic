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
    echo "Обнаружена установленная панель x-ui."
    read -p "Вы хотите переустановить x-ui? [y/N]: " confirm
    confirm=${confirm,,}
    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        echo "Отмена. Скрипт завершает работу."
        exit 1
    fi
    echo "Удаление x-ui..."
    systemctl unmask x-ui &>/dev/null || true
    /usr/local/x-ui/x-ui uninstall -y &>/dev/null || true
    rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service
    systemctl daemon-reexec
    systemctl daemon-reload
    rm -f /root/3x-ui.txt
    echo "x-ui успешно удалена. Продолжаем выполнение скрипта..."
fi

# Вывод всех команд кроме диалога — в лог
exec 3>&1  # Сохраняем stdout для сообщений пользователю
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

REALITY_PORT=8443
HYSTERIA_PORT=8444

DOMAINS=("ozon.ru" "games.mail.ru")
BEST_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}

echo -e "${green}VLESS инбаунд: in-${REALITY_PORT}-tcp → порт ${REALITY_PORT}${plain}" >&3
echo -e "${green}Hysteria2 порт: ${HYSTERIA_PORT}${plain}" >&3
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


case "${release}" in
    ubuntu | debian | armbian)
        apt-get update > /dev/null 2>&1
        apt-get install -y -q wget curl tar tzdata jq xxd qrencode sqlite3 > /dev/null 2>&1
        ;;
    centos | rhel | almalinux | rocky | ol)
        yum -y update > /dev/null 2>&1
        yum install -y -q wget curl tar tzdata jq xxd qrencode sqlite > /dev/null 2>&1
        ;;
    fedora | amzn | virtuozzo)
        dnf -y update > /dev/null 2>&1
        dnf install -y -q wget curl tar tzdata jq xxd qrencode sqlite > /dev/null 2>&1
        ;;
    arch | manjaro | parch)
        pacman -Syu --noconfirm > /dev/null 2>&1
        pacman -S --noconfirm wget curl tar tzdata jq xxd qrencode sqlite > /dev/null 2>&1
        ;;
    opensuse-tumbleweed)
        zypper refresh > /dev/null 2>&1
        zypper install -y wget curl tar timezone jq xxd qrencode sqlite3 > /dev/null 2>&1
        ;;
    *)
        apt-get update > /dev/null 2>&1
        apt-get install -y wget curl tar tzdata jq xxd qrencode sqlite3 > /dev/null 2>&1
        ;;
esac

#3x-ui
cd /usr/local/ || exit 1
FILE="x-ui-linux-${ARCH}.tar.gz"
URL="https://github.com/MHSanaei/3x-ui/releases/download/v3.6.0/${FILE}"

systemctl stop x-ui 2>/dev/null || true
rm -rf /usr/local/x-ui/ "$FILE"

if ! wget -q -O "$FILE" "$URL"; then
    echo "Ошибка: не удалось скачать 3x-ui с GitHub" >&3
    exit 1
fi

if ! tar -xzf "$FILE"; then
    echo "Ошибка: не удалось распаковать архив 3x-ui" >&3
    rm -f "$FILE"
    exit 1
fi
rm -f "$FILE"

cd x-ui || exit 1
chmod +x x-ui bin/xray-linux-* 2>/dev/null || true

if [[ -f "bin/x-ui.service" ]]; then
    cp -f bin/x-ui.service /etc/systemd/system/
elif [[ -f "x-ui.service" ]]; then
    cp -f x-ui.service /etc/systemd/system/
else
    wget -q -O /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service
fi

FILE="/usr/bin/x-ui"
URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh"

if ! wget -q -O "$FILE" "$URL"; then
    echo "Ошибка: не удалось скачать x-ui.sh с GitHub"
    exit 1
fi

chmod +x /usr/local/x-ui/x-ui.sh /usr/bin/x-ui 2>/dev/null || true

WEBPATH_FORMATTED="/$(echo "$WEBPATH" | sed 's@^/@@;s@/$@@')/"

/usr/local/x-ui/x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "$WEBPATH_FORMATTED" >>"$LOG_FILE" 2>&1
/usr/local/x-ui/x-ui migrate >>"$LOG_FILE" 2>&1

systemctl daemon-reload >>"$LOG_FILE" 2>&1
systemctl enable x-ui >>"$LOG_FILE" 2>&1
systemctl start x-ui >>"$LOG_FILE" 2>&1


CLEAN_PATH=$(echo "$WEBPATH" | sed 's@^/@@;s@/$@@')

echo -e "${yellow}Ожидаем запуска панели...${plain}" >&3
for i in {1..15}; do
    sleep 2
    if curl -s -k -L --max-time 3 "http://127.0.0.1:${PORT}/${CLEAN_PATH}/" | grep -qiE "html|3x-ui|x-ui|login" 2>/dev/null; then
        echo -e "${green}Панель готова.${plain}" >&3
        break
    fi
    if [[ $i -eq 15 ]]; then
        echo -e "${yellow}Панель долго стартует, продолжаем...${plain}" >&3
    fi
done

XRAY_BIN="/usr/local/x-ui/bin/xray-linux-${ARCH}"
[[ -x "$XRAY_BIN" ]] || XRAY_BIN=$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' | head -n1)

KEYS=$("$XRAY_BIN" x25519 2>&1)
PRIVATE_KEY=$(echo "$KEYS" | awk -F': ' '/[Pp]rivate/{print $NF}' | tr -d '[:space:]')
PUBLIC_KEY=$(echo "$KEYS" | awk -F': ' '/[Pp]ublic|[Pp]assword/{print $NF}' | tr -d '[:space:]')
SHORT_ID=$(head -c 8 /dev/urandom | xxd -p)
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || gen_random_string 36)
EMAIL=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)

HYSTERIA_PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
SALAMANDER_PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)

# === Аутентификация в x-ui API ===
COOKIE_JAR=$(mktemp)

CLEAN_PATH=$(echo "$WEBPATH" | sed 's@^/@@;s@/$@@')

LOGIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${USERNAME}\", \"password\": \"${PASSWORD}\"}")

if ! echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    echo -e "${red}Ошибка авторизации через API.${plain}" >&3
    echo "$LOGIN_RESPONSE" >&3
    exit 1
fi

# === Генерация уникального SpiderX, SubID и массивов ShortIds ===
SPIDER_X="/$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)"
SUB_ID=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
NOW_MS=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")

SHORT_IDS_JSON="[]"
for len in 2 4 6 8 10 12 14 16; do
    sid=$(head -c $((len/2)) /dev/urandom | xxd -p)
    SHORT_IDS_JSON=$(echo "$SHORT_IDS_JSON" | jq --arg s "$sid" '. + [$s]')
done

# === Формирование JSON для VLESS Reality ===
SETTINGS_JSON=$(jq -nc \
  --arg uuid "$UUID" \
  --arg email "$EMAIL" \
  --arg subid "$SUB_ID" \
  --argjson created "$NOW_MS" '{
  clients: [
    {
      id: $uuid,
      email: $email,
      flow: "xtls-rprx-vision",
      limitIp: 0,
      totalGB: 0,
      expiryTime: 0,
      enable: true,
      tgId: 0,
      subId: $subid,
      comment: "",
      reset: 0,
      created_at: $created,
      updated_at: $created
    }
  ],
  decryption: "mlkem768x25519plus.native.600s.iGcs-rpqJJDbB7-OIES2XhsfmZ_EQ6nHXyqSpYIqQXE",
  encryption: "mlkem768x25519plus.native.0rtt.9bj2xAkpgSD1Sf0UrMczep4TKwT5eZdVqVU5lI5O6zM",
  testseed: [900, 500, 900, 256]
}')

STREAM_SETTINGS_JSON=$(jq -nc \
  --arg pbk "$PUBLIC_KEY" \
  --arg prk "$PRIVATE_KEY" \
  --argjson sids "$SHORT_IDS_JSON" \
  --arg domain "$BEST_DOMAIN" \
  --arg spx "$SPIDER_X" '{
  network: "tcp",
  tcpSettings: {
    acceptProxyProtocol: false,
    header: { type: "none" }
  },
  security: "reality",
  realitySettings: {
    show: false,
    xver: 0,
    target: ($domain + ":443"),
    serverNames: [("www." + $domain), $domain],
    privateKey: $prk,
    minClientVer: "",
    maxClientVer: "",
    maxTimediff: 0,
    shortIds: $sids,
    mldsa65Seed: "",
    limitFallbackUpload: { afterBytes: 0, bytesPerSec: 0, burstBytesPerSec: 0 },
    limitFallbackDownload: { afterBytes: 0, bytesPerSec: 0, burstBytesPerSec: 0 },
    settings: {
      publicKey: $pbk,
      fingerprint: "firefox",
      serverName: "",
      spiderX: $spx,
      mldsa65Verify: ""
    }
  }
}')

SNIFFING_JSON=$(jq -nc '{
  enabled: true,
  destOverride: ["http", "tls"]
}')

# === Отправка VLESS инбаунда через API ===
ADD_RESULT=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --argjson settings "$SETTINGS_JSON" \
    --argjson stream "$STREAM_SETTINGS_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    --arg port "$REALITY_PORT" \
    '{
      enable: true,
      remark: "VLESS-Reality",
      listen: "",
      port: ($port | tonumber),
      protocol: "vless",
      tag: ("in-" + $port + "-tcp"),
      settings: ($settings | tostring),
      streamSettings: ($stream | tostring),
      sniffing: ($sniffing | tostring)
    }')"
)

if echo "$ADD_RESULT" | grep -q '"success":true'; then
    echo -e "${green}VLESS Reality инбаунд успешно добавлен.${plain}" >&3
else
    echo -e "${red}Ошибка добавления VLESS инбаунда:${plain}" >&3
    echo "$ADD_RESULT" >&3
fi

# === Проверка директории и сертификатов ===
mkdir -p /root/cert/ip
if [[ ! -s "/root/cert/ip/fullchain.pem" || ! -s "/root/cert/ip/privkey.pem" ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "/root/cert/ip/privkey.pem" -out "/root/cert/ip/fullchain.pem" \
        -days 3650 -subj "/CN=${BEST_DOMAIN}" >/dev/null 2>&1
    chmod 600 /root/cert/ip/privkey.pem
fi

# === Формирование JSON для Hysteria2 ===
NOW_MS=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")

HYSTERIA_SETTINGS_JSON=$(jq -nc \
  --arg auth "$HYSTERIA_PASSWORD" \
  --arg email "$EMAIL" \
  --arg subid "$SUB_ID" \
  --argjson created "$NOW_MS" '{
  clients: [
    {
      auth: $auth,
      email: $email,
      limitIp: 0,
      totalGB: 0,
      expiryTime: 0,
      enable: true,
      tgId: 0,
      subId: $subid,
      comment: "",
      reset: 0,
      created_at: $created,
      updated_at: $created
    }
  ],
  version: 2
}')

HYSTERIA_STREAM_JSON=$(jq -nc \
  --arg domain "$BEST_DOMAIN" \
  --arg salpass "$SALAMANDER_PASSWORD" '{
  network: "hysteria",
  hysteriaSettings: {
    version: 2,
    udpIdleTimeout: 60
  },
  security: "tls",
  tlsSettings: {
    serverName: $domain,
    minVersion: "1.2",
    maxVersion: "1.3",
    cipherSuites: "",
    rejectUnknownSni: false,
    disableSystemRoot: false,
    enableSessionResumption: false,
    certificates: [
      {
        certificateFile: "/root/cert/ip/fullchain.pem",
        keyFile: "/root/cert/ip/privkey.pem",
        ocspStapling: 0,
        oneTimeLoading: false,
        usage: "encipherment",
        buildChain: false,
        useFile: true
      }
    ],
    alpn: ["h3"],
    echServerKeys: "",
    settings: {
      fingerprint: "firefox",
      echConfigList: "",
      pinnedPeerCertSha256: [],
      verifyPeerCertByName: ""
    }
  },
  finalmask: {
    udp: [
      {
        type: "salamander",
        settings: {
          password: $salpass
        }
      }
    ]
  }
}')

SNIFFING_JSON=$(jq -nc '{
  enabled: true,
  destOverride: ["http", "tls"]
}')

# === Отправка Hysteria инбаунда через API ===
ADD_HY2_RESULT=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --argjson settings "$HYSTERIA_SETTINGS_JSON" \
    --argjson stream "$HYSTERIA_STREAM_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    --arg port "$HYSTERIA_PORT" \
    '{
      enable: true,
      remark: "Hysteria2",
      listen: "",
      port: ($port | tonumber),
      protocol: "hysteria",
      tag: ("in-" + $port + "-udp"),
      settings: ($settings | tostring),
      streamSettings: ($stream | tostring),
      sniffing: ($sniffing | tostring)
    }')"
)

# Проверку статуса выносим СРАЗУ после запроса:
if echo "$ADD_HY2_RESULT" | grep -q '"success":true'; then
    echo -e "${green}Hysteria2 инбаунд успешно добавлен.${plain}" >&3
else
    echo -e "${red}Ошибка добавления Hysteria2 инбаунда:${plain}" >&3
    echo "$ADD_HY2_RESULT" >&3
fi

# === Блок установки и настройки WARP ===
if [[ "$INSTALL_WARP" == true ]]; then
    echo -e "${yellow}Установка Cloudflare WARP...${plain}" >&3
    if wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/warp_menu.sh >/dev/null 2>&1; then
        echo -e "1\n" | bash /tmp/warp_menu.sh c >/dev/null 2>&1
        rm -f /tmp/warp_menu.sh
        echo -e "${green}Cloudflare WARP успешно установлен на сервер.${plain}" >&3
        
        echo -e "${yellow}Настройка маршрутизации WARP в 3x-ui...${plain}" >&3
        
        XRAY_CONFIG=$(jq -nc --arg vlesstag "in-${REALITY_PORT}-tcp" '{
          log: { access: "none", dnsLog: false, error: "", loglevel: "warning" },
          api: { tag: "api", services: ["HandlerService", "LoggerService", "StatsService"] },
          inbounds: [
            { tag: "api", listen: "127.0.0.1", port: 62789, protocol: "dokodemo-door", settings: { address: "127.0.0.1" } }
          ],
          outbounds: [
            { tag: "direct", protocol: "freedom", settings: {} },
            { tag: "blocked", protocol: "blackhole", settings: {} },
            { tag: "WARP", protocol: "socks", settings: { servers: [{ address: "127.0.0.1", port: 40000 }] } }
          ],
          routing: {
            domainStrategy: "AsIs",
            rules: [
              { type: "field", inboundTag: ["api"], outboundTag: "api" },
              { type: "field", outboundTag: "blocked", ip: ["geoip:private"] },
              { type: "field", outboundTag: "blocked", protocol: ["bittorrent"] },
              { type: "field", inboundTag: [$vlesstag], outboundTag: "WARP" }
            ]
          }
        }')

        sqlite3 /etc/x-ui/x-ui.db "UPDATE configs SET value='$(echo "$XRAY_CONFIG" | sed "s/'/''/g")' WHERE key='xrayTemplateConfig';" 2>/dev/null || true
        
        curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${CLEAN_PATH}/server/restartXrayService" >/dev/null 2>&1
        systemctl restart x-ui >>"$LOG_FILE" 2>&1
        
        echo -e "${green}Трафик VLESS Reality успешно перенаправлен через WARP!${plain}" >&3
    else
        echo -e "${red}Не удалось загрузить скрипт WARP.${plain}" >&3
    fi
fi

rm -f "$COOKIE_JAR"

# === Формирование итоговых ссылок подключения ===
SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${BEST_DOMAIN}&fp=firefox&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F#VLESS-Reality"
HY2_LINK="hysteria2://${HYSTERIA_PASSWORD}@${SERVER_IP}:${HYSTERIA_PORT}?insecure=1&sni=${BEST_DOMAIN}#Hysteria2"

# === Вывод в консоль ===
echo -e "\n\033[1;32m══════════════════════════════════════════════════\033[0m" >&3
echo -e "\033[1;32m   VLESS Reality Ключ\033[0m" >&3
echo -e "\033[1;32m══════════════════════════════════════════════════\033[0m" >&3
echo -e "${cyan}${VLESS_LINK}${plain}" >&3
echo -e "" >&3
qrencode -t ANSIUTF8 "$VLESS_LINK"
echo -e "" >&3

echo -e "\033[1;32m══════════════════════════════════════════════════\033[0m" >&3
echo -e "\033[1;32m   Hysteria2 Ключ\033[0m" >&3
echo -e "\033[1;32m══════════════════════════════════════════════════\033[0m" >&3
echo -e "${cyan}${HY2_LINK}${plain}" >&3
echo -e "" >&3
qrencode -t ANSIUTF8 "$HY2_LINK"
echo -e "" >&3

echo -e "\033[1;32m══════════════════════════════════════════════════\033[0m" >&3
echo -e "\033[1;32m   Панель управления 3X-UI\033[0m" >&3
echo -e "\033[1;32m══════════════════════════════════════════════════\033[0m" >&3
echo -e "Адрес панели: \033[1;36mhttp://${SERVER_IP}:${PORT}/${CLEAN_PATH}\033[0m" >&3
echo -e "Логин:        \033[1;33m${USERNAME}\033[0m" >&3
echo -e "Пароль:       \033[1;33m${PASSWORD}\033[0m" >&3
echo -e "" >&3
echo -e "Инструкции по настройке VPN клиентов:" >&3
echo -e "\033[1;34mhttps://github.com/YukiKras/wiki/blob/main/nastroikavpn.md\033[0m" >&3
echo -e "" >&3
echo -e "Все данные сохранены в файл: \033[1;36m/root/3x-ui.txt\033[0m" >&3
echo -e "Для просмотра в будущем введите: \033[0;36mcat /root/3x-ui.txt\033[0m\n" >&3

# === Запись всех данных в /root/3x-ui.txt ===
{
echo "======================================"
echo "   VLESS Reality"
echo "======================================"
echo "$VLESS_LINK"
echo ""
echo "Порт: ${REALITY_PORT} | SNI: ${BEST_DOMAIN}"
echo ""
echo "======================================"
echo "   Hysteria2"
echo "======================================"
echo "$HY2_LINK"
echo ""
echo "Порт: ${HYSTERIA_PORT} | SNI: ${BEST_DOMAIN}"
echo ""
echo "======================================"
echo "   Панель управления 3X-UI"
echo "======================================"
echo "Адрес:  http://${SERVER_IP}:${PORT}/${CLEAN_PATH}"
echo "Логин:  ${USERNAME}"
echo "Пароль: ${PASSWORD}"
echo ""
echo "Инструкции по настройке VPN клиентов:"
echo "https://github.com/YukiKras/wiki/blob/main/nastroikavpn.md"
} > /root/3x-ui.txt
