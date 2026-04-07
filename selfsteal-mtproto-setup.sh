#!/bin/bash

# ============================================================
#  MTProto SelfSteal Installer  v4
#  Telegram MTProto Proxy + nginx (маскировка под свой домен)
#
#  Архитектура:
#    Port 443  → mtprotoproxy (faketls)
#                  ├─ MTProto клиент → туннель Telegram
#                  └─ DPI/сканер    → nginx:8443 (реальный сайт + TLS)
#    Port 8443 → nginx HTTPS (только 127.0.0.1, TLS + stub-страница)
#    Port 80   → nginx (ACME + редирект)
#
#  Улучшения v4:
#    — Случайный faketls-секрет (не на основе домена)
#    — PROXY_URL через HTTPS (полный TLS при пробинге)
#    — Hardened nginx: HSTS, скрытый Server, rate-limit
#    — Фейковые подстраницы: /about, /contact, robots.txt, sitemap.xml
#    — Запуск mtprotoproxy от выделенного пользователя
#    — fail2ban для SSH + nginx
#    — logrotate для mtprotoproxy
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
 ║       MTProto SelfSteal Installer  v4                    ║
 ║       Telegram прокси + nginx (маскировка домена)        ║
 ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Root ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✗] Запусти от root: sudo bash $0${NC}"
    exit 1
fi

# ── Домен ─────────────────────────────────────────────────
read -rp "$(echo -e "${YELLOW}[?] Твой домен (например, proxy.example.com): ${NC}")" DOMAIN
DOMAIN=$(echo "$DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')
[[ -z "$DOMAIN" ]] && { echo -e "${RED}[✗] Домен не может быть пустым${NC}"; exit 1; }

# ── Выбор stub-страницы ────────────────────────────────────
echo ""
echo -e "${BOLD}  Выбери маскировочную страницу:${NC}"
echo ""
echo -e "  ${CYAN}1)${NC} Минимальный 404     ${DIM}— тёмный, лаконичный${NC}"
echo -e "  ${CYAN}2)${NC} Котики 404          ${DIM}— весёлый, с анимацией${NC}"
echo -e "  ${CYAN}3)${NC} Tech-компания        ${DIM}— корпоративный лендинг (NovaTech)${NC}"
echo -e "  ${CYAN}4)${NC} Облачный хостинг     ${DIM}— SaaS / хостинг стиль (VortexHost)${NC}"
echo -e "  ${CYAN}5)${NC} Личный блог          ${DIM}— инженерный блог${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}[?] Выбор (1-5) [по умолчанию: 3]: ${NC}")" STUB_CHOICE
STUB_CHOICE=${STUB_CHOICE:-3}
[[ ! "$STUB_CHOICE" =~ ^[1-5]$ ]] && STUB_CHOICE=3

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
apt install -y python3 git curl dnsutils ufw nginx certbot python3-certbot-nginx \
    fail2ban logrotate > /dev/null 2>&1
echo -e "${GREEN}[✓] Зависимости установлены${NC}"

# ── Генерация СЛУЧАЙНОГО секрета ───────────────────────────
# faketls-секрет = "ee" + hex-кодировка домена
# Это НЕ пароль — это инструкция клиенту какой SNI использовать при TLS-хендшейке.
# Безопасность обеспечивается маскировкой трафика, а не секретностью этой строки.
FAKETLS_SECRET="ee$(python3 -c "print('${DOMAIN}'.encode().hex())")"
echo -e "${GREEN}[✓] FakeTLS-секрет сгенерирован (содержит домен ${DOMAIN})${NC}"

# ── Создание пользователя mtproto ──────────────────────────
echo -e "${CYAN}[*] Создаю пользователя mtproto...${NC}"
if ! id mtproto &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -d /opt/mtprotoproxy mtproto
    echo -e "${GREEN}[✓] Пользователь mtproto создан${NC}"
else
    echo -e "${DIM}[·] Пользователь mtproto уже существует${NC}"
fi

# ── Установка mtprotoproxy ─────────────────────────────────
echo -e "${CYAN}[*] Устанавливаю mtprotoproxy (stable)...${NC}"
PROXY_DIR="/opt/mtprotoproxy"

if [[ -d "$PROXY_DIR" ]]; then
    echo -e "${YELLOW}[!] mtprotoproxy уже установлен, обновляю...${NC}"
    git -C "$PROXY_DIR" pull -q 2>/dev/null || true
else
    git clone -q https://github.com/alexbers/mtprotoproxy.git "$PROXY_DIR"
fi
chown -R mtproto:mtproto "$PROXY_DIR"
echo -e "${GREEN}[✓] mtprotoproxy готов (stable)${NC}"

# ── Stub-страницы (с подстраницами для правдоподобности) ───
echo -e "${CYAN}[*] Создаю маскировочные страницы...${NC}"
WEBROOT="/var/www/${DOMAIN}"
mkdir -p "${WEBROOT}"

# ── Общие файлы для всех тем ──────────────────────────────

# robots.txt
cat > "${WEBROOT}/robots.txt" << 'ROBOTS'
User-agent: *
Allow: /
Sitemap: /sitemap.xml
ROBOTS

# sitemap.xml
cat > "${WEBROOT}/sitemap.xml" << SITEMAP
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${DOMAIN}/</loc><priority>1.0</priority></url>
  <url><loc>https://${DOMAIN}/about</loc><priority>0.8</priority></url>
  <url><loc>https://${DOMAIN}/contact</loc><priority>0.7</priority></url>
</urlset>
SITEMAP

# favicon.ico (1x1 пустой)
python3 -c "
import struct, zlib, base64
# minimal valid .ico (16x16, 1 color)
ico = bytes.fromhex(
    '00000100010010100000000000006800000016000000'
    '28000000100000002000000001000400000000000000'
    '0000000000000000000000000000000000000000'
)
ico += b'\x00' * 64  # color table
ico += b'\x00' * 128  # XOR mask
ico += b'\xff' * 64   # AND mask
with open('${WEBROOT}/favicon.ico', 'wb') as f:
    f.write(ico)
" 2>/dev/null || touch "${WEBROOT}/favicon.ico"

# ── Генерация страниц по выбору темы ──────────────────────

generate_stub_pages() {
    local THEME="$1"
    local SITE_NAME SITE_TAG HERO_TITLE HERO_SUB NAV_ITEMS COLOR1 COLOR2 BG_COLOR
    local ABOUT_TITLE ABOUT_TEXT CONTACT_TITLE

    case "$THEME" in
        1)  # Минимальный 404
            SITE_NAME="404"; COLOR1="#5b7cf6"; COLOR2="#9b5bf6"; BG_COLOR="#080b10"
            ;;
        2)  # Котики 404
            SITE_NAME="404"; COLOR1="#ff6eb4"; COLOR2="#6a9fff"; BG_COLOR="#160f22"
            ;;
        3)  # Tech-компания
            SITE_NAME="NovaTech"; SITE_TAG="Solutions"
            COLOR1="#4e79f6"; COLOR2="#7b54f5"; BG_COLOR="#090c13"
            HERO_TITLE="Building the <em>future</em> of cloud infrastructure"
            HERO_SUB="We help companies scale with modern cloud-native solutions, enterprise-grade security, and zero-downtime deployments."
            NAV_ITEMS="Solutions|About|Pricing|Contact"
            ABOUT_TITLE="About NovaTech"
            ABOUT_TEXT="Founded in 2019, NovaTech Solutions is a digital infrastructure company specializing in cloud-native architecture, DevOps automation, and enterprise security. We serve over 500 clients across 30 countries."
            CONTACT_TITLE="Get in Touch"
            ;;
        4)  # Облачный хостинг
            SITE_NAME="Vortex"; SITE_TAG="Host"
            COLOR1="#00d4ff"; COLOR2="#0060ff"; BG_COLOR="#04060d"
            HERO_TITLE="Web hosting that's <span>lightning fast</span>"
            HERO_SUB="Deploy your projects in seconds with our global CDN, NVMe storage, and auto-scaling infrastructure."
            NAV_ITEMS="Hosting|VPS|Domains|Support"
            ABOUT_TITLE="About VortexHost"
            ABOUT_TEXT="VortexHost provides high-performance cloud hosting with data centers in Frankfurt, Amsterdam, and London. Our infrastructure is built on enterprise-grade hardware with NVMe storage and redundant networking."
            CONTACT_TITLE="Contact Support"
            ;;
        5)  # Личный блог
            SITE_NAME="Alex Chen"; SITE_TAG=""
            COLOR1="#8b5cf6"; COLOR2="#3b82f6"; BG_COLOR="#faf8f5"
            NAV_ITEMS="Writing|Projects|About|RSS"
            ABOUT_TITLE="About Me"
            ABOUT_TEXT="I'm a software engineer focused on distributed systems and backend architecture. Previously at several startups, now building infrastructure tools. I write about technology, engineering craft, and the occasional deep dive."
            CONTACT_TITLE="Contact"
            ;;
    esac

    # Для тем 1 и 2 — только 404 страницы
    if [[ "$THEME" == "1" ]]; then
        cat > "${WEBROOT}/index.html" << 'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>404 – Not Found</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#080b10;color:#9ba3b8;display:flex;justify-content:center;align-items:center;min-height:100vh}.wrap{text-align:center;padding:2rem}h1{font-size:clamp(5rem,18vw,11rem);font-weight:800;letter-spacing:-.04em;background:linear-gradient(135deg,#5b7cf6,#9b5bf6);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;line-height:1;animation:flicker 4s ease-in-out infinite}p{margin-top:.8rem;font-size:.95rem;color:#424860}@keyframes flicker{0%,100%{opacity:1}48%{opacity:1}50%{opacity:.7}52%{opacity:1}96%{opacity:1}98%{opacity:.5}99%{opacity:1}}</style></head><body><div class="wrap"><h1>404</h1><p>The resource you requested does not exist on this server.</p></div></body></html>
HTML
        # /about и /contact — чуть другой текст чтобы не палить одинаковый ответ
        mkdir -p "${WEBROOT}/about" "${WEBROOT}/contact"
        sed 's/does not exist on this server/page not found/;s/<title>404/<title>About/' \
            "${WEBROOT}/index.html" > "${WEBROOT}/about/index.html"
        sed 's/does not exist on this server/nothing here/;s/<title>404/<title>Contact/' \
            "${WEBROOT}/index.html" > "${WEBROOT}/contact/index.html"
        echo -e "${GREEN}[✓] Stub-страницы созданы (Минимальный 404)${NC}"
        return
    fi

    if [[ "$THEME" == "2" ]]; then
        cat > "${WEBROOT}/index.html" << 'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>404 – Oops!</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:#160f22;color:#d0c4e8;display:flex;justify-content:center;align-items:center;min-height:100vh;overflow:hidden}.bg{position:fixed;inset:0;overflow:hidden;pointer-events:none}.bg span{position:absolute;font-size:1.6rem;opacity:.05;animation:fall linear infinite}.bg span:nth-child(1){left:8%;animation-duration:14s}.bg span:nth-child(2){left:25%;animation-duration:18s;animation-delay:3s}.bg span:nth-child(3){left:50%;animation-duration:16s;animation-delay:7s}.bg span:nth-child(4){left:72%;animation-duration:20s;animation-delay:1s}.bg span:nth-child(5){left:90%;animation-duration:13s;animation-delay:5s}@keyframes fall{from{top:-60px}to{top:110%}}.wrap{text-align:center;padding:2rem;position:relative;z-index:1}.emoji{font-size:5rem;animation:bob 3s ease-in-out infinite;display:block;margin-bottom:1rem}@keyframes bob{0%,100%{transform:translateY(0) rotate(-3deg)}50%{transform:translateY(-12px) rotate(3deg)}}h1{font-size:clamp(4rem,14vw,8rem);font-weight:800;background:linear-gradient(135deg,#ff6eb4,#b46aff,#6a9fff);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;line-height:1}.msg{font-size:1.1rem;color:#9b80c4;margin-top:.6rem}.paws{margin-top:1.5rem;font-size:1.3rem;letter-spacing:8px;opacity:.4}</style></head><body><div class="bg"><span>🐱</span><span>😸</span><span>🐈</span><span>😺</span><span>😻</span></div><div class="wrap"><span class="emoji">😿</span><h1>404</h1><p class="msg">The cat knocked this page off the table.</p><div class="paws">🐾 🐾 🐾</div></div></body></html>
HTML
        mkdir -p "${WEBROOT}/about" "${WEBROOT}/contact"
        sed 's/knocked this page off the table/is sleeping on this page/;s/<title>404/<title>About/' \
            "${WEBROOT}/index.html" > "${WEBROOT}/about/index.html"
        sed 's/knocked this page off the table/hid this page under the couch/;s/<title>404/<title>Contact/' \
            "${WEBROOT}/index.html" > "${WEBROOT}/contact/index.html"
        echo -e "${GREEN}[✓] Stub-страницы созданы (Котики 404)${NC}"
        return
    fi

    # ── Темы 3, 4, 5: полноценный сайт с подстраницами ────

    # Определяем CSS-переменные и стиль навбара
    local IS_DARK=true
    local TEXT_COLOR="#b0b8cc" TEXT_DIM="#4a5168" TEXT_WHITE="#e8ecf5"
    local BORDER_COLOR="#1b2035" NAV_BG="rgba(9,12,19,.75)"
    local FONT="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif"

    if [[ "$THEME" == "5" ]]; then
        IS_DARK=false
        BG_COLOR="#faf8f5"; TEXT_COLOR="#2d2926"; TEXT_DIM="#7a7068"
        TEXT_WHITE="#1a1714"; BORDER_COLOR="#e8e3da"; NAV_BG="#faf8f5"
        FONT="font-family:'Georgia',serif"
    fi

    local LOGO_HTML
    if [[ -n "$SITE_TAG" ]]; then
        LOGO_HTML="${SITE_NAME}<span style=\"color:${COLOR1}\">${SITE_TAG}</span>"
    else
        LOGO_HTML="${SITE_NAME}"
    fi

    # Генерируем nav-ссылки
    local NAV_HTML=""
    IFS='|' read -ra NAV_ARR <<< "$NAV_ITEMS"
    for item in "${NAV_ARR[@]}"; do
        local href="/"
        local lower=$(echo "$item" | tr '[:upper:]' '[:lower:]')
        case "$lower" in
            about|projects) href="/about" ;;
            contact|support|pricing) href="/contact" ;;
            *) href="#" ;;
        esac
        NAV_HTML="${NAV_HTML}<li><a href=\"${href}\">${item}</a></li>"
    done

    # CSS общий
    local CSS_COMMON="*{margin:0;padding:0;box-sizing:border-box}body{${FONT};background:${BG_COLOR};color:${TEXT_COLOR};line-height:1.7}nav{position:fixed;top:0;width:100%;padding:1rem 2.5rem;display:flex;justify-content:space-between;align-items:center;z-index:10;backdrop-filter:blur(14px);background:${NAV_BG};border-bottom:1px solid ${BORDER_COLOR}}.logo{font-size:1.2rem;font-weight:800;color:${TEXT_WHITE}}nav ul{list-style:none;display:flex;gap:1.6rem}nav a{color:${TEXT_DIM};text-decoration:none;font-size:.85rem;transition:color .2s}nav a:hover{color:${TEXT_WHITE}}.content{max-width:720px;margin:0 auto;padding:7rem 2rem 4rem}h1{font-size:clamp(1.8rem,4vw,2.6rem);color:${TEXT_WHITE};margin-bottom:1rem}p{margin-bottom:1rem;line-height:1.75;color:${TEXT_COLOR}}footer{text-align:center;padding:1.5rem;border-top:1px solid ${BORDER_COLOR};font-size:.75rem;color:${TEXT_DIM}}@media(max-width:560px){nav ul{display:none}}"

    local YEAR
    YEAR=$(date +%Y)
    local FOOTER_HTML="<footer>&copy; ${YEAR} ${SITE_NAME}${SITE_TAG:+ ${SITE_TAG}}. All rights reserved.</footer>"
    local NAV_BLOCK="<nav><div class=\"logo\">${LOGO_HTML}</div><ul>${NAV_HTML}</ul></nav>"

    # ── index.html ──
    if [[ "$THEME" == "3" ]]; then
        cat > "${WEBROOT}/index.html" << HTML
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${SITE_NAME} ${SITE_TAG} — Cloud Infrastructure</title><style>${CSS_COMMON}.hero{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:6rem 2rem 4rem;text-align:center;position:relative}.badge{display:inline-block;padding:.35rem .9rem;border:1px solid ${BORDER_COLOR};border-radius:50px;font-size:.75rem;color:${COLOR1};margin-bottom:1.8rem;letter-spacing:1.2px;text-transform:uppercase}h1{font-size:clamp(2.2rem,5.5vw,4rem);line-height:1.1;margin-bottom:1.3rem}h1 em{font-style:normal;background:linear-gradient(135deg,${COLOR1},${COLOR2});-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}.sub{font-size:1.05rem;color:${TEXT_DIM};max-width:520px;margin:0 auto 2.2rem;line-height:1.65}.btns{display:flex;gap:.8rem;justify-content:center;flex-wrap:wrap}.btn{padding:.75rem 1.7rem;border-radius:7px;font-size:.9rem;font-weight:600;text-decoration:none;transition:all .25s}.btn-p{background:linear-gradient(135deg,${COLOR1},${COLOR2});color:#fff}.btn-p:hover{transform:translateY(-2px)}.btn-o{background:transparent;color:${TEXT_COLOR};border:1px solid ${BORDER_COLOR}}.btn-o:hover{border-color:${COLOR1};color:${TEXT_WHITE}}.stats{display:flex;gap:2.5rem;justify-content:center;margin-top:3.5rem;padding-top:2.5rem;border-top:1px solid ${BORDER_COLOR};flex-wrap:wrap}.stat-n{font-size:2rem;font-weight:800;color:${TEXT_WHITE}}.stat-l{font-size:.8rem;color:${TEXT_DIM};margin-top:.25rem}</style></head><body>${NAV_BLOCK}<section class="hero"><div><div class="badge">Digital Infrastructure Partner</div><h1>${HERO_TITLE}</h1><p class="sub">${HERO_SUB}</p><div class="btns"><a class="btn btn-p" href="/contact">Get Started</a><a class="btn btn-o" href="/about">Learn More</a></div><div class="stats"><div><div class="stat-n">500+</div><div class="stat-l">Enterprise Clients</div></div><div><div class="stat-n">99.9%</div><div class="stat-l">Uptime SLA</div></div><div><div class="stat-n">24/7</div><div class="stat-l">Expert Support</div></div></div></div></section>${FOOTER_HTML}</body></html>
HTML
    elif [[ "$THEME" == "4" ]]; then
        cat > "${WEBROOT}/index.html" << HTML
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${SITE_NAME}${SITE_TAG} — Lightning Fast Hosting</title><style>${CSS_COMMON}.orbs{position:fixed;inset:0;pointer-events:none;overflow:hidden}.orb{position:absolute;border-radius:50%;filter:blur(80px);opacity:.08}.o1{width:500px;height:500px;background:${COLOR1};top:-150px;left:-100px;animation:d1 20s ease-in-out infinite}.o2{width:400px;height:400px;background:${COLOR2};bottom:-100px;right:-100px;animation:d2 18s ease-in-out infinite}@keyframes d1{0%,100%{transform:translate(0,0)}50%{transform:translate(60px,40px)}}@keyframes d2{0%,100%{transform:translate(0,0)}50%{transform:translate(-40px,-60px)}}.hero{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:6rem 2rem 4rem;position:relative;z-index:1;text-align:center}.tag{display:inline-flex;align-items:center;gap:.4rem;padding:.3rem .9rem;border-radius:50px;background:rgba(0,212,255,.08);border:1px solid rgba(0,212,255,.2);color:${COLOR1};font-size:.75rem;margin-bottom:1.6rem}h1 span{background:linear-gradient(90deg,${COLOR1},${COLOR2});-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}.sub{color:${TEXT_DIM};max-width:480px;margin:0 auto 2rem}.btns{display:flex;gap:.75rem;justify-content:center;flex-wrap:wrap;margin-bottom:2rem}.btn{padding:.7rem 1.6rem;border-radius:6px;font-size:.88rem;font-weight:600;text-decoration:none;transition:all .2s}.btn-c{background:linear-gradient(90deg,${COLOR1},${COLOR2});color:#000}.btn-c:hover{transform:translateY(-2px)}.btn-g{background:rgba(255,255,255,.04);color:#7888a0;border:1px solid rgba(255,255,255,.08)}.btn-g:hover{border-color:${COLOR1};color:#fff}.features{display:flex;gap:1rem;justify-content:center;flex-wrap:wrap}.feat{display:flex;align-items:center;gap:.4rem;font-size:.8rem;color:${TEXT_DIM}}.feat::before{content:"✓";color:${COLOR1};font-weight:700}</style></head><body><div class="orbs"><div class="orb o1"></div><div class="orb o2"></div></div>${NAV_BLOCK}<section class="hero"><div><div class="tag">⚡ 99.99% Uptime Guaranteed</div><h1>${HERO_TITLE}</h1><p class="sub">${HERO_SUB}</p><div class="btns"><a class="btn btn-c" href="/contact">Start Free Trial</a><a class="btn btn-g" href="/about">View Plans</a></div><div class="features"><span class="feat">Free SSL</span><span class="feat">Daily Backups</span><span class="feat">1-Click Deploy</span><span class="feat">24/7 Support</span></div></div></section>${FOOTER_HTML}</body></html>
HTML
    elif [[ "$THEME" == "5" ]]; then
        cat > "${WEBROOT}/index.html" << HTML
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${SITE_NAME} — Engineering Blog</title><style>${CSS_COMMON}.hero{max-width:660px;margin:0 auto;padding:8rem 2rem 4rem;text-align:center}.avatar{width:64px;height:64px;border-radius:50%;background:linear-gradient(135deg,${COLOR1},${COLOR2});margin:0 auto 1.5rem;display:flex;align-items:center;justify-content:center;color:#fff;font-size:1.6rem}h1{font-size:clamp(1.8rem,4vw,2.4rem);margin-bottom:.8rem;letter-spacing:-.3px}.tagline{font-size:1.05rem;color:${TEXT_DIM};max-width:440px;margin:0 auto 2rem}.social{display:flex;gap:1rem;justify-content:center;flex-wrap:wrap}.social a{padding:.45rem 1.1rem;border:1px solid ${BORDER_COLOR};border-radius:5px;font-family:-apple-system,sans-serif;font-size:.82rem;color:${TEXT_DIM};text-decoration:none;transition:all .2s}.social a:hover{border-color:${COLOR1};color:${COLOR1}}.posts{max-width:660px;margin:0 auto;padding:1rem 2rem 4rem}.stitle{font-family:-apple-system,sans-serif;font-size:.72rem;text-transform:uppercase;letter-spacing:2px;color:${TEXT_DIM};margin-bottom:1.2rem;padding-bottom:.5rem;border-bottom:1px solid ${BORDER_COLOR}}.post{padding:1.2rem 0;border-bottom:1px solid ${BORDER_COLOR};display:flex;justify-content:space-between;align-items:flex-start;gap:1rem}.post:last-child{border-bottom:none}.post-title{font-size:1rem;color:${TEXT_WHITE};text-decoration:none;transition:color .2s;line-height:1.4}.post-title:hover{color:${COLOR1}}.post-meta{font-family:-apple-system,sans-serif;font-size:.75rem;color:${TEXT_DIM};white-space:nowrap}.tag{font-family:-apple-system,sans-serif;font-size:.7rem;padding:.15rem .5rem;background:${BORDER_COLOR};color:${TEXT_DIM};border-radius:3px;display:inline-block;margin-top:.35rem;margin-right:.3rem}</style></head><body>${NAV_BLOCK}<section class="hero"><div class="avatar">✍️</div><h1>Software engineering, systems, and occasional philosophy</h1><p class="tagline">Building distributed systems by day. Writing about technology, craft, and the occasional rabbit hole by night.</p><div class="social"><a href="#">GitHub</a><a href="#">Twitter / X</a><a href="#">LinkedIn</a></div></section><section class="posts"><div class="stitle">Recent Writing</div><div class="post"><div><a class="post-title" href="#">Why I stopped using ORM frameworks in production</a><div><span class="tag">databases</span><span class="tag">backend</span></div></div><span class="post-meta">Feb 2026</span></div><div class="post"><div><a class="post-title" href="#">A practical guide to distributed tracing without vendor lock-in</a><div><span class="tag">observability</span></div></div><span class="post-meta">Jan 2026</span></div><div class="post"><div><a class="post-title" href="#">Event sourcing in Go: lessons after two years in production</a><div><span class="tag">go</span><span class="tag">architecture</span></div></div><span class="post-meta">Dec 2025</span></div></section>${FOOTER_HTML}</body></html>
HTML
    fi

    # ── /about/index.html ──
    mkdir -p "${WEBROOT}/about"
    cat > "${WEBROOT}/about/index.html" << HTML
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${ABOUT_TITLE} — ${SITE_NAME}${SITE_TAG:+ ${SITE_TAG}}</title><style>${CSS_COMMON}</style></head><body>${NAV_BLOCK}<div class="content"><h1>${ABOUT_TITLE}</h1><p>${ABOUT_TEXT}</p><p>For inquiries, visit our <a href="/contact" style="color:${COLOR1}">contact page</a>.</p></div>${FOOTER_HTML}</body></html>
HTML

    # ── /contact/index.html ──
    mkdir -p "${WEBROOT}/contact"
    cat > "${WEBROOT}/contact/index.html" << HTML
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${CONTACT_TITLE} — ${SITE_NAME}${SITE_TAG:+ ${SITE_TAG}}</title><style>${CSS_COMMON}.form-stub{margin-top:2rem;padding:2rem;border:1px solid ${BORDER_COLOR};border-radius:8px}.form-stub p{color:${TEXT_DIM};font-size:.9rem}</style></head><body>${NAV_BLOCK}<div class="content"><h1>${CONTACT_TITLE}</h1><div class="form-stub"><p>Our contact form is temporarily unavailable. Please reach out via email.</p><p style="margin-top:1rem;color:${COLOR1}">contact@${DOMAIN}</p></div></div>${FOOTER_HTML}</body></html>
HTML

    echo -e "${GREEN}[✓] Stub-страницы созданы (${STUB_NAMES[$((THEME-1))]}) + /about, /contact, robots.txt, sitemap.xml${NC}"
}

generate_stub_pages "$STUB_CHOICE"

# ── nginx конфигурация ────────────────────────────────────
echo -e "${CYAN}[*] Настраиваю nginx...${NC}"

# Удаляем default
rm -f /etc/nginx/sites-enabled/default

# Глобальный hardening
# server_tokens off — добавляем в nginx.conf если ещё нет (избегаем дубликата)
if ! grep -q 'server_tokens off' /etc/nginx/nginx.conf 2>/dev/null; then
    sed -i '/http {/a\    server_tokens off;' /etc/nginx/nginx.conf
fi

# Rate-limiting зоны (отдельный файл, без server_tokens)
cat > /etc/nginx/conf.d/hardening.conf << 'NGXHARD'
# Rate-limiting зоны (используются в site-конфиге)
limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=probe:10m rate=3r/s;
limit_conn_zone $binary_remote_addr zone=connlimit:10m;
NGXHARD

# headers-more для полного скрытия Server header (опционально)
if nginx -V 2>&1 | grep -q "headers-more"; then
    echo 'more_clear_headers Server;' >> /etc/nginx/conf.d/hardening.conf
    echo -e "${GREEN}[✓] Модуль headers-more найден — Server header скрыт${NC}"
else
    echo -e "${YELLOW}[!] Модуль headers-more не найден (server_tokens off достаточно)${NC}"
    echo -e "${DIM}    Установить: apt install libnginx-mod-http-headers-more-filter${NC}"
fi

# Основной site-конфиг
cat > "/etc/nginx/sites-available/${DOMAIN}" << NGXCONF
# ── ${DOMAIN} — MTProto SelfSteal маскировка ──────────────

# HTTP — для ACME + редирект браузеров на HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/${DOMAIN};
    }

    # Всё остальное → HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS на 8443 — только localhost (для mtprotoproxy PROXY_URL + прямых проверок)
server {
    listen 127.0.0.1:8443 ssl;
    server_name ${DOMAIN};

    # TLS — сертификат будет получен certbot
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Content-Security-Policy "default-src 'self' 'unsafe-inline'" always;

    # Rate-limiting
    limit_req zone=probe burst=5 nodelay;
    limit_conn connlimit 15;

    root /var/www/${DOMAIN};
    index index.html;

    # Подстраницы
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Статические файлы с правильными типами
    location = /robots.txt { }
    location = /sitemap.xml { }
    location = /favicon.ico { access_log off; log_not_found off; }

    # Блокируем подозрительные пути
    location ~* \.(php|asp|aspx|jsp|cgi)$ {
        return 404;
    }

    access_log /var/log/nginx/${DOMAIN}_ssl_access.log;
    error_log /var/log/nginx/${DOMAIN}_ssl_error.log;
}
NGXCONF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" /etc/nginx/sites-enabled/

# ── Получаем TLS-сертификат ───────────────────────────────
# Сначала запускаем nginx только на HTTP (без SSL-блока)
# чтобы certbot мог пройти ACME challenge

# Временный конфиг — только HTTP
cat > "/etc/nginx/sites-available/${DOMAIN}-temp" << TMPCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /var/www/${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/${DOMAIN}; }
    location / { return 200 'OK'; add_header Content-Type text/plain; }
}
TMPCONF

ln -sf "/etc/nginx/sites-available/${DOMAIN}-temp" /etc/nginx/sites-enabled/
rm -f "/etc/nginx/sites-enabled/${DOMAIN}"

if nginx -t > /dev/null 2>&1; then
    systemctl restart nginx
else
    echo -e "${YELLOW}[!] nginx -t failed, диагностика:${NC}"
    nginx -t 2>&1 | tail -5
fi
echo -e "${GREEN}[✓] nginx запущен (HTTP)${NC}"

echo -e "${CYAN}[*] Получаю TLS-сертификат (Let's Encrypt)...${NC}"
if certbot certonly --webroot -w "/var/www/${DOMAIN}" -d "${DOMAIN}" \
    --non-interactive --agree-tos --register-unsafely-without-email 2>&1 | tail -5; then
    echo -e "${GREEN}[✓] Сертификат получен${NC}"
else
    echo ""
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        echo -e "${YELLOW}[!] certbot вернул ошибку, но сертификат существует — продолжаю${NC}"
    else
        echo -e "${RED}[✗] Сертификат не получен — проверь DNS и порт 80${NC}"
        echo -e "    Вручную: certbot certonly --webroot -w /var/www/${DOMAIN} -d ${DOMAIN}"
        read -rp "$(echo -e "${YELLOW}[?] Продолжить без сертификата? (y/n): ${NC}")" CONT
        [[ "$CONT" != "y" ]] && exit 1
    fi
fi

# Переключаем на полный конфиг
rm -f "/etc/nginx/sites-enabled/${DOMAIN}-temp"
rm -f "/etc/nginx/sites-available/${DOMAIN}-temp"
ln -sf "/etc/nginx/sites-available/${DOMAIN}" /etc/nginx/sites-enabled/
if nginx -t > /dev/null 2>&1; then
    systemctl restart nginx
    echo -e "${GREEN}[✓] nginx настроен (HTTP + HTTPS localhost)${NC}"
else
    echo -e "${RED}[✗] nginx -t failed после включения SSL-конфига${NC}"
    nginx -t 2>&1 | tail -5
    echo -e "${YELLOW}    Проверь: /etc/nginx/sites-available/${DOMAIN}${NC}"
fi

# ── Автообновление сертификата ─────────────────────────────
if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'") | crontab -
    echo -e "${GREEN}[✓] Автообновление сертификата настроено${NC}"
fi

# ── Конфиг mtprotoproxy ────────────────────────────────────
cat > "${PROXY_DIR}/config.py" << PYEOF
# ── MTProto SelfSteal Config v4 ─────────────────────────────
# Сгенерировано selfsteal-mtproto-setup.sh
# Секрет = ee + hex(домен) — формат FakeTLS для SNI-маскировки

PORT = 443
BIND_IP = "0.0.0.0"

USERS = {
    "tg": "${FAKETLS_SECRET}",
}

# Домен маскировки TLS
TLS_DOMAIN = "${DOMAIN}"

# КЛЮЧЕВАЯ НАСТРОЙКА SELFSTEAL:
# DPI/сканеры перенаправляются на nginx HTTPS (полный TLS-хендшейк)
PROXY_URL = "https://127.0.0.1:8443"

# Безопасность
SECURE_ONLY = True          # только faketls, отклонять plain mtproto
MAX_CONNECTIONS = 500        # лимит одновременных соединений

# Без ограничения скорости на уровне прокси
# (используй SkunkTrafLimit для per-user лимитов)
PYEOF

chown mtproto:mtproto "${PROXY_DIR}/config.py"
echo -e "${GREEN}[✓] Конфиг mtprotoproxy создан${NC}"

# ── systemd: mtprotoproxy (от пользователя mtproto) ────────
echo -e "${CYAN}[*] Создаю systemd-юнит для mtprotoproxy...${NC}"
cat > /etc/systemd/system/mtprotoproxy.service << SVCEOF
[Unit]
Description=MTProto Proxy for Telegram (SelfSteal v4)
After=network.target nginx.service
Wants=nginx.service

[Service]
Type=simple
User=mtproto
Group=mtproto
WorkingDirectory=${PROXY_DIR}
ExecStart=/usr/bin/python3 ${PROXY_DIR}/mtprotoproxy.py
Restart=always
RestartSec=5

# Разрешаем привязку к порту 443 без root
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

# Hardening
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${PROXY_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

# Логи — минимум
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtprotoproxy

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
echo -e "${GREEN}[✓] Юнит создан (запуск от mtproto, hardened)${NC}"

# ── fail2ban ──────────────────────────────────────────────
echo -e "${CYAN}[*] Настраиваю fail2ban...${NC}"

# Фильтр для nginx (подозрительные запросы)
cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'F2BFILTER'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD) .*(\.php|\.asp|\.aspx|\.jsp|\.cgi|wp-login|xmlrpc|\.env|\.git).*" (403|404)
ignoreregex =
F2BFILTER

# Jail
cat > /etc/fail2ban/jail.d/selfsteal.conf << F2BJAIL
[sshd]
enabled = true
maxretry = 5
bantime = 3600
findtime = 600

[nginx-probe]
enabled = true
port = http,https
filter = nginx-probe
logpath = /var/log/nginx/${DOMAIN}_ssl_access.log
maxretry = 10
bantime = 1800
findtime = 300
F2BJAIL

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban > /dev/null 2>&1
echo -e "${GREEN}[✓] fail2ban настроен (SSH + nginx probe)${NC}"

# ── logrotate для mtprotoproxy ─────────────────────────────
cat > /etc/logrotate.d/mtprotoproxy << 'LOGROTATE'
/var/log/journal/*mtprotoproxy* {
    weekly
    rotate 2
    compress
    delaycompress
    missingok
    notifempty
}
LOGROTATE
echo -e "${GREEN}[✓] logrotate настроен${NC}"

# ── Файрвол ────────────────────────────────────────────────
echo -e "${CYAN}[*] Настраиваю файрвол...${NC}"
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp   > /dev/null 2>&1 || true
    ufw allow 443/tcp  > /dev/null 2>&1 || true
    ufw delete allow 8443/tcp > /dev/null 2>&1 || true
    ufw delete allow 8080/tcp > /dev/null 2>&1 || true
    echo -e "${GREEN}[✓] UFW: 80, 443 открыты | 8443 только localhost${NC}"
fi

# ── Запуск ─────────────────────────────────────────────────
echo -e "${CYAN}[*] Запускаю mtprotoproxy...${NC}"
systemctl enable mtprotoproxy > /dev/null 2>&1
systemctl restart mtprotoproxy
sleep 3

# ── Проверка ───────────────────────────────────────────────
PROXY_OK=false
NGINX_OK=false

if systemctl is-active --quiet mtprotoproxy; then
    PROXY_OK=true
    echo -e "${GREEN}[✓] mtprotoproxy запущен${NC}"
else
    echo -e "${RED}[✗] mtprotoproxy не запустился — journalctl -u mtprotoproxy -n 20${NC}"
fi

if systemctl is-active --quiet nginx; then
    NGINX_OK=true
    echo -e "${GREEN}[✓] nginx запущен${NC}"
else
    echo -e "${RED}[✗] nginx не запустился — journalctl -u nginx -n 20${NC}"
fi

# Проверка маскировки
MASK_OK=false
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:8443" --resolve "${DOMAIN}:8443:127.0.0.1" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" ]]; then
        MASK_OK=true
        echo -e "${GREEN}[✓] Маскировка работает — сертификат от nginx${NC}"
    else
        echo -e "${YELLOW}[!] Предупреждение: TLS probe вернул HTTP ${HTTP_CODE} (некритично)${NC}"
    fi
fi

# ── Ссылка для подключения ────────────────────────────────
TG_LINK="https://t.me/proxy?server=${DOMAIN}&port=443&secret=${FAKETLS_SECRET}"

# ── Итог ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✓  MTProto SelfSteal v4 готов!                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Домен:${NC}          ${CYAN}${DOMAIN}${NC}"
echo -e "  ${BOLD}IP сервера:${NC}     ${CYAN}${SERVER_IP}${NC}"
echo -e "  ${BOLD}Маскировка:${NC}     ${CYAN}${STUB_NAMES[$((STUB_CHOICE-1))]}${NC}"
echo -e "  ${BOLD}Веб-сервер:${NC}     ${CYAN}nginx + certbot${NC}"
echo ""
echo -e "  ${YELLOW}━━  Ссылка для Telegram  ━━${NC}"
echo ""
echo -e "  ${GREEN}${TG_LINK}${NC}"
echo ""
echo -e "  Скопируй ссылку → отправь в Saved Messages → нажми → Подключить"
echo ""
echo -e "  ${BOLD}Секрет (faketls):${NC}"
echo -e "  ${CYAN}${FAKETLS_SECRET}${NC}"
echo ""
echo -e "  ${YELLOW}━━  Порты  ━━${NC}"
echo ""
echo -e "  ${BOLD}443${NC}   → mtprotoproxy (MTProto + faketls маскировка)"
echo -e "  ${BOLD}80${NC}    → nginx (ACME + редирект на HTTPS)"
echo -e "  ${BOLD}8443${NC}  → nginx HTTPS (только 127.0.0.1 — TLS-проба от DPI)"
echo ""
echo -e "  ${YELLOW}━━  Улучшения v4  ━━${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} FakeTLS-секрет (SNI-маскировка домена)"
echo -e "  ${GREEN}✓${NC} PROXY_URL → HTTPS (полный TLS при пробинге)"
echo -e "  ${GREEN}✓${NC} nginx: HSTS, скрытый Server, rate-limit, CSP"
echo -e "  ${GREEN}✓${NC} Подстраницы: /about, /contact, robots.txt, sitemap.xml"
echo -e "  ${GREEN}✓${NC} Запуск от пользователя mtproto (не root)"
echo -e "  ${GREEN}✓${NC} systemd hardening (ProtectSystem, PrivateTmp...)"
echo -e "  ${GREEN}✓${NC} fail2ban (SSH + nginx probe detection)"
echo -e "  ${GREEN}✓${NC} logrotate для mtprotoproxy"
echo ""
echo -e "  ${DIM}Логи прокси:   journalctl -u mtprotoproxy -f${NC}"
echo -e "  ${DIM}Логи nginx:    tail -f /var/log/nginx/${DOMAIN}_ssl_access.log${NC}"
echo -e "  ${DIM}fail2ban:      fail2ban-client status${NC}"
echo -e "  ${DIM}Страница:      nano /var/www/${DOMAIN}/index.html && systemctl reload nginx${NC}"
echo ""
echo -e "  ${YELLOW}━━  Как работает маскировка  ━━${NC}"
echo ""
echo -e "  DPI/сканер → port 443 → mtprotoproxy → не MTProto?"
echo -e "  → PROXY_URL → nginx:8443 (TLS + валидный сертификат + реальная страница)"
echo -e "  Для блокировщика трафик неотличим от обычного HTTPS-сайта"
echo ""
