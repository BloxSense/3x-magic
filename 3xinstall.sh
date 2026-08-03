#!/bin/bash
set -uo pipefail

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
            echo "Неизвестный аргумент: $1" >&2
            exit 1
            ;;
    esac
done

XUI_VERSION="v3.5.0"
REALITY_PORT=8443
HYSTERIA_PORT=8444
REALITY_DEST_DOMAIN="ozon.ru"
REALITY_DEST="${REALITY_DEST_DOMAIN}:443"
HYSTERIA_SNI="ozon.ru"
CERT_DIR="/root/cert/ip"

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: скрипт нужно запускать от root"
    exit 1
fi

LOG_FILE="/var/log/3x-ui_install_log.txt"
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

green='\033[0;32m'
cyan='\033[0;36m'
plain='\033[0m'

echo -e "${cyan}[1/5] Очистка старых компонентов...${plain}" >&3

if command -v x-ui &> /dev/null; then
    systemctl stop x-ui 2>/dev/null || true
    /usr/local/x-ui/x-ui uninstall -y &>/dev/null || true
    rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service
    systemctl daemon-reexec
    systemctl daemon-reload
    rm -f /root/3x-ui.txt
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

echo -e "${cyan}[2/5] Установка системных зависимостей...${plain}" >&3

case "${release}" in
    ubuntu | debian | armbian)
        apt-get update -y > /dev/null 2>&1
        apt-get install -y -q wget curl tar jq xxd qrencode uuid-runtime openssl ca-certificates sqlite3 > /dev/null 2>&1
        ;;
    centos | rhel | almalinux | rocky | ol | fedora | amzn | virtuozzo)
        (dnf -y update || yum -y update) > /dev/null 2>&1
        (dnf install -y -q wget curl tar jq xxd qrencode util-linux openssl sqlite || \
         yum install -y -q wget curl tar jq xxd qrencode util-linux openssl sqlite) > /dev/null 2>&1
        ;;
    arch | manjaro | parch)
        pacman -Syu --noconfirm > /dev/null 2>&1
        pacman -S --noconfirm wget curl tar jq xxd qrencode util-linux openssl sqlite > /dev/null 2>&1
        ;;
    *)
        apt-get update -y > /dev/null 2>&1
        apt-get install -y wget curl tar jq xxd qrencode uuid-runtime openssl sqlite3 > /dev/null 2>&1
        ;;
esac

gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}
gen_hex() {
    local nbytes="$1"
    head -c "$nbytes" /dev/urandom | xxd -p -c 256
}
gen_uuid() {
    if command -v uuidgen &>/dev/null; then uuidgen; else cat /proc/sys/kernel/random/uuid; fi
}

PANEL_USERNAME=$(gen_random_string 10)
PANEL_PASSWORD=$(gen_random_string 14)
PANEL_WEBPATH=$(gen_random_string 16)

if [[ "$EXTENDED_SETUP" == true ]]; then
    read -rp "Введите порт для панели (Enter для случайного): " USER_PORT
    if [[ -n "$USER_PORT" ]]; then
        PANEL_PORT="$USER_PORT"
    else
        PANEL_PORT=$(( (RANDOM % 20000) + 20000 ))
    fi
else
    PANEL_PORT=$(( (RANDOM % 20000) + 20000 ))
fi

echo -e "${cyan}[3/5] Загрузка панели 3x-ui ${XUI_VERSION}...${plain}" >&3
export XUI_NONINTERACTIVE=1
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) "${XUI_VERSION}" >/dev/null 2>&1

if ! command -v x-ui &>/dev/null; then
    echo "Ошибка: Установка 3x-ui не удалась." >&3
    exit 1
fi

xui_folder="/usr/local/x-ui"
XRAY_BIN="${xui_folder}/bin/xray-linux-${ARCH}"
[[ -x "$XRAY_BIN" ]] || XRAY_BIN=$(find "${xui_folder}/bin" -maxdepth 1 -type f -name 'xray-linux-*' | head -n1)

mkdir -p "$CERT_DIR"
if [[ ! -s "${CERT_DIR}/fullchain.pem" || ! -s "${CERT_DIR}/privkey.pem" ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${CERT_DIR}/privkey.pem" -out "${CERT_DIR}/fullchain.pem" \
        -days 3650 -subj "/CN=${HYSTERIA_SNI}" >/dev/null 2>&1
fi
chmod 600 "${CERT_DIR}/privkey.pem"

echo -e "${cyan}[4/5] Генерация ключей и сертов...${plain}" >&3
X25519_OUT=$("$XRAY_BIN" x25519 2>&1)
REALITY_PRIVATE_KEY=$(echo "$X25519_OUT" | awk -F': ' '/[Pp]rivate/{print $NF; exit}')
REALITY_PUBLIC_KEY=$(echo "$X25519_OUT" | awk -F': ' '/[Pp]assword/{print $NF; exit}')
[[ -z "$REALITY_PUBLIC_KEY" ]] && REALITY_PUBLIC_KEY=$(echo "$X25519_OUT" | awk -F': ' '/[Pp]ublic/{print $NF; exit}')

SHORT_IDS_JSON="[]"
for len in 2 4 6 8 10 12 14 16; do
    sid=$(gen_hex $((len/2)))
    SHORT_IDS_JSON=$(echo "$SHORT_IDS_JSON" | jq --arg s "$sid" '. + [$s]')
done

SPIDER_X="/$(gen_random_string 14)"
CLIENT_UUID=$(gen_uuid)
CLIENT_EMAIL="client-$(gen_random_string 6)"
CLIENT_SUBID=$(gen_random_string 16)
HYSTERIA_PASSWORD=$(gen_random_string 16)
SALAMANDER_PASSWORD=$(gen_random_string 16)

if [[ "$INSTALL_WARP" == true ]]; then
    echo -e "${cyan}[*] Установка Cloudflare WARP...${plain}" >&3
    if wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/warp_menu.sh >/dev/null 2>&1; then
        echo -e "1\n" | bash /tmp/warp_menu.sh c >/dev/null 2>&1
        rm -f /tmp/warp_menu.sh
    fi
fi

echo -e "${cyan}[5/5] Запись данных и инбаундов с клиентами в SQLite...${plain}" >&3
"${xui_folder}/x-ui" setting -username "$PANEL_USERNAME" -password "$PANEL_PASSWORD" -port "$PANEL_PORT" -webBasePath "$PANEL_WEBPATH" >/dev/null 2>&1
"${xui_folder}/x-ui" migrate >/dev/null 2>&1

# 1. Внедряем VLESS клиента внутрь поля settings
VLESS_SETTINGS=$(jq -nc --arg uuid "$CLIENT_UUID" --arg email "$CLIENT_EMAIL" --arg subid "$CLIENT_SUBID" '{
    clients: [{
        id: $uuid,
        flow: "xtls-rprx-vision",
        email: $email,
        limitIp: 0,
        totalGB: 0,
        expiryTime: 0,
        enable: true,
        tgId: "",
        subId: $subid,
        reset: 0
    }],
    decryption: "none",
    fallbacks: []
}')

STREAM_SETTINGS_REALITY=$(jq -nc \
    --arg dest "$REALITY_DEST" --arg sni1 "$REALITY_DEST_DOMAIN" --arg sni2 "www.${REALITY_DEST_DOMAIN}" \
    --arg prk "$REALITY_PRIVATE_KEY" --argjson sids "$SHORT_IDS_JSON" --arg pbk "$REALITY_PUBLIC_KEY" --arg spx "$SPIDER_X" '{
    network: "tcp",
    security: "reality",
    realitySettings: {
        show: false,
        dest: $dest,
        xver: 0,
        serverNames: [$sni1, $sni2],
        privateKey: $prk,
        minClientVer: "",
        maxClientVer: "",
        maxTimeDiff: 0,
        shortIds: $sids,
        settings: {publicKey: $pbk, fingerprint: "chrome", serverName: "", spiderX: $spx}
    }
}')

# 2. Внедряем Hysteria2 клиента внутрь поля settings
HYSTERIA_SETTINGS=$(jq -nc --arg pass "$HYSTERIA_PASSWORD" --arg email "$CLIENT_EMAIL" --arg subid "$CLIENT_SUBID" '{
    clients: [{
        password: $pass,
        email: $email,
        limitIp: 0,
        totalGB: 0,
        expiryTime: 0,
        enable: true,
        tgId: "",
        subId: $subid,
        reset: 0
    }],
    ignoreClientBandwidth: false
}')

STREAM_SETTINGS_HY2=$(jq -nc \
    --arg sni "$HYSTERIA_SNI" --arg cert "${CERT_DIR}/fullchain.pem" --arg key "${CERT_DIR}/privkey.pem" --arg salpass "$SALAMANDER_PASSWORD" '{
    network: "tcp",
    security: "tls",
    tlsSettings: {
        serverName: $sni,
        minVersion: "1.2",
        maxVersion: "1.3",
        alpn: ["h3"],
        fingerprint: "chrome",
        rejectUnknownSni: false,
        certificates: [{ certificateFile: $cert, keyFile: $key }]
    },
    sockopt: { udpIdleTimeoutSec: 60 },
    hy2UdpMasks: [{ type: "salamander", password: $salpass }]
}')

SNIFFING=$(jq -nc '{enabled:true, destOverride:["http","tls"], metadataOnly:false, routeOnly:false}')

# Запись в базу SQLite c клиентами
sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, 'VLESS-Reality', 1, 0, '', ${REALITY_PORT}, 'vless', '$(echo $VLESS_SETTINGS | sed "s/'/''/g")', '$(echo $STREAM_SETTINGS_REALITY | sed "s/'/''/g")', 'inbound-${REALITY_PORT}', '$(echo $SNIFFING | sed "s/'/''/g")');" 2>/dev/null || true

sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, 'Hysteria2', 1, 0, '', ${HYSTERIA_PORT}, 'hysteria2', '$(echo $HYSTERIA_SETTINGS | sed "s/'/''/g")', '$(echo $STREAM_SETTINGS_HY2 | sed "s/'/''/g")', 'inbound-${HYSTERIA_PORT}', '$(echo $SNIFFING | sed "s/'/''/g")');" 2>/dev/null || true

systemctl daemon-reload >/dev/null 2>&1
systemctl enable x-ui >/dev/null 2>&1
systemctl restart x-ui >/dev/null 2>&1

SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)
SPIDER_X_ENC=$(jq -rn --arg s "$SPIDER_X" '$s|@uri')
FIRST_SHORT_ID=$(echo "$SHORT_IDS_JSON" | jq -r '.[0]')

VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:${REALITY_PORT}?type=tcp&security=reality&flow=xtls-rprx-vision&sni=${REALITY_DEST_DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${FIRST_SHORT_ID}&spx=${SPIDER_X_ENC}#${CLIENT_EMAIL}"
# Добавлен insecure=1 для автоматического доверия не подписанному сертификату
HY2_LINK="hysteria2://${HYSTERIA_PASSWORD}@${SERVER_IP}:${HYSTERIA_PORT}?sni=${HYSTERIA_SNI}&alpn=h3&insecure=1&obfs=salamander&obfs-password=${SALAMANDER_PASSWORD}#${CLIENT_EMAIL}"

# Итоговый красивый консольный вывод строго по твоему ТЗ
echo -e "\n${green}[✓] Установка успешно завершена!${plain}\n" >&3
echo -e "==============================" >&3
echo -e "VLESS Reality:" >&3
echo -e "\`${VLESS_LINK}\`" >&3
echo -e "" >&3
echo -e "Кьюар:" >&3
qrencode -t ANSIUTF8 "$VLESS_LINK" >&3 2>/dev/null || true
echo -e "==============================" >&3
echo -e "Hysteria:" >&3
echo -e "\`${HY2_LINK}\`" >&3
echo -e "" >&3
echo -e "Кьюар:" >&3
qrencode -t ANSIUTF8 "$HY2_LINK" >&3 2>/dev/null || true
echo -e "==============================" >&3
echo -e "Панель 3x-ui" >&3
echo -e "Ссылка: http://${SERVER_IP}:${PANEL_PORT}/${PANEL_WEBPATH}" >&3
echo -e "Логин:  ${PANEL_USERNAME}" >&3
echo -e "Пароль: ${PANEL_PASSWORD}" >&3
echo -e "==============================" >&3
