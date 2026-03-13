# 🛡️ MTProto SelfSteal Proxy

Telegram MTProto прокси с маскировкой трафика под собственный домен. DPI и активные зонды видят легитимный TLS 1.3 сертификат и реальную HTML-страницу — трафик неотличим от обычного HTTPS-сайта.

## Как работает

```
Клиент Telegram → :443 → mtprotoproxy → MTProto хендшейк ОК → туннель в Telegram
DPI / сканер    → :443 → mtprotoproxy → хендшейк не MTProto → nginx:8443 (TLS 1.3 + HTML)
Браузер         → :80  → nginx → HTML-страница
```

**Почему это надёжно:**
- nginx отдаёт чистый TLS 1.3 хендшейк без лишних записей — идеально для маскировки
- FakeTLS-секрет содержит домен → клиент ставит правильный SNI в TLS ClientHello
- mtprotoproxy на порту 443 принимает только MTProto-клиентов
- Все остальные (DPI, сканеры) перенаправляются на nginx с валидным Let's Encrypt сертификатом
- Сертификат обновляется автоматически через certbot

## Требования

- Сервер с Debian или Ubuntu (20.04+)
- Root-доступ
- Домен с A-записью, указывающей на IP сервера
- Открытые порты: `80`, `443`

> ⚠️ Cloudflare прокси (оранжевое облако) должно быть **выключено** — только DNS-only (серое облако). Иначе TLS-хендшейк и выдача сертификата сломаются.

## Установка

**Один шаг:**

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/MTPSSteal/main/selfsteal-mtproto-setup.sh)
```

**Или вручную:**

```bash
curl -Lo setup.sh https://raw.githubusercontent.com/SkunkBG/MTPSSteal/main/selfsteal-mtproto-setup.sh
bash setup.sh
```

Скрипт спросит:

1. **Домен** — должен резолвиться на IP сервера
2. **Стиль маскировочной страницы** — на выбор 5 вариантов

После установки выведет готовую ссылку `tg://proxy?...` — отправь в Telegram и нажми «Подключить».

## Что делает скрипт

1. Проверяет DNS — домен должен вести на сервер
2. Устанавливает зависимости (`python3`, `nginx`, `certbot`, `git`)
3. Клонирует [mtprotoproxy](https://github.com/alexbers/mtprotoproxy) (ветка `stable`)
4. Генерирует FakeTLS-секрет: 32-hex ключ для `config.py` + полная ссылка для клиента
5. Настраивает nginx (HTTP + HTTPS localhost с TLS 1.3)
6. Получает TLS-сертификат через certbot (Let's Encrypt)
7. Настраивает автообновление сертификата
8. Создаёт маскировочную страницу
9. Запускает всё через systemd

## Порты

| Порт | Сервис | Доступ | Назначение |
|------|--------|--------|------------|
| `443` | mtprotoproxy | Публичный | MTProto + FakeTLS маскировка |
| `80` | nginx | Публичный | HTML-страница + ACME challenge |
| `8443` | nginx HTTPS | **Только localhost** | TLS 1.3 ответ для DPI/сканеров |

## Маскировочные страницы

| № | Название | Описание |
|---|----------|----------|
| 1 | Минимальный 404 | Тёмный лаконичный 404 |
| 2 | Котики 404 | Весёлая страница с анимацией |
| 3 | Tech-компания | Корпоративный лендинг (NovaTech) |
| 4 | Облачный хостинг | SaaS / хостинг стиль (VortexHost) |
| 5 | Личный блог | Инженерный блог |

Заменить страницу после установки:

```bash
nano /var/www/html/index.html
systemctl reload nginx
```

## Подключение в Telegram

### По ссылке (самый простой способ):
1. Скопируй ссылку `tg://proxy?server=...` из вывода скрипта
2. Отправь её себе в «Избранное» (Saved Messages) в Telegram
3. Нажми на неё → Telegram предложит подключить прокси → **Подключить**

### Вручную:
1. **Настройки** → **Данные и память** → **Тип соединения** → **Использовать прокси**
2. Нажми **Добавить прокси** → тип **MTProto**
3. Заполни: Сервер, Порт (443), Секрет (начинается с `ee`)

## Файлы после установки

| Файл | Путь |
|------|------|
| Конфиг прокси | `/opt/mtprotoproxy/config.py` |
| Маскировочная страница | `/var/www/html/index.html` |
| nginx конфиг | `/etc/nginx/sites-available/selfsteal` |
| TLS сертификат | `/etc/letsencrypt/live/<домен>/` |
| Systemd юнит | `/etc/systemd/system/mtprotoproxy.service` |

## Управление

```bash
# Статус
systemctl status mtprotoproxy
systemctl status nginx

# Перезапуск
systemctl restart mtprotoproxy
systemctl reload nginx

# Логи
journalctl -u mtprotoproxy -f
tail -f /var/log/nginx/error.log

# Сертификат
certbot certificates
certbot renew --dry-run
```

## Диагностика

**Прокси не подключается:**
```bash
systemctl status mtprotoproxy nginx
ss -tlnp | grep -E '443|80|8443'
journalctl -u mtprotoproxy --no-pager -n 30
```

**Проверить маскировочную страницу:**
```bash
curl -sk https://127.0.0.1:8443 | head -5
```

**Проверить TLS версию:**
```bash
echo | openssl s_client -connect 127.0.0.1:8443 -tls1_3 2>/dev/null | grep "Protocol"
```

**Обновить секрет:**
```bash
NEW_KEY=$(python3 -c "import os; print(os.urandom(16).hex())")
DOMAIN="example.com"  # замени на свой
DOMAIN_HEX=$(python3 -c "print('${DOMAIN}'.encode().hex())")

echo "Ключ для config.py USERS: ${NEW_KEY}"
echo "Ссылка: ee${NEW_KEY}${DOMAIN_HEX}"

nano /opt/mtprotoproxy/config.py
systemctl restart mtprotoproxy
```

> **Важно:** в `USERS` хранится только 32-hex ключ. Полный секрет `ee` + ключ + домен — только в ссылке для клиента.

## Удаление

```bash
systemctl stop mtprotoproxy nginx
systemctl disable mtprotoproxy nginx
rm -rf /opt/mtprotoproxy
rm -f /etc/systemd/system/mtprotoproxy.service
rm -f /etc/nginx/sites-enabled/selfsteal
rm -f /etc/nginx/sites-available/selfsteal
certbot delete --cert-name example.com  # замени на свой домен
rm -rf /var/www/html
systemctl daemon-reload
```

## Благодарности

- [alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy) — async MTProto proxy на Python
- [nginx](https://nginx.org/) — высокопроизводительный веб-сервер
- [certbot](https://certbot.eff.org/) — автоматические TLS-сертификаты

## Лицензия

MIT
