# MTPSSteal v5 — mtproto.zig + DPI Evasion

Высокопроизводительный Telegram MTProto прокси с полной защитой от DPI.

## Что внутри

| Технология | Описание |
|------------|----------|
| **mtproto.zig** | 126 КБ бинарник, ~120 КБ RAM, 0 зависимостей, Zig |
| **FakeTLS 1.3** | Трафик неотличим от обычного HTTPS |
| **TCPMSS=88** | ClientHello фрагментируется на 6 TCP-пакетов — ломает DPI |
| **Split-TLS** | 1-байтный чанкинг TLS-записей |
| **DRS** | Dynamic Record Sizing — имитация Chrome/Firefox |
| **Anti-replay** | Отклоняет повторные хендшейки (±2 мин), блокирует ТСПУ Ревизор |
| **Маскировка** | DPI-пробы перенаправляются на реальный сайт (wb.ru, ozon.ru...) |
| **zapret/nfqws** | TCP desync: fake packets + TTL spoofing (опционально) |

## Установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/MTPSSteal/main/selfsteal-mtproto-setup.sh)
```

Скрипт спросит:
1. **Домен** — должен вести на сервер
2. **Домен маскировки** — реальный сайт для перенаправления DPI (wb.ru, ozon.ru...)
3. **zapret/nfqws** — установить TCP desync

## Управление

```bash
# Логи
journalctl -u mtproto-proxy -f

# Перезапуск
systemctl restart mtproto-proxy

# Конфиг
nano /opt/mtproto-proxy/config.toml

# Подбор стратегии nfqws под провайдера
cd /opt/zapret && ./blockcheck.sh
```

## Конфиг

```toml
[server]
port = 443

[censorship]
tls_domain = "wb.ru"    # куда перенаправлять DPI-пробы
mask = true              # включить маскировку
fast_mode = true         # zero-copy S2C (меньше CPU/RAM)

[access.users]
tg = "00112233445566778899aabbccddeeff"   # 16 байт hex
```

## Добавление пользователей

```toml
[access.users]
alice = "00112233445566778899aabbccddeeff"
bob   = "ffeeddccbbaa99887766554433221100"
```

Сгенерировать секрет: `openssl rand -hex 16`

## Удаление

```bash
systemctl stop mtproto-proxy nfqws-mtproto
systemctl disable mtproto-proxy nfqws-mtproto
rm -rf /opt/mtproto-proxy
rm -f /etc/systemd/system/mtproto-proxy.service
rm -f /etc/systemd/system/nfqws-mtproto.service
rm -rf /opt/zapret
userdel mtproto 2>/dev/null
systemctl daemon-reload
```

## Лицензия

MIT
