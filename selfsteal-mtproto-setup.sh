#!/bin/bash

# ============================================================
#  MTPSSteal v5 — mtproto.zig + DPI Evasion
#
#  Высокопроизводительный MTProto прокси с полной DPI-защитой:
#    — mtproto.zig: 126 КБ, ~120 КБ RAM, 0 зависимостей
#    — FakeTLS 1.3, Split-TLS, DRS, Anti-replay
#    — TCPMSS=88: фрагментация ClientHello на 6 TCP-пакетов
#    — zapret/nfqws: TCP desync (fake packets + TTL spoofing)
#    — Маскировка: forward на реальный сайт при DPI-пробе
#    — IPv6 auto-hopping через Cloudflare (опционально)
#
#  Требования: Debian/Ubuntu 20.04+, root, домен с A-записью
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

echo -e "${CYAN}"
cat << 'BANNER'
 ╔══════════════════════════════════════════════════════════╗
 ║       MTPSSteal v5 — mtproto.zig + DPI Evasion          ║
 ║       Высокопроизводительный MTProto прокси              ║
 ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✗] Запусти от root: sudo bash $0${NC}"
    exit 1
fi

# ── Домен ─────────────────────────────────────────────────
read -rp "$(echo -e "${YELLOW}[?] Твой домен (например, proxy.example.com): ${NC}")" DOMAIN
DOMAIN=$(echo "$DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')
[[ -z "$DOMAIN" ]] && { echo -e "${RED}[✗] Домен не может быть пустым${NC}"; exit 1; }

# ── Домен маскировки ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Домен маскировки (реальный сайт для перенаправления DPI-проб):${NC}"
echo ""
echo -e "  ${CYAN}1)${NC} wb.ru               ${DIM}— Wildberries, естественный трафик из РФ${NC}"
echo -e "  ${CYAN}2)${NC} www.ozon.ru         ${DIM}— Ozon, российский e-commerce${NC}"
echo -e "  ${CYAN}3)${NC} www.avito.ru        ${DIM}— Avito${NC}"
echo -e "  ${CYAN}4)${NC} www.google.com      ${DIM}— универсальный${NC}"
echo -e "  ${CYAN}5)${NC} Свой домен          ${DIM}— ввести вручную${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}[?] Выбор (1-5) [по умолчанию: 1]: ${NC}")" MASK_CHOICE
MASK_CHOICE=${MASK_CHOICE:-1}

case "$MASK_CHOICE" in
    1) TLS_DOMAIN="wb.ru" ;;
    2) TLS_DOMAIN="www.ozon.ru" ;;
    3) TLS_DOMAIN="www.avito.ru" ;;
    4) TLS_DOMAIN="www.google.com" ;;
    5) read -rp "$(echo -e "${YELLOW}[?] Домен маскировки: ${NC}")" TLS_DOMAIN ;;
    *) TLS_DOMAIN="wb.ru" ;;
esac
echo -e "${GREEN}[✓] Маскировка под: ${TLS_DOMAIN}${NC}"

# ── zapret ────────────────────────────────────────────────
echo ""
read -rp "$(echo -e "${YELLOW}[?] Установить zapret/nfqws для TCP desync? (y/n) [y]: ${NC}")" INSTALL_ZAPRET
INSTALL_ZAPRET=${INSTALL_ZAPRET:-y}

# ── DNS-проверка ──────────────────────────────────────────
echo ""
echo -e "${CYAN}[*] Проверяю DNS для ${DOMAIN}...${NC}"
SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")
DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)

if [[ -z "$DOMAIN_IP" ]]; then
    echo -e "${RED}[✗] ${DOMAIN} не резолвится — добавь A-запись: ${DOMAIN} → ${SERVER_IP}${NC}"
    read -rp "$(echo -e "${YELLOW}[?] Продолжить? (y/n): ${NC}")" CONT
    [[ "$CONT" != "y" ]] && exit 1
elif [[ "$SERVER_IP" == "$DOMAIN_IP" ]]; then
    echo -e "${GREEN}[✓] DNS OK: ${DOMAIN} → ${DOMAIN_IP}${NC}"
else
    echo -e "${YELLOW}[!] ${DOMAIN} → ${DOMAIN_IP}, но IP сервера ${SERVER_IP}${NC}"
    read -rp "$(echo -e "${YELLOW}[?] Продолжить? (y/n): ${NC}")" CONT
    [[ "$CONT" != "y" ]] && exit 1
fi

# ── Остановка старого mtprotoproxy ────────────────────────
echo -e "${CYAN}[*] Останавливаю старый прокси (если есть)...${NC}"
systemctl stop mtprotoproxy 2>/dev/null || true
systemctl disable mtprotoproxy 2>/dev/null || true
rm -f /etc/systemd/system/mtprotoproxy.service
systemctl stop mtproto-proxy 2>/dev/null || true
echo -e "${GREEN}[✓] Старый прокси остановлен${NC}"

# ── Зависимости ───────────────────────────────────────────
echo -e "${CYAN}[*] Устанавливаю зависимости...${NC}"
apt update -qq > /dev/null 2>&1
apt install -y git curl dnsutils ufw fail2ban xz-utils build-essential openssl python3 > /dev/null 2>&1
echo -e "${GREEN}[✓] Зависимости установлены${NC}"

# ── Zig ───────────────────────────────────────────────────
ZIG_VERSION="0.15.2"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ZIG_ARCH="x86_64" ;;
    aarch64) ZIG_ARCH="aarch64" ;;
    *) echo -e "${RED}[✗] Неподдерживаемая архитектура: ${ARCH}${NC}"; exit 1 ;;
esac

if command -v zig &>/dev/null && zig version 2>/dev/null | grep -q "0\.1[45]"; then
    echo -e "${DIM}[·] Zig $(zig version) уже установлен${NC}"
else
    echo -e "${CYAN}[*] Устанавливаю Zig ${ZIG_VERSION}...${NC}"
    # Новый формат URL: zig-ARCH-OS-VERSION
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
    if ! curl -sSfL "$ZIG_URL" -o /tmp/zig.tar.xz 2>/dev/null; then
        # Старый формат: zig-linux-ARCH-VERSION
        ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
        if ! curl -sSfL "$ZIG_URL" -o /tmp/zig.tar.xz 2>/dev/null; then
            echo -e "${RED}[✗] Не удалось скачать Zig ${ZIG_VERSION}${NC}"
            echo -e "${YELLOW}    Попробую 0.14.0...${NC}"
            ZIG_VERSION="0.14.0"
            ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
            if ! curl -sSfL "$ZIG_URL" -o /tmp/zig.tar.xz 2>/dev/null; then
                ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
                curl -sSfL "$ZIG_URL" -o /tmp/zig.tar.xz || {
                    echo -e "${RED}[✗] Не удалось скачать Zig. Установи вручную: https://ziglang.org/download/${NC}"
                    exit 1
                }
            fi
        fi
    fi
    tar xJf /tmp/zig.tar.xz -C /usr/local
    # Найти распакованную папку
    ZIG_DIR=$(ls -d /usr/local/zig-*-linux-${ZIG_VERSION}* 2>/dev/null | head -1)
    [[ -z "$ZIG_DIR" ]] && ZIG_DIR=$(ls -d /usr/local/zig-linux-*-${ZIG_VERSION}* 2>/dev/null | head -1)
    [[ -n "$ZIG_DIR" ]] && ln -sf "${ZIG_DIR}/zig" /usr/local/bin/zig
    rm -f /tmp/zig.tar.xz
    if zig version &>/dev/null; then
        echo -e "${GREEN}[✓] Zig $(zig version) установлен${NC}"
    else
        echo -e "${RED}[✗] Zig не работает после установки${NC}"
        exit 1
    fi
fi

# ── Сборка mtproto.zig ────────────────────────────────────
echo -e "${CYAN}[*] Собираю mtproto.zig (ReleaseFast)...${NC}"
PROXY_DIR="/opt/mtproto-proxy"
BUILD_DIR="/tmp/mtproto-zig-build"

rm -rf "$BUILD_DIR"
git clone -q https://github.com/sleep3r/mtproto.zig.git "$BUILD_DIR"
cd "$BUILD_DIR"

if zig build -Doptimize=ReleaseFast 2>&1 | tail -5; then
    mkdir -p "$PROXY_DIR"
    cp zig-out/bin/mtproto-proxy "$PROXY_DIR/"
    BIN_SIZE=$(du -h "$PROXY_DIR/mtproto-proxy" | awk '{print $1}')
    echo -e "${GREEN}[✓] mtproto.zig собран (${BIN_SIZE})${NC}"
else
    echo -e "${RED}[✗] Сборка не удалась${NC}"
    exit 1
fi

# Копируем deploy-скрипты если есть
[[ -d "${BUILD_DIR}/deploy" ]] && cp -r "${BUILD_DIR}/deploy" "${PROXY_DIR}/"

# ── Пользователь ──────────────────────────────────────────
if ! id mtproto &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -d "$PROXY_DIR" mtproto
fi

# ── Секрет + config.toml ──────────────────────────────────
SECRET=$(openssl rand -hex 16)

cat > "${PROXY_DIR}/config.toml" << TOMLEOF
[server]
port = 443

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
fast_mode = true

[access.users]
tg = "${SECRET}"
TOMLEOF

chown -R mtproto:mtproto "$PROXY_DIR"
echo -e "${GREEN}[✓] config.toml создан (секрет: 16 случайных байт)${NC}"

# ── systemd ───────────────────────────────────────────────
echo -e "${CYAN}[*] Создаю systemd-юнит...${NC}"
if [[ -f "${BUILD_DIR}/deploy/mtproto-proxy.service" ]]; then
    cp "${BUILD_DIR}/deploy/mtproto-proxy.service" /etc/systemd/system/
else
    cat > /etc/systemd/system/mtproto-proxy.service << 'SVCEOF'
[Unit]
Description=MTProto Proxy (mtproto.zig)
After=network.target

[Service]
Type=simple
User=mtproto
Group=mtproto
WorkingDirectory=/opt/mtproto-proxy
ExecStart=/opt/mtproto-proxy/mtproto-proxy /opt/mtproto-proxy/config.toml
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/mtproto-proxy
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SVCEOF
fi

systemctl daemon-reload
echo -e "${GREEN}[✓] Юнит создан${NC}"

# ── TCPMSS=88 ─────────────────────────────────────────────
echo -e "${CYAN}[*] Применяю TCPMSS=88...${NC}"
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
IFACE=${IFACE:-eth0}

iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "$IFACE" \
    --dport 443 -j TCPMSS --set-mss 88 2>/dev/null || true
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "$IFACE" \
    --dport 443 -j TCPMSS --set-mss 88

# Persist
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save > /dev/null 2>&1 || true
else
    iptables-save > /etc/iptables.rules 2>/dev/null || true
    grep -q "iptables-restore" /etc/rc.local 2>/dev/null || {
        printf '#!/bin/bash\niptables-restore < /etc/iptables.rules\n' > /etc/rc.local
        chmod +x /etc/rc.local
    }
fi
echo -e "${GREEN}[✓] TCPMSS=88 на ${IFACE} — ClientHello фрагментация${NC}"

# ── zapret/nfqws ──────────────────────────────────────────
if [[ "$INSTALL_ZAPRET" == "y" ]]; then
    echo -e "${CYAN}[*] Устанавливаю zapret/nfqws...${NC}"
    ZAPRET_DIR="/opt/zapret"

    if [[ -d "$ZAPRET_DIR" ]]; then
        git -C "$ZAPRET_DIR" pull -q 2>/dev/null || true
    else
        git clone -q https://github.com/bol-van/zapret.git "$ZAPRET_DIR"
    fi

    cd "$ZAPRET_DIR"
    if make -j"$(nproc)" > /dev/null 2>&1 && [[ -x "${ZAPRET_DIR}/nfq/nfqws" ]]; then

        cat > /etc/systemd/system/nfqws-mtproto.service << NFQEOF
[Unit]
Description=nfqws DPI desync for MTProto
After=network.target
Before=mtproto-proxy.service

[Service]
Type=simple
ExecStart=${ZAPRET_DIR}/nfq/nfqws \\
    --qnum=200 \\
    --dpi-desync=fake,disorder2 \\
    --dpi-desync-split-pos=1 \\
    --dpi-desync-ttl=6 \\
    --dpi-desync-fooling=md5sig,badsum \\
    --dpi-desync-fake-tls=${ZAPRET_DIR}/files/fake/tls_clienthello_www_google_com.bin
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
NFQEOF

        # NFQUEUE iptables rule
        iptables -t mangle -D POSTROUTING -o "$IFACE" -p tcp --dport 443 \
            -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:6 \
            -m mark ! --mark 0x40000000/0x40000000 \
            -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null || true

        iptables -t mangle -A POSTROUTING -o "$IFACE" -p tcp --dport 443 \
            -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:6 \
            -m mark ! --mark 0x40000000/0x40000000 \
            -j NFQUEUE --queue-num 200 --queue-bypass

        # Persist
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save > /dev/null 2>&1 || true
        else
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi

        systemctl daemon-reload
        systemctl enable nfqws-mtproto > /dev/null 2>&1
        systemctl start nfqws-mtproto
        echo -e "${GREEN}[✓] zapret/nfqws запущен${NC}"
        echo -e "${DIM}    Стратегия: fake,disorder2 + ttl=6 + md5sig,badsum${NC}"
        echo -e "${DIM}    Тонкая настройка: cd /opt/zapret && ./blockcheck.sh${NC}"
    else
        echo -e "${YELLOW}[!] zapret не собрался — пропускаю nfqws${NC}"
        INSTALL_ZAPRET="n"
    fi
fi

# ── fail2ban ──────────────────────────────────────────────
cat > /etc/fail2ban/jail.d/selfsteal.conf << 'F2B'
[sshd]
enabled = true
maxretry = 5
bantime = 3600
findtime = 600
F2B
systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban > /dev/null 2>&1
echo -e "${GREEN}[✓] fail2ban настроен${NC}"

# ── UFW ───────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp  > /dev/null 2>&1 || true
    ufw allow 443/tcp > /dev/null 2>&1 || true
    echo -e "${GREEN}[✓] UFW: 80, 443 открыты${NC}"
fi

# ── Запуск ─────────────────────────────────────────────────
echo -e "${CYAN}[*] Запускаю mtproto-proxy...${NC}"
systemctl enable mtproto-proxy > /dev/null 2>&1
systemctl restart mtproto-proxy
sleep 2

if systemctl is-active --quiet mtproto-proxy; then
    echo -e "${GREEN}[✓] mtproto-proxy запущен${NC}"
else
    echo -e "${RED}[✗] mtproto-proxy не запустился:${NC}"
    journalctl -u mtproto-proxy -n 10 --no-pager
fi

# ── Очистка ────────────────────────────────────────────────
rm -rf "$BUILD_DIR"

# ── Ссылка ─────────────────────────────────────────────────
HEX_DOMAIN=$(python3 -c "print('${TLS_DOMAIN}'.encode().hex())" 2>/dev/null || echo -n "${TLS_DOMAIN}" | od -A n -t x1 | tr -d ' \n')
FULL_SECRET="ee${SECRET}${HEX_DOMAIN}"
TG_LINK="https://t.me/proxy?server=${DOMAIN}&port=443&secret=${FULL_SECRET}"

# ── Итог ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✓  MTPSSteal v5 готов!                           ║${NC}"
echo -e "${GREEN}║         mtproto.zig + полная DPI-защита                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Домен:${NC}          ${CYAN}${DOMAIN}${NC}"
echo -e "  ${BOLD}IP сервера:${NC}     ${CYAN}${SERVER_IP}${NC}"
echo -e "  ${BOLD}Маскировка:${NC}     ${CYAN}${TLS_DOMAIN}${NC}"
echo -e "  ${BOLD}Прокси:${NC}         ${CYAN}mtproto.zig (Zig, ReleaseFast)${NC}"
echo ""
echo -e "  ${YELLOW}━━  Ссылка для Telegram  ━━${NC}"
echo ""
echo -e "  ${GREEN}${TG_LINK}${NC}"
echo ""
echo -e "  ${BOLD}Секрет:${NC} ${CYAN}${FULL_SECRET}${NC}"
echo ""
echo -e "  ${YELLOW}━━  DPI-защита  ━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} FakeTLS 1.3 — трафик = обычный HTTPS"
echo -e "  ${GREEN}✓${NC} TCPMSS=88 — ClientHello → 6 TCP-фрагментов"
echo -e "  ${GREEN}✓${NC} Split-TLS — 1-байтный чанкинг"
echo -e "  ${GREEN}✓${NC} DRS — имитация Chrome/Firefox"
echo -e "  ${GREEN}✓${NC} Anti-replay — блокировка ТСПУ Ревизор проб"
echo -e "  ${GREEN}✓${NC} Маскировка → ${TLS_DOMAIN}"
[[ "$INSTALL_ZAPRET" == "y" ]] && \
echo -e "  ${GREEN}✓${NC} zapret/nfqws — TCP desync + TTL spoofing"
echo ""
echo -e "  ${YELLOW}━━  Управление  ━━${NC}"
echo ""
echo -e "  ${DIM}journalctl -u mtproto-proxy -f${NC}     — логи прокси"
echo -e "  ${DIM}systemctl restart mtproto-proxy${NC}     — перезапуск"
echo -e "  ${DIM}nano ${PROXY_DIR}/config.toml${NC}       — конфиг"
[[ "$INSTALL_ZAPRET" == "y" ]] && \
echo -e "  ${DIM}cd /opt/zapret && ./blockcheck.sh${NC}   — подбор стратегии nfqws"
echo ""
