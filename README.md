# MTProto SelfSteal Proxy v4

Telegram MTProto прокси с маскировкой трафика под собственный домен.

## Как работает

```
Клиент → :443 (mtprotoproxy, faketls)
              ├─ Telegram-клиент  ──► туннель в Telegram
              └─ DPI / сканер     ──► nginx:8443 (127.0.0.1)
                                          └─ реальный сайт + валидный TLS
```

DPI и активные зонды видят легитимный TLS-сертификат на **твоём** домене и реальную HTML-страницу с подстраницами. Трафик неотличим от обычного HTTPS-сайта.

## Что нового в v4

- **FakeTLS-секрет** — формат `ee` + hex(домен) для корректной SNI-маскировки
- **PROXY_URL через HTTPS** — DPI при пробинге получает полный TLS-хендшейк с валидным сертификатом
- **Hardened nginx** — HSTS, скрытый Server header, rate-limiting, CSP
- **Подстраницы** — `/about`, `/contact`, `robots.txt`, `sitemap.xml`, `favicon.ico` — сайт выглядит живым
- **Запуск не от root** — mtprotoproxy работает от пользователя `mtproto` с `CAP_NET_BIND_SERVICE`
- **systemd hardening** — `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`
- **fail2ban** — защита SSH + детекция probe-сканеров по логам nginx
- **logrotate** — автоочистка логов

## Требования

- Сервер с Debian или Ubuntu (20.04+)
- Root-доступ
- Домен с A-записью, указывающей на IP сервера
- Открытые порты: `80`, `443`

## Установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/MTPSSteal/main/selfsteal-mtproto-setup.sh)
```

Скрипт спросит:

1. **Домен** — должен резолвиться на IP сервера
2. **Стиль страницы-маскировки** — 5 вариантов на выбор

## Порты

| Порт | Сервис | Доступ |
|------|--------|--------|
| `443` | mtprotoproxy | Публичный — VPN-соединения |
| `80` | nginx | Публичный — ACME + редирект |
| `8443` | nginx HTTPS | **Только localhost** — TLS-проба для DPI |

## Маскировочные страницы

| № | Название | Описание |
|---|----------|----------|
| 1 | Минимальный 404 | Тёмный лаконичный 404 |
| 2 | Котики 404 | Весёлая страница с анимацией |
| 3 | Tech-компания | Корпоративный лендинг (NovaTech) |
| 4 | Облачный хостинг | SaaS / хостинг стиль (VortexHost) |
| 5 | Личный блог | Инженерный блог |

Все темы включают подстраницы `/about`, `/contact`, а также `robots.txt`, `sitemap.xml` и `favicon.ico`.

## Файлы после установки

| Файл | Путь |
|------|------|
| Конфиг прокси | `/opt/mtprotoproxy/config.py` |
| Маскировочные страницы | `/var/www/<домен>/` |
| nginx конфиг | `/etc/nginx/sites-available/<домен>` |
| nginx hardening | `/etc/nginx/conf.d/hardening.conf` |
| fail2ban jail | `/etc/fail2ban/jail.d/selfsteal.conf` |
| systemd юнит | `/etc/systemd/system/mtprotoproxy.service` |

## Управление

```bash
# Статус
systemctl status mtprotoproxy
systemctl status nginx

# Перезапуск
systemctl restart mtprotoproxy
systemctl restart nginx

# Логи
journalctl -u mtprotoproxy -f
tail -f /var/log/nginx/<домен>_ssl_access.log

# fail2ban
fail2ban-client status
fail2ban-client status nginx-probe
```

## Обновление секрета

```bash
# Сгенерировать faketls-секрет для нового домена
NEW_SECRET="ee$(echo -n 'newdomain.com' | xxd -p | tr -d '\n')"
echo "$NEW_SECRET"

# Вставить в конфиг
nano /opt/mtprotoproxy/config.py

# Перезапустить
systemctl restart mtprotoproxy
```

## Удаление

```bash
systemctl stop mtprotoproxy nginx
systemctl disable mtprotoproxy nginx
rm -rf /opt/mtprotoproxy
rm -f /etc/systemd/system/mtprotoproxy.service
rm -f /etc/nginx/sites-enabled/<домен>
rm -f /etc/nginx/sites-available/<домен>
rm -f /etc/nginx/conf.d/hardening.conf
rm -f /etc/fail2ban/jail.d/selfsteal.conf
rm -f /etc/fail2ban/filter.d/nginx-probe.conf
rm -rf /var/www/<домен>
userdel mtproto 2>/dev/null
certbot delete --cert-name <домен>
systemctl daemon-reload
```

## Безопасность

- mtprotoproxy запущен от выделенного пользователя `mtproto`, не root
- systemd юнит использует `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`
- nginx скрывает `Server` header, включает HSTS и rate-limiting
- fail2ban банит SSH брутфорс и probe-сканеры
- faketls-секрет в формате `ee` + hex(домен) — стандарт FakeTLS для SNI-маскировки
- `SECURE_ONLY = True` — отклоняет plain MTProto без faketls

## Лицензия

MIT
