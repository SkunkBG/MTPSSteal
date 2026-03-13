# 🛡️ MTProto SelfSteal Proxy

Telegram MTProto прокси с маскировкой трафика под собственный домен. DPI и активные зонды видят легитимный TLS-сертификат и реальную HTML-страницу — трафик неотличим от обычного HTTPS-сайта.

## Как работает

```
Клиент Telegram → :443 → mtprotoproxy → MTProto хендшейк ОК → туннель в Telegram
DPI / сканер    → :443 → mtprotoproxy → хендшейк не MTProto → Caddy:8443 (реальный сайт + TLS)
Браузер         → :80  → Caddy → HTML-страница + ACME-сертификат
```

**Почему это надёжно:**
- FakeTLS-секрет содержит домен → клиент ставит правильный SNI в TLS ClientHello
- mtprotoproxy на порту 443 принимает только MTProto-клиентов
- Все остальные (DPI, сканеры, браузеры) перенаправляются на Caddy
- Caddy отдаёт реальную HTML-страницу с валидным Let's Encrypt сертификатом
- Для блокировщика трафик выглядит как обычный HTTPS-сайт

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

После установки выведет готовую ссылку `tg://proxy?...` — просто отправь её в Telegram и нажми «Подключить».

## Что делает скрипт

1. Проверяет DNS — домен должен вести на сервер
2. Устанавливает зависимости (`python3`, `git`, `curl`, `ufw`)
3. Клонирует [mtprotoproxy](https://github.com/alexbers/mtprotoproxy) (ветка `stable`) в `/opt/mtprotoproxy`
4. Генерирует FakeTLS-секрет: `ee` + 16 случайных байт + домен в hex
5. Настраивает `config.py` с `MASK = True` → Caddy на `127.0.0.1:8443`
6. Устанавливает [Caddy](https://caddyserver.com/) и получает TLS-сертификат (Let's Encrypt)
7. Создаёт маскировочную страницу в `/var/www/html/`
8. Настраивает `systemd`-юниты для автозапуска
9. Открывает порты 80 и 443 через UFW
10. Выводит готовую ссылку для подключения

## Порты

| Порт | Сервис | Доступ | Назначение |
|------|--------|--------|------------|
| `443` | mtprotoproxy | Публичный | MTProto + FakeTLS маскировка |
| `80` | Caddy | Публичный | HTML-страница + ACME-сертификат |
| `8443` | Caddy HTTPS | **Только localhost** | TLS-ответ для DPI/сканеров |

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
systemctl restart caddy
```

## Подключение в Telegram

### По ссылке (самый простой способ):
1. Скопируй ссылку `tg://proxy?server=...` из вывода скрипта
2. Отправь её себе в «Избранное» (Saved Messages) в Telegram
3. Нажми на неё → Telegram предложит подключить прокси → **Подключить**
4. Появится значок щита — прокси работает!

### Вручную:
1. **Настройки** → **Данные и память** → **Тип соединения** → **Использовать прокси**
2. Нажми **Добавить прокси** → тип **MTProto**
3. Заполни: Сервер, Порт (443), Секрет (начинается с `ee`)
4. Включи тумблер

## Файлы после установки

| Файл | Путь |
|------|------|
| Конфиг прокси | `/opt/mtprotoproxy/config.py` |
| Маскировочная страница | `/var/www/html/index.html` |
| Caddy конфиг | `/etc/caddy/Caddyfile` |
| Systemd юнит | `/etc/systemd/system/mtprotoproxy.service` |

## Управление

```bash
# Статус
systemctl status mtprotoproxy
systemctl status caddy

# Перезапуск
systemctl restart mtprotoproxy
systemctl restart caddy

# Логи в реальном времени
journalctl -u mtprotoproxy -f
journalctl -u caddy -f
```

## Диагностика

**Прокси не подключается:**
```bash
# Проверь что оба сервиса работают
systemctl status mtprotoproxy caddy

# Проверь что порт 443 слушается
ss -tlnp | grep 443

# Логи прокси
journalctl -u mtprotoproxy --no-pager -n 30
```

**Caddy не запускается:**
```bash
journalctl -u caddy --no-pager -n 30
```
Убедись что порт 80 открыт и A-запись DNS ведёт на сервер.

**Проверить маскировочную страницу:**
```bash
curl -sk https://localhost:8443 | head -5
```

**Обновить секрет:**
```bash
# Сгенерировать новый
NEW_KEY=$(python3 -c "import os; print(os.urandom(16).hex())")
DOMAIN_HEX=$(python3 -c "print('example.com'.encode().hex())")  # замени на свой домен
echo "Новый секрет: ee${NEW_KEY}${DOMAIN_HEX}"

# Вставить в конфиг
nano /opt/mtprotoproxy/config.py

# Перезапустить
systemctl restart mtprotoproxy
```

## Удаление

```bash
systemctl stop mtprotoproxy caddy
systemctl disable mtprotoproxy caddy
rm -rf /opt/mtprotoproxy
rm -f /etc/systemd/system/mtprotoproxy.service
apt remove caddy -y
rm -f /etc/apt/sources.list.d/caddy-stable.list
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
rm -rf /var/www/html
systemctl daemon-reload
```

## Благодарности

- [alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy) — async MTProto proxy на Python
- [Caddy](https://caddyserver.com/) — автоматический HTTPS-сервер

## Лицензия

MIT
