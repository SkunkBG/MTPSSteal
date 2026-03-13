# MTProto SelfSteal Proxy

Telegram MTProto прокси с маскировкой трафика под собственный домен.

## Как работает

```
Клиент → :443 (mtprotoproxy, faketls)
              ├─ Telegram-клиент  ──► туннель в Telegram
              └─ DPI / сканер     ──► Caddy:8443 (127.0.0.1)
                                          └─ реальный сайт + валидный TLS
```

DPI и активные зонды видят легитимный TLS-сертификат на **твоём** домене и реальную HTML-страницу. Трафик неотличим от обычного HTTPS-сайта.

## Требования

- Сервер с Debian или Ubuntu (20.04+)
- Root-доступ
- Домен с A-записью, указывающей на IP сервера
- Открытые порты: `80`, `443`

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
2. **Стиль страницы-маскировки** — на выбор 5 вариантов

## Что делает скрипт

1. Проверяет DNS — домен должен вести на сервер
2. Устанавливает зависимости (`python3`, `git`, `curl`, `ufw`)
3. Клонирует [mtprotoproxy](https://github.com/alexbers/mtprotoproxy) в `/opt/mtprotoproxy`
4. Генерирует faketls-секрет на основе твоего домена
5. Устанавливает [Caddy](https://caddyserver.com/) и получает TLS-сертификат (Let's Encrypt)
6. Создаёт stub-страницу на выбор в `/var/www/html/`
7. Настраивает `systemd`-юниты для автозапуска
8. Открывает порты 80 и 443 через UFW
9. Выводит готовую ссылку для подключения

## Ссылка для подключения

После установки скрипт выведет ссылку вида:

```
https://t.me/proxy?server=example.com&port=443&secret=ee...
```

Нажми «Подключиться» в Telegram — готово.

## Порты

| Порт | Сервис | Доступ |
|------|--------|--------|
| `443` | mtprotoproxy | Публичный — VPN-соединения |
| `80` | Caddy | Публичный — ACME + редирект |
| `8443` | Caddy HTTPS | **Только localhost** — маскировочная страница |

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

## Файлы после установки

| Файл | Путь |
|------|------|
| Конфиг прокси | `/opt/mtprotoproxy/config.py` |
| Маскировочная страница | `/var/www/html/index.html` |
| Caddy конфиг | `/etc/caddy/Caddyfile` |

## Управление сервисами

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

## Обновление секрета

```bash
# Сгенерировать новый faketls-секрет
python3 -c "import binascii; print('ee' + binascii.hexlify(b'example.com').decode())"

# Вставить в конфиг
nano /opt/mtprotoproxy/config.py

# Перезапустить прокси
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

## Диагностика

**Caddy не запускается:**
```bash
journalctl -u caddy --no-pager -n 30
```

**Сертификат не выдаётся:**
- Убедись, что порт 80 открыт и A-запись DNS ведёт на сервер
- Проверь: `curl -I http://example.com`

**Проверить маскировочную страницу:**
```bash
curl -sk https://example.com:8443 | head -5
```

**Проверить порт прокси:**
```bash
ss -tlnp | grep 443
```

## Лицензия

MIT
