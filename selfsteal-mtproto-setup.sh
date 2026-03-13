#!/bin/bash

# ============================================================
#  MTProto SelfSteal Installer
#  Telegram MTProto Proxy + Caddy (маскировка под свой домен)
#
#  Архитектура:
#    Port 443  → mtprotoproxy (faketls)
#                  ├─ MTProto клиент → туннель Telegram
#                  └─ DPI/сканер    → Caddy:8443 (реальный сайт)
#    Port 8443 → Caddy (TLS + stub-страница, только localhost)
#    Port 80   → Caddy (ACME + редирект)
#
#  Требования: Debian/Ubuntu, root, домен с A-записью на сервер
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
 ║       MTProto SelfSteal Installer                        ║
 ║       Telegram прокси под маскировкой своего домена      ║
 ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Root ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✗] Запусти от root: sudo bash $0${NC}"
    exit 1
fi

# ── Домен ─────────────────────────────────────────────────
read -rp "$(echo -e "${YELLOW}[?] Твой домен (например, example.com): ${NC}")" DOMAIN
DOMAIN=$(echo "$DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')
[[ -z "$DOMAIN" ]] && { echo -e "${RED}[✗] Домен не может быть пустым${NC}"; exit 1; }

# ── Выбор stub-страницы ────────────────────────────────────
echo ""
echo -e "${BOLD}  Выбери маскировочную страницу:${NC}"
echo ""
echo -e "  ${CYAN}1)${NC} Минимальный 404     ${DIM}— тёмный, лаконичный${NC}"
echo -e "  ${CYAN}2)${NC} Котики 404          ${DIM}— весёлый, с анимацией${NC}"
echo -e "  ${CYAN}3)${NC} Tech-компания        ${DIM}— корпоративный лендинг${NC}"
echo -e "  ${CYAN}4)${NC} Облачный хостинг     ${DIM}— SaaS / хостинг стиль${NC}"
echo -e "  ${CYAN}5)${NC} Личный блог          ${DIM}— инженерный блог${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}[?] Выбор (1-5) [по умолчанию: 1]: ${NC}")" STUB_CHOICE
STUB_CHOICE=${STUB_CHOICE:-1}
[[ ! "$STUB_CHOICE" =~ ^[1-5]$ ]] && STUB_CHOICE=1

STUB_NAMES=("Минимальный 404" "Котики 404" "Tech-компания" "Облачный хостинг" "Личный блог")
echo -e "${GREEN}[✓] Выбрано: ${STUB_NAMES[$((STUB_CHOICE-1))]}${NC}"

# ── DNS-проверка ──────────────────────────────────────────
echo ""
echo -e "${CYAN}[*] Проверяю DNS для ${DOMAIN}...${NC}"
SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")
DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)

if [[ -z "$DOMAIN_IP" ]]; then
    echo -e "${RED}[✗] ${DOMAIN} не резолвится${NC}"
    echo -e "    Добавь A-запись: ${CYAN}${DOMAIN} → ${SERVER_IP}${NC}"
    read -rp "$(echo -e "${YELLOW}[?] Продолжить? (y/n): ${NC}")" CONT
    [[ "$CONT" != "y" ]] && exit 1
elif [[ "$SERVER_IP" == "$DOMAIN_IP" ]]; then
    echo -e "${GREEN}[✓] DNS OK: ${DOMAIN} → ${DOMAIN_IP}${NC}"
else
    echo -e "${YELLOW}[!] ${DOMAIN} → ${DOMAIN_IP}, но IP сервера ${SERVER_IP}${NC}"
    read -rp "$(echo -e "${YELLOW}[?] Продолжить? (y/n): ${NC}")" CONT
    [[ "$CONT" != "y" ]] && exit 1
fi

# ── Зависимости ───────────────────────────────────────────
echo -e "${CYAN}[*] Устанавливаю зависимости...${NC}"
apt update -qq > /dev/null 2>&1
apt install -y python3 python3-pip git curl dnsutils ufw > /dev/null 2>&1

# ── Генерация секрета ──────────────────────────────────────
# faketls-секрет = "ee" + 16 случайных байт в hex (итого 34 символа)
# Домен маскировки задаётся отдельно через TLS_DOMAIN в config.py
FAKETLS_SECRET="ee$(python3 -c "import os; print(os.urandom(16).hex())")"
echo -e "${GREEN}[✓] Секрет сгенерирован${NC}"

# ── Установка mtprotoproxy ─────────────────────────────────
echo -e "${CYAN}[*] Устанавливаю mtprotoproxy...${NC}"
PROXY_DIR="/opt/mtprotoproxy"

if [[ -d "$PROXY_DIR" ]]; then
    echo -e "${YELLOW}[!] mtprotoproxy уже установлен, обновляю...${NC}"
    git -C "$PROXY_DIR" pull -q 2>/dev/null || true
else
    git clone -q https://github.com/alexbers/mtprotoproxy.git "$PROXY_DIR"
fi
echo -e "${GREEN}[✓] mtprotoproxy готов${NC}"

# ── Конфиг mtprotoproxy ────────────────────────────────────
cat > "${PROXY_DIR}/config.py" << PYEOF
# ── MTProto SelfSteal Config ────────────────────────────────
# Сгенерировано selfsteal-mtproto-setup.sh

# Порт (443 = максимальная скрытность)
PORT = 443

# Привязка
BIND_IP = "0.0.0.0"

# Пользователи и их faketls-секреты
# Формат секрета: "ee" + домен в hex = маскировка под TLS
USERS = {
    "user1": "${FAKETLS_SECRET}",
}

# Режим: faketls — трафик выглядит как обычный HTTPS
# Клиенту нужно указать именно faketls-секрет (начинается на "ee")
MODE = "faketls"

# Домен маскировки — должен совпадать с доменом в секрете
TLS_DOMAIN = "${DOMAIN}"

# КЛЮЧЕВАЯ НАСТРОЙКА SELFSTEAL:
# Куда перенаправлять DPI/сканеры, которые не говорят MTProto.
# Caddy слушает на 8080 (plain HTTP, только localhost) и отдаёт страницу.
PROXY_URL = "http://127.0.0.1:8080"

# Без ограничений на соединения
MAX_CONNECTIONS = 0
PYEOF

echo -e "${GREEN}[✓] Конфиг mtprotoproxy создан${NC}"

# ── Установка Caddy ───────────────────────────────────────
echo -e "${CYAN}[*] Устанавливаю Caddy...${NC}"
if ! command -v caddy &>/dev/null; then
    apt install -y debian-keyring debian-archive-keyring apt-transport-https > /dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    apt update -qq > /dev/null 2>&1
    apt install -y caddy > /dev/null 2>&1
fi
command -v caddy &>/dev/null \
    && echo -e "${GREEN}[✓] Caddy готов ($(caddy version 2>/dev/null | awk '{print $1}'))${NC}" \
    || { echo -e "${RED}[✗] Caddy не установился${NC}"; exit 1; }

# ── Stub-страницы ─────────────────────────────────────────
mkdir -p /var/www/html

create_stub_minimal() {
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>404 – Not Found</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#080b10;color:#9ba3b8;display:flex;justify-content:center;align-items:center;min-height:100vh}.wrap{text-align:center;padding:2rem}h1{font-size:clamp(5rem,18vw,11rem);font-weight:800;letter-spacing:-.04em;background:linear-gradient(135deg,#5b7cf6,#9b5bf6);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;line-height:1;animation:flicker 4s ease-in-out infinite}p{margin-top:.8rem;font-size:.95rem;color:#424860}@keyframes flicker{0%,100%{opacity:1}48%{opacity:1}50%{opacity:.7}52%{opacity:1}96%{opacity:1}98%{opacity:.5}99%{opacity:1}}</style></head><body><div class="wrap"><h1>404</h1><p>The resource you requested does not exist on this server.</p></div></body></html>
HTML
}

create_stub_cats() {
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>404 – Oops!</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:#160f22;color:#d0c4e8;display:flex;justify-content:center;align-items:center;min-height:100vh;overflow:hidden}.bg{position:fixed;inset:0;overflow:hidden;pointer-events:none}.bg span{position:absolute;font-size:1.6rem;opacity:.05;animation:fall linear infinite}.bg span:nth-child(1){left:8%;animation-duration:14s}.bg span:nth-child(2){left:25%;animation-duration:18s;animation-delay:3s}.bg span:nth-child(3){left:50%;animation-duration:16s;animation-delay:7s}.bg span:nth-child(4){left:72%;animation-duration:20s;animation-delay:1s}.bg span:nth-child(5){left:90%;animation-duration:13s;animation-delay:5s}@keyframes fall{from{top:-60px}to{top:110%}}.wrap{text-align:center;padding:2rem;position:relative;z-index:1}.emoji{font-size:5rem;animation:bob 3s ease-in-out infinite;display:block;margin-bottom:1rem}@keyframes bob{0%,100%{transform:translateY(0) rotate(-3deg)}50%{transform:translateY(-12px) rotate(3deg)}}h1{font-size:clamp(4rem,14vw,8rem);font-weight:800;background:linear-gradient(135deg,#ff6eb4,#b46aff,#6a9fff);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;line-height:1}.msg{font-size:1.1rem;color:#9b80c4;margin-top:.6rem}.paws{margin-top:1.5rem;font-size:1.3rem;letter-spacing:8px;opacity:.4}</style></head><body><div class="bg"><span>🐱</span><span>😸</span><span>🐈</span><span>😺</span><span>😻</span></div><div class="wrap"><span class="emoji">😿</span><h1>404</h1><p class="msg">The cat knocked this page off the table.</p><div class="paws">🐾 🐾 🐾</div></div></body></html>
HTML
}

create_stub_business() {
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>NovaTech Solutions</title><style>*{margin:0;padding:0;box-sizing:border-box}:root{--bg:#090c13;--s:#0f1320;--b:#1b2035;--a:#4e79f6;--a2:#7b54f5;--t:#b0b8cc;--td:#4a5168;--w:#e8ecf5}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--t);overflow-x:hidden}nav{position:fixed;top:0;width:100%;padding:1.1rem 3rem;display:flex;justify-content:space-between;align-items:center;z-index:10;backdrop-filter:blur(16px);background:rgba(9,12,19,.75);border-bottom:1px solid var(--b)}.logo{font-size:1.25rem;font-weight:800;color:var(--w)}.logo span{color:var(--a)}nav ul{list-style:none;display:flex;gap:1.8rem}nav a{color:var(--td);text-decoration:none;font-size:.88rem;transition:color .25s}nav a:hover{color:var(--w)}.hero{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:6rem 2rem 4rem;text-align:center;position:relative}.glow{position:absolute;width:400px;height:400px;border-radius:50%;filter:blur(100px);opacity:.1;pointer-events:none}.g1{background:var(--a);top:-80px;left:-80px}.g2{background:var(--a2);bottom:-80px;right:-80px}.badge{display:inline-block;padding:.35rem .9rem;border:1px solid var(--b);border-radius:50px;font-size:.75rem;color:var(--a);margin-bottom:1.8rem;letter-spacing:1.2px;text-transform:uppercase}h1{font-size:clamp(2.2rem,5.5vw,4rem);color:var(--w);font-weight:800;line-height:1.1;margin-bottom:1.3rem}h1 em{font-style:normal;background:linear-gradient(135deg,var(--a),var(--a2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}.sub{font-size:1.05rem;color:var(--td);max-width:520px;margin:0 auto 2.2rem;line-height:1.65}.btns{display:flex;gap:.8rem;justify-content:center}.btn{padding:.75rem 1.7rem;border-radius:7px;font-size:.9rem;font-weight:600;text-decoration:none;border:none;font-family:inherit;transition:all .25s;cursor:pointer}.btn-p{background:linear-gradient(135deg,var(--a),var(--a2));color:#fff}.btn-p:hover{transform:translateY(-2px)}.btn-o{background:transparent;color:var(--t);border:1px solid var(--b)}.btn-o:hover{border-color:var(--a);color:var(--w)}.stats{display:flex;gap:2.5rem;justify-content:center;margin-top:3.5rem;padding-top:2.5rem;border-top:1px solid var(--b);flex-wrap:wrap}.stat-n{font-size:2rem;font-weight:800;color:var(--w)}.stat-l{font-size:.8rem;color:var(--td);margin-top:.25rem}footer{text-align:center;padding:1.8rem;border-top:1px solid var(--b);font-size:.78rem;color:var(--td)}@media(max-width:580px){nav ul{display:none}}</style></head><body><nav><div class="logo">Nova<span>Tech</span></div><ul><li><a href="#">Solutions</a></li><li><a href="#">About</a></li><li><a href="#">Pricing</a></li><li><a href="#">Contact</a></li></ul></nav><section class="hero"><div class="glow g1"></div><div class="glow g2"></div><div><div class="badge">Digital Infrastructure Partner</div><h1>Building the <em>future</em> of cloud infrastructure</h1><p class="sub">We help companies scale with modern cloud-native solutions, enterprise-grade security, and zero-downtime deployments.</p><div class="btns"><a class="btn btn-p" href="#">Get Started</a><a class="btn btn-o" href="#">Learn More</a></div><div class="stats"><div><div class="stat-n">500+</div><div class="stat-l">Enterprise Clients</div></div><div><div class="stat-n">99.9%</div><div class="stat-l">Uptime SLA</div></div><div><div class="stat-n">24/7</div><div class="stat-l">Expert Support</div></div></div></div></section><footer>&copy; 2026 NovaTech Solutions. All rights reserved.</footer></body></html>
HTML
}

create_stub_hosting() {
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VortexHost — Lightning Fast Hosting</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Inter',sans-serif;background:#04060d;color:#a8b4cc;overflow-x:hidden}.orbs{position:fixed;inset:0;pointer-events:none;overflow:hidden}.orb{position:absolute;border-radius:50%;filter:blur(80px);opacity:.08}.orb1{width:500px;height:500px;background:#00d4ff;top:-150px;left:-100px;animation:drift1 20s ease-in-out infinite}.orb2{width:400px;height:400px;background:#0040ff;bottom:-100px;right:-100px;animation:drift2 18s ease-in-out infinite}@keyframes drift1{0%,100%{transform:translate(0,0)}50%{transform:translate(60px,40px)}}@keyframes drift2{0%,100%{transform:translate(0,0)}50%{transform:translate(-40px,-60px)}}nav{position:fixed;top:0;width:100%;padding:1rem 2.5rem;display:flex;justify-content:space-between;align-items:center;z-index:10;background:rgba(4,6,13,.8);backdrop-filter:blur(14px);border-bottom:1px solid rgba(255,255,255,.05)}.logo{font-weight:800;font-size:1.2rem;color:#fff}.logo span{color:#00d4ff}nav ul{list-style:none;display:flex;gap:1.6rem}nav a{color:#5a6a82;text-decoration:none;font-size:.85rem;transition:color .2s}nav a:hover{color:#fff}.hero{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:6rem 2rem 4rem;position:relative;z-index:1;text-align:center}.tag{display:inline-flex;align-items:center;gap:.4rem;padding:.3rem .9rem;border-radius:50px;background:rgba(0,212,255,.08);border:1px solid rgba(0,212,255,.2);color:#00d4ff;font-size:.75rem;margin-bottom:1.6rem;letter-spacing:.5px}h1{font-size:clamp(2rem,5vw,3.8rem);font-weight:800;color:#fff;line-height:1.1;margin-bottom:1.2rem}h1 span{background:linear-gradient(90deg,#00d4ff,#0088ff);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}.sub{font-size:1rem;color:#4a5a72;max-width:480px;margin:0 auto 2rem;line-height:1.65}.btns{display:flex;gap:.75rem;justify-content:center;flex-wrap:wrap;margin-bottom:2rem}.btn{padding:.7rem 1.6rem;border-radius:6px;font-size:.88rem;font-weight:600;text-decoration:none;transition:all .2s;font-family:inherit;cursor:pointer;border:none}.btn-c{background:linear-gradient(90deg,#00d4ff,#0060ff);color:#000}.btn-c:hover{transform:translateY(-2px)}.btn-g{background:rgba(255,255,255,.04);color:#7888a0;border:1px solid rgba(255,255,255,.08)}.btn-g:hover{border-color:#00d4ff;color:#fff}.features{display:flex;gap:1rem;justify-content:center;flex-wrap:wrap}.feat{display:flex;align-items:center;gap:.4rem;font-size:.8rem;color:#3a4a60}.feat::before{content:"✓";color:#00d4ff;font-weight:700}footer{text-align:center;padding:1.5rem;border-top:1px solid rgba(255,255,255,.04);font-size:.75rem;color:#2a3040}@media(max-width:560px){nav ul{display:none}}</style></head><body><div class="orbs"><div class="orb orb1"></div><div class="orb orb2"></div></div><nav><div class="logo">Vortex<span>Host</span></div><ul><li><a href="#">Hosting</a></li><li><a href="#">VPS</a></li><li><a href="#">Domains</a></li><li><a href="#">Support</a></li></ul></nav><section class="hero"><div><div class="tag">⚡ 99.99% Uptime Guaranteed</div><h1>Web hosting that's <span>lightning fast</span></h1><p class="sub">Deploy your projects in seconds with our global CDN, NVMe storage, and auto-scaling infrastructure.</p><div class="btns"><a class="btn btn-c" href="#">Start Free Trial</a><a class="btn btn-g" href="#">View Plans</a></div><div class="features"><span class="feat">Free SSL</span><span class="feat">Daily Backups</span><span class="feat">1-Click Deploy</span><span class="feat">24/7 Support</span></div></div></section><footer>&copy; 2026 VortexHost. All rights reserved.</footer></body></html>
HTML
}

create_stub_blog() {
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Alex Chen — Engineering Blog</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Georgia',serif;background:#faf8f5;color:#2d2926;line-height:1.7}nav{position:fixed;top:0;width:100%;padding:.9rem 2rem;display:flex;justify-content:space-between;align-items:center;background:#faf8f5;border-bottom:1px solid #e8e3da;z-index:10}.logo{font-size:1rem;font-weight:700;color:#1a1714}nav ul{list-style:none;display:flex;gap:1.5rem}nav a{color:#7a7068;text-decoration:none;font-family:-apple-system,sans-serif;font-size:.82rem;transition:color .2s}nav a:hover{color:#1a1714}.hero{max-width:660px;margin:0 auto;padding:8rem 2rem 4rem;text-align:center}.avatar{width:64px;height:64px;border-radius:50%;background:linear-gradient(135deg,#8b5cf6,#3b82f6);margin:0 auto 1.5rem;display:flex;align-items:center;justify-content:center;color:#fff;font-size:1.6rem}h1{font-size:clamp(1.8rem,4vw,2.8rem);color:#1a1714;margin-bottom:.8rem;line-height:1.2;letter-spacing:-.3px}.tagline{font-size:1.05rem;color:#7a7068;max-width:440px;margin:0 auto 2rem}.social{display:flex;gap:1rem;justify-content:center;flex-wrap:wrap}.social a{padding:.45rem 1.1rem;border:1px solid #e0dbd2;border-radius:5px;font-family:-apple-system,sans-serif;font-size:.82rem;color:#5a5248;text-decoration:none;transition:all .2s}.social a:hover{border-color:#8b5cf6;color:#8b5cf6}.posts{max-width:660px;margin:0 auto;padding:1rem 2rem 4rem}.section-title{font-family:-apple-system,sans-serif;font-size:.72rem;text-transform:uppercase;letter-spacing:2px;color:#b0a898;margin-bottom:1.2rem;padding-bottom:.5rem;border-bottom:1px solid #e8e3da}.post{padding:1.2rem 0;border-bottom:1px solid #f0ece4;display:flex;justify-content:space-between;align-items:flex-start;gap:1rem}.post:last-child{border-bottom:none}.post-title{font-size:1rem;color:#1a1714;text-decoration:none;transition:color .2s;line-height:1.4}.post-title:hover{color:#8b5cf6}.post-meta{font-family:-apple-system,sans-serif;font-size:.75rem;color:#b0a898;white-space:nowrap}.tags{display:flex;gap:.4rem;margin-top:.35rem;flex-wrap:wrap}.tag{font-family:-apple-system,sans-serif;font-size:.7rem;padding:.15rem .5rem;background:#f0ece4;color:#7a7068;border-radius:3px}footer{text-align:center;padding:1.5rem;border-top:1px solid #e8e3da;font-family:-apple-system,sans-serif;font-size:.75rem;color:#b0a898}@media(max-width:540px){nav ul{display:none}}</style></head><body><nav><div class="logo">Alex Chen</div><ul><li><a href="#">Writing</a></li><li><a href="#">Projects</a></li><li><a href="#">About</a></li><li><a href="#">RSS</a></li></ul></nav><section class="hero"><div class="avatar">✍️</div><h1>Software engineering, systems, and occasional philosophy</h1><p class="tagline">Building distributed systems by day. Writing about technology, craft, and the occasional rabbit hole by night.</p><div class="social"><a href="#">GitHub</a><a href="#">Twitter / X</a><a href="#">LinkedIn</a><a href="#">Newsletter</a></div></section><section class="posts"><div class="section-title">Recent Writing</div><div class="post"><div><a class="post-title" href="#">Why I stopped using ORM frameworks in production</a><div class="tags"><span class="tag">databases</span><span class="tag">backend</span></div></div><span class="post-meta">Feb 2026</span></div><div class="post"><div><a class="post-title" href="#">A practical guide to distributed tracing without vendor lock-in</a><div class="tags"><span class="tag">observability</span></div></div><span class="post-meta">Jan 2026</span></div><div class="post"><div><a class="post-title" href="#">Event sourcing in Go: lessons after two years in production</a><div class="tags"><span class="tag">go</span><span class="tag">architecture</span></div></div><span class="post-meta">Dec 2025</span></div></section><footer>Written and maintained by Alex Chen · No tracking, no cookies</footer></body></html>
HTML
}

case "$STUB_CHOICE" in
    1) create_stub_minimal ;;
    2) create_stub_cats ;;
    3) create_stub_business ;;
    4) create_stub_hosting ;;
    5) create_stub_blog ;;
esac
echo -e "${GREEN}[✓] Stub-страница создана${NC}"

# ── Caddyfile (порт 8443, только localhost) ────────────────
echo -e "${CYAN}[*] Настраиваю Caddy...${NC}"
[[ -f /etc/caddy/Caddyfile ]] && \
    cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"

cat > /etc/caddy/Caddyfile << CADDYEOF
{
    email admin@${DOMAIN}
}

# Публичный HTTP — отдаёт страницу браузеру + ACME для сертификата
${DOMAIN}:80 {
    header {
        -Server
        X-Content-Type-Options "nosniff"
    }
    root * /var/www/html
    try_files {path} /index.html
    file_server
}

# Внутренний HTTPS — для faketls-маскировки (mtprotoproxy → сюда при TLS-пробе)
${DOMAIN}:8443 {
    bind 127.0.0.1
    tls {
        protocols tls1.2 tls1.3
    }
    header {
        -Server
        X-Content-Type-Options "nosniff"
    }
    root * /var/www/html
    try_files {path} /index.html
    file_server
}

# Внутренний plain HTTP — PROXY_URL для mtprotoproxy (перенаправление DPI/сканеров)
:8080 {
    bind 127.0.0.1
    header {
        -Server
    }
    root * /var/www/html
    try_files {path} /index.html
    file_server
}
CADDYEOF

caddy fmt --overwrite /etc/caddy/Caddyfile > /dev/null 2>&1 || true
echo -e "${GREEN}[✓] Caddyfile готов${NC}"

# ── systemd: mtprotoproxy ──────────────────────────────────
echo -e "${CYAN}[*] Создаю systemd-юнит для mtprotoproxy...${NC}"
cat > /etc/systemd/system/mtprotoproxy.service << SVCEOF
[Unit]
Description=MTProto Proxy for Telegram (SelfSteal)
After=network.target caddy.service
Requires=caddy.service

[Service]
Type=simple
User=root
WorkingDirectory=${PROXY_DIR}
ExecStart=/usr/bin/python3 ${PROXY_DIR}/mtprotoproxy.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
echo -e "${GREEN}[✓] Юнит создан${NC}"

# ── Файрвол ────────────────────────────────────────────────
echo -e "${CYAN}[*] Настраиваю файрвол...${NC}"
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp   > /dev/null 2>&1 || true
    ufw allow 443/tcp  > /dev/null 2>&1 || true
    ufw delete allow 8443/tcp > /dev/null 2>&1 || true
    ufw delete allow 8080/tcp > /dev/null 2>&1 || true
    echo -e "${GREEN}[✓] UFW: 80, 443 открыты | 8443, 8080 только localhost${NC}"
fi

# ── Запуск ─────────────────────────────────────────────────
echo -e "${CYAN}[*] Запускаю Caddy (получаю сертификат)...${NC}"
systemctl enable caddy > /dev/null 2>&1
systemctl restart caddy
sleep 5

echo -e "${CYAN}[*] Запускаю mtprotoproxy...${NC}"
systemctl enable mtprotoproxy > /dev/null 2>&1
systemctl start mtprotoproxy
sleep 3

# ── Проверка ───────────────────────────────────────────────
CADDY_OK=false
PROXY_OK=false

if systemctl is-active --quiet caddy; then
    CADDY_OK=true
    echo -e "${GREEN}[✓] Caddy запущен${NC}"
else
    echo -e "${RED}[✗] Caddy не запустился — journalctl -u caddy -n 20${NC}"
fi

if systemctl is-active --quiet mtprotoproxy; then
    PROXY_OK=true
    echo -e "${GREEN}[✓] mtprotoproxy запущен${NC}"
else
    echo -e "${RED}[✗] mtprotoproxy не запустился — journalctl -u mtprotoproxy -n 20${NC}"
fi

# ── Ссылка для подключения ────────────────────────────────
TG_LINK="https://t.me/proxy?server=${DOMAIN}&port=443&secret=${FAKETLS_SECRET}"

# ── Итог ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✓  MTProto SelfSteal готов                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Домен:${NC}          ${CYAN}${DOMAIN}${NC}"
echo -e "  ${BOLD}IP сервера:${NC}     ${CYAN}${SERVER_IP}${NC}"
echo -e "  ${BOLD}Маскировка:${NC}     ${CYAN}${STUB_NAMES[$((STUB_CHOICE-1))]}${NC}"
echo ""
echo -e "  ${YELLOW}━━━  Ссылка для подключения в Telegram  ━━━${NC}"
echo ""
echo -e "  ${GREEN}${TG_LINK}${NC}"
echo ""
echo -e "  ${BOLD}Секрет (faketls):${NC}"
echo -e "  ${CYAN}${FAKETLS_SECRET}${NC}"
echo ""
echo -e "  ${YELLOW}━━━  Порты  ━━━${NC}"
echo ""
echo -e "  ${BOLD}443${NC}   → mtprotoproxy (MTProto + faketls маскировка)"
echo -e "  ${BOLD}80${NC}    → Caddy (страница в браузере + ACME-сертификат)"
echo -e "  ${BOLD}8443${NC}  → Caddy HTTPS (только 127.0.0.1 — faketls TLS-проба)"
echo -e "  ${BOLD}8080${NC}  → Caddy HTTP  (только 127.0.0.1 — PROXY_URL для DPI)"
echo ""
echo -e "  ${DIM}Логи прокси:  journalctl -u mtprotoproxy -f${NC}"
echo -e "  ${DIM}Логи Caddy:   journalctl -u caddy -f${NC}"
echo -e "  ${DIM}Страница:     nano /var/www/html/index.html && systemctl restart caddy${NC}"
echo ""
echo -e "  ${YELLOW}━━━  Как работает маскировка  ━━━${NC}"
echo ""
echo -e "  DPI/сканер подключается → видит TLS-хендшейк с сертификатом ${DOMAIN}"
echo -e "  mtprotoproxy перенаправляет на Caddy → получает реальную HTML-страницу"
echo -e "  Для блокировщика трафик неотличим от обычного HTTPS-сайта"
echo ""
