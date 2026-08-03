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

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
cyan='\033[0;36m'
plain='\033[0m'

XUI_VERSION="v3.5.0"
REALITY_PORT=8443
HYSTERIA_PORT=8444
REALITY_DEST_DOMAIN="ozon.ru"
REALITY_DEST="${REALITY_DEST_DOMAIN}:443"
HYSTERIA_SNI="ozon.ru"
CERT_DIR="/root/cert/ip"

if [[ $EUID -ne 0 ]]; then
    echo -e "${red}Ошибка:${plain} скрипт нужно запускать от root"
    exit 1
fi

exec 3>&1
LOG_FILE="/var/log/3x-ui_install_log.txt"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

echo -e "Весь процесс установки будет сохранён в файле: \033[0;36m${LOG_FILE}\033[0m" >&3
echo -e "\n\033[1;34mИдёт установка... Пожалуйста, не закрывайте терминал.\033[0m" >&3

if command -v x-ui &> /dev/null; then
    echo -e "${yellow}Обнаружена установленная панель x-ui.${plain}" >&3
    read -rp "Переустановить x-ui? [y/N]: " confirm
    confirm=${confirm,,}
    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        echo "Отмена." >&3
        exit 1
    fi
    systemctl stop x-ui 2>/dev/null
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
    echo -e "${red}Не удалось определить ОС${plain}" >&3
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
        apt-get update -y > /dev/null 2>&1
        apt-get install -y -q wget curl tar jq xxd qrencode uuid-runtime openssl ca-certificates > /dev/null 2>&1
        ;;
    centos | rhel | almalinux | rocky | ol | fedora | amzn | virtuozzo)
        (dnf -y update || yum -y update) > /dev/null 2>&1
        (dnf install -y -q wget curl tar jq xxd qrencode util-linux openssl || \
         yum install -y -q wget curl tar jq xxd qrencode util-linux openssl) > /dev/null 2>&1
        ;;
    arch | manjaro | parch)
        pacman -Syu --noconfirm > /dev/null 2>&1
        pacman -S --noconfirm wget curl tar jq xxd qrencode util-linux openssl > /dev/null 2>&1
        ;;
    *)
        apt-get update -y > /dev/null 2>&1
        apt-get install -y wget curl tar jq xxd qrencode uuid-runtime openssl > /dev/null 2>&1
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
    read -rp $'\033[0;33mВведите порт для панели (Enter для случайного): \033[0m' USER_PORT
    if [[ -n "$USER_PORT" ]]; then
        PANEL_PORT="$USER_PORT"
    else
        PANEL_PORT=$(( (RANDOM % 20000) + 20000 ))
    fi
else
    PANEL_PORT=$(( (RANDOM % 20000) + 20000 ))
fi

echo -e "${green}Сгенерированы случайные учётные данные панели.${plain}" >&3

echo -e "${yellow}Устанавливается 3x-ui ${XUI_VERSION}...${plain}" >&3
export XUI_NONINTERACTIVE=1
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) "${XUI_VERSION}" </dev/null

if ! command -v x-ui &>/dev/null; then
    echo -e "${red}Установка 3x-ui не удалась.${plain}" >&3
    exit 1
fi

xui_folder="/usr/local/x-ui"
XRAY_BIN="${xui_folder}/bin/xray-linux-${ARCH}"
[[ -x "$XRAY_BIN" ]] || XRAY_BIN=$(find "${xui_folder}/bin" -maxdepth 1 -type f -name 'xray-linux-*' | head -n1)

"${xui_folder}/x-ui" setting -username "$PANEL_USERNAME" -password "$PANEL_PASSWORD" -port "$PANEL_PORT" -webBasePath "$PANEL_WEBPATH" >>"$LOG_FILE" 2>&1
"${xui_folder}/x-ui" migrate >>"$LOG_FILE" 2>&1
systemctl daemon-reload >>"$LOG_FILE" 2>&1
systemctl enable x-ui >>"$LOG_FILE" 2>&1
systemctl restart x-ui >>"$LOG_FILE" 2>&1
sleep 3

mkdir -p "$CERT_DIR"
if [[ ! -s "${CERT_DIR}/fullchain.pem" || ! -s "${CERT_DIR}/privkey.pem" ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${CERT_DIR}/privkey.pem" -out "${CERT_DIR}/fullchain.pem" \
        -days 3650 -subj "/CN=${HYSTERIA_SNI}" >>"$LOG_FILE" 2>&1
fi
chmod 600 "${CERT_DIR}/privkey.pem"

X25519_OUT=$("$XRAY_BIN" x25519)
REALITY_PRIVATE_KEY=$(echo "$X25519_OUT" | grep -i "Private key" | sed -E 's/.*key:\s*//')
REALITY_PUBLIC_KEY=$(echo "$X25519_OUT" | grep -i "Password" | sed -E 's/.*Password:\s*//')
[[ -z "$REALITY_PUBLIC_KEY" ]] && REALITY_PUBLIC_KEY=$(echo "$X25519_OUT" | grep -i "Public key" | sed -E 's/.*key:\s*//')

SHORT_IDS_JSON="[]"
for len in 2 4 6 8 10 12 14 16; do
    sid=$(gen_hex $((len/2)))
    SHORT_IDS_JSON=$(echo "$SHORT_IDS_JSON" | jq --arg s "$sid" '. + [$s]')
done

SPIDER_X="/$(gen_random_string 14)"

MLDSA_SEED=""
MLDSA_VERIFY=""
if "$XRAY_BIN" mldsa65 -h >/dev/null 2>&1; then
    MLDSA_OUT=$("$XRAY_BIN" mldsa65 2>/dev/null)
    MLDSA_SEED=$(echo "$MLDSA_OUT"  | grep -i "Seed"   | sed -E 's/.*:\s*//')
    MLDSA_VERIFY=$(echo "$MLDSA_OUT" | grep -i "Verify" | sed -E 's/.*:\s*//')
fi

VLESS_DECRYPTION="none"
VLESS_ENCRYPTION="none"
if "$XRAY_BIN" vlessenc -h >/dev/null 2>&1; then
    VLESSENC_JSON=$("$XRAY_BIN" vlessenc --json 2>/dev/null)
    if echo "$VLESSENC_JSON" | jq -e '.mlkem768.decryption' >/dev/null 2>&1; then
        VLESS_DECRYPTION=$(echo "$VLESSENC_JSON" | jq -r '.mlkem768.decryption')
        VLESS_ENCRYPTION=$(echo "$VLESSENC_JSON" | jq -r '.mlkem768.encryption')
    fi
fi

CLIENT_UUID=$(gen_uuid)
CLIENT_EMAIL="client-$(gen_random_string 6)"
CLIENT_SUBID=$(gen_random_string 16)
HYSTERIA_PASSWORD=$(gen_random_string 16)
SALAMANDER_PASSWORD=$(gen_random_string 16)

echo -e "${green}Сгенерирован криптоматериал (Reality x25519, shortIds, PQ-поля).${plain}" >&3

WARP_OK=false
if [[ "$INSTALL_WARP" == true ]]; then
    echo -e "${yellow}Устанавливается WARP...${plain}" >&3
    if wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/warp_menu.sh >/dev/null 2>&1; then
        echo -e "1\n" | bash /tmp/warp_menu.sh c >>"$LOG_FILE" 2>&1
        if curl -s --max-time 3 -x socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
            WARP_OK=true
            echo -e "${green}WARP успешно установлен (socks5 127.0.0.1:40000).${plain}" >&3
        else
            echo -e "${yellow}WARP установлен, но проверка соединения не прошла — outbound всё равно будет добавлен.${plain}" >&3
            WARP_OK=true
        fi
        rm -f /tmp/warp_menu.sh
    else
        echo -e "${red}Не удалось загрузить скрипт WARP, пропускаю этот шаг.${plain}" >&3
    fi
fi

COOKIE_JAR=$(mktemp)
BASE_URL="http://127.0.0.1:${PANEL_PORT}/${PANEL_WEBPATH}"

LOGIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"${PANEL_USERNAME}\", \"password\": \"${PANEL_PASSWORD}\"}")

if ! echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    echo -e "${red}Ошибка авторизации в панели через API:${plain}" >&3
    echo "$LOGIN_RESPONSE" >&3
    echo -e "${yellow}Панель установлена, но автонастройка инбаундов через API прервана. Доделайте вручную в веб-интерфейсе.${plain}" >&3
    API_OK=false
else
    API_OK=true
fi

get_inbound_tag() {
    curl -s -b "$COOKIE_JAR" "${BASE_URL}/panel/api/inbounds/list" \
        | jq -r --argjson p "$1" '.obj[] | select(.port==$p) | .tag' | head -n1
}

REALITY_TAG=""
HYSTERIA_TAG=""

if [[ "$API_OK" == true ]]; then
    VLESS_SETTINGS=$(jq -nc \
        --arg uuid "$CLIENT_UUID" --arg email "$CLIENT_EMAIL" --arg subid "$CLIENT_SUBID" \
        --arg dec "$VLESS_DECRYPTION" '{
        clients: [{
            id: $uuid, flow: "xtls-rprx-vision", email: $email,
            limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: "", subId: $subid, reset: 0
        }],
        decryption: $dec,
        fallbacks: []
    }')

    REALITY_SETTINGS_INNER=$(jq -nc \
        --arg pbk "$REALITY_PUBLIC_KEY" --arg spx "$SPIDER_X" --arg mv "$MLDSA_VERIFY" \
        '{publicKey: $pbk, fingerprint: "chrome", serverName: "", spiderX: $spx}
         + (if $mv != "" then {mldsa65Verify: $mv} else {} end)')

    STREAM_SETTINGS_REALITY=$(jq -nc \
        --arg dest "$REALITY_DEST" --arg sni1 "$REALITY_DEST_DOMAIN" --arg sni2 "www.${REALITY_DEST_DOMAIN}" \
        --arg prk "$REALITY_PRIVATE_KEY" --argjson sids "$SHORT_IDS_JSON" --arg seed "$MLDSA_SEED" \
        --argjson inner "$REALITY_SETTINGS_INNER" '{
        network: "tcp",
        security: "reality",
        realitySettings: ({
            show: false, dest: $dest, xver: 0,
            serverNames: [$sni1, $sni2],
            privateKey: $prk, minClientVer: "", maxClientVer: "", maxTimeDiff: 0,
            shortIds: $sids, settings: $inner
        } + (if $seed != "" then {mldsa65Seed: $seed} else {} end))
    }')

    SNIFFING=$(jq -nc '{enabled:true, destOverride:["http","tls"], metadataOnly:false, routeOnly:false}')

    ADD_REALITY=$(curl -s -b "$COOKIE_JAR" -X POST "${BASE_URL}/panel/api/inbounds/add" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --argjson s "$VLESS_SETTINGS" --argjson ss "$STREAM_SETTINGS_REALITY" --argjson sn "$SNIFFING" '{
            enable: true, remark: "VLESS-Reality", listen: "", port: '"${REALITY_PORT}"',
            protocol: "vless",
            settings: ($s|tostring), streamSettings: ($ss|tostring), sniffing: ($sn|tostring)
        }')")

    if echo "$ADD_REALITY" | grep -q '"success":true'; then
        echo -e "${green}Инбаунд VLESS+Reality (порт ${REALITY_PORT}) добавлен.${plain}" >&3
    else
        echo -e "${red}Ошибка добавления VLESS+Reality:${plain}" >&3; echo "$ADD_REALITY" >&3
    fi

    HYSTERIA_SETTINGS=$(jq -nc --arg pass "$HYSTERIA_PASSWORD" --arg email "$CLIENT_EMAIL" --arg subid "$CLIENT_SUBID" '{
        clients: [{ password: $pass, email: $email, limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: "", subId: $subid, reset: 0 }],
        ignoreClientBandwidth: false
    }')

    STREAM_SETTINGS_HY2=$(jq -nc \
        --arg sni "$HYSTERIA_SNI" --arg cert "${CERT_DIR}/fullchain.pem" --arg key "${CERT_DIR}/privkey.pem" \
        --arg salpass "$SALAMANDER_PASSWORD" '{
        network: "tcp",
        security: "tls",
        tlsSettings: {
            serverName: $sni, minVersion: "1.2", maxVersion: "1.3",
            alpn: ["h3"], fingerprint: "chrome", rejectUnknownSni: false,
            certificates: [{ certificateFile: $cert, keyFile: $key }]
        },
        sockopt: { udpIdleTimeoutSec: 60 },
        hy2UdpMasks: [{ type: "salamander", password: $salpass }]
    }')

    ADD_HY2=$(curl -s -b "$COOKIE_JAR" -X POST "${BASE_URL}/panel/api/inbounds/add" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --argjson s "$HYSTERIA_SETTINGS" --argjson ss "$STREAM_SETTINGS_HY2" --argjson sn "$SNIFFING" '{
            enable: true, remark: "Hysteria2", listen: "", port: '"${HYSTERIA_PORT}"',
            protocol: "hysteria2",
            settings: ($s|tostring), streamSettings: ($ss|tostring), sniffing: ($sn|tostring)
        }')")

    if echo "$ADD_HY2" | grep -q '"success":true'; then
        echo -e "${green}Инбаунд Hysteria2 (порт ${HYSTERIA_PORT}) добавлен.${plain}" >&3
    else
        echo -e "${red}Ошибка добавления Hysteria2:${plain}" >&3; echo "$ADD_HY2" >&3
    fi

    systemctl restart x-ui >>"$LOG_FILE" 2>&1
    sleep 2

    REALITY_TAG=$(get_inbound_tag "$REALITY_PORT")
    HYSTERIA_TAG=$(get_inbound_tag "$HYSTERIA_PORT")

    if [[ "$WARP_OK" == true ]]; then
        XRAY_GLOBAL=$(jq -nc --arg intag "$REALITY_TAG" '{
            log: { access: "none", dnsLog: false, error: "", loglevel: "warning", maskAddress: "" },
            api: { tag: "api", services: ["HandlerService","LoggerService","StatsService"] },
            inbounds: [{ tag: "api", listen: "127.0.0.1", port: 62789, protocol: "dokodemo-door", settings: { address: "127.0.0.1" } }],
            outbounds: [
                { tag: "direct", protocol: "freedom", settings: { domainStrategy: "AsIs", redirect: "", noises: [] } },
                { tag: "blocked", protocol: "blackhole", settings: {} },
                { tag: "warp", protocol: "socks", settings: { servers: [{ address: "127.0.0.1", port: 40000, users: [] }] } }
            ],
            policy: {
                levels: { "0": { statsUserDownlink: true, statsUserUplink: true } },
                system: { statsInboundDownlink: true, statsInboundUplink: true, statsOutboundDownlink: false, statsOutboundUplink: false }
            },
            routing: {
                domainStrategy: "AsIs",
                rules: [
                    { type: "field", inboundTag: ["api"], outboundTag: "api" },
                    { type: "field", outboundTag: "blocked", ip: ["geoip:private"] },
                    { type: "field", outboundTag: "blocked", protocol: ["bittorrent"] }
                ] + (if $intag != "" then [{ type: "field", inboundTag: [$intag], outboundTag: "warp" }] else [] end)
            },
            stats: {},
            metrics: { tag: "metrics_out", listen: "127.0.0.1:11111" }
        }')

        XRAY_GLOBAL_ENCODED=$(echo "$XRAY_GLOBAL" | jq -sRr @uri)
        UPD=$(curl -s -b "$COOKIE_JAR" -X POST "${BASE_URL}/panel/api/xray/update" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data-raw "xraySetting=${XRAY_GLOBAL_ENCODED}")

        if echo "$UPD" | grep -q '"success":true'; then
            echo -e "${green}WARP настроен как outbound; трафик VLESS-инбаунда (${REALITY_TAG:-неизвестный tag}) направлен через WARP.${plain}" >&3
            curl -s -b "$COOKIE_JAR" -X POST "${BASE_URL}/server/restartXrayService" >/dev/null 2>&1 \
              || curl -s -b "$COOKIE_JAR" -X POST "${BASE_URL}/panel/api/server/restartXrayService" >/dev/null 2>&1
        else
            echo -e "${red}Ошибка обновления глобального конфига Xray (WARP):${plain}" >&3; echo "$UPD" >&3
            echo -e "${yellow}Возможно, в этой версии путь другой — проверьте вручную вкладку 'Исходящие'/'Маршрутизация' в панели.${plain}" >&3
        fi
    fi

    rm -f "$COOKIE_JAR"
fi

systemctl restart x-ui >>"$LOG_FILE" 2>&1

SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)

SPIDER_X_ENC=$(jq -rn --arg s "$SPIDER_X" '$s|@uri')
FIRST_SHORT_ID=$(echo "$SHORT_IDS_JSON" | jq -r '.[0]')
VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:${REALITY_PORT}?type=tcp&security=reality&flow=xtls-rprx-vision&sni=${REALITY_DEST_DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${FIRST_SHORT_ID}&spx=${SPIDER_X_ENC}#${CLIENT_EMAIL}"
[[ "$VLESS_ENCRYPTION" != "none" && -n "$VLESS_ENCRYPTION" ]] && VLESS_LINK="${VLESS_LINK}&encryption=${VLESS_ENCRYPTION}"

HY2_LINK="hysteria2://${HYSTERIA_PASSWORD}@${SERVER_IP}:${HYSTERIA_PORT}?sni=${HYSTERIA_SNI}&alpn=h3&insecure=1&obfs=salamander&obfs-password=${SALAMANDER_PASSWORD}#${CLIENT_EMAIL}"

{
echo "==============================================="
echo " 3x-ui ${XUI_VERSION} — данные установки"
echo "==============================================="
echo "Панель:   http://${SERVER_IP}:${PANEL_PORT}/${PANEL_WEBPATH}"
echo "Логин:    ${PANEL_USERNAME}"
echo "Пароль:   ${PANEL_PASSWORD}"
echo ""
echo "--- VLESS + Reality (порт ${REALITY_PORT}) ---"
echo "UUID:            ${CLIENT_UUID}"
echo "SNI/dest:        ${REALITY_DEST}"
echo "Reality pubKey:  ${REALITY_PUBLIC_KEY}"
echo "Reality privKey: ${REALITY_PRIVATE_KEY}"
echo "ShortIds:        $(echo "$SHORT_IDS_JSON" | jq -r 'join(", ")')"
echo "SpiderX:         ${SPIDER_X}"
[[ -n "$MLDSA_SEED" ]] && echo "mldsa65 Seed:    ${MLDSA_SEED}"
[[ "$VLESS_DECRYPTION" != "none" ]] && echo "VLESS decryption (PQ): ${VLESS_DECRYPTION}"
echo "Ссылка:          ${VLESS_LINK}"
echo ""
echo "--- Hysteria2 (порт ${HYSTERIA_PORT}) ---"
echo "Пароль:          ${HYSTERIA_PASSWORD}"
echo "Salamander pass: ${SALAMANDER_PASSWORD}"
echo "SNI:             ${HYSTERIA_SNI}"
echo "Ссылка:          ${HY2_LINK}"
echo ""
echo "Subscription ID: ${CLIENT_SUBID}"
echo "WARP:            $([[ "$WARP_OK" == true ]] && echo "установлен, socks5 127.0.0.1:40000, привязан к VLESS-инбаунду" || echo "не установлен")"
echo "==============================================="
} > /root/3x-ui.txt

echo -e "" >&3
echo -e "${green}Готово! Итоговые данные сохранены в /root/3x-ui.txt${plain}" >&3
cat /root/3x-ui.txt >&3
echo -e "" >&3
echo -e "${cyan}QR-код VLESS+Reality:${plain}" >&3
qrencode -t ANSIUTF8 "$VLESS_LINK" >&3 2>/dev/null || true
echo -e "${cyan}QR-код Hysteria2:${plain}" >&3
qrencode -t ANSIUTF8 "$HY2_LINK" >&3 2>/dev/null || true
