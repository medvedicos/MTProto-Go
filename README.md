# MTProto-Go — Telemt Installer

Интерактивный установщик для [Telemt](https://github.com/telemt/telemt) — высокопроизводительного MTProto-прокси для Telegram, написанного на Rust.

---

## Установка — одна команда

Вставьте в консоль VPS (под root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/medvedicos/MTProto-Go/main/install_telemt.sh)
```

Если вы не root:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/medvedicos/MTProto-Go/main/install_telemt.sh)
```

> **Почему `bash <(...)` а не `curl | bash`?**
> Установщик интерактивный — задаёт вопросы. При `curl | bash` stdin занят пайпом и `read` не работает. Process substitution `<(...)` сохраняет stdin как терминал.

---

## Что настраивается (пошаговый wizard)

| # | Шаг | Описание |
|---|-----|----------|
| 1 | Метод установки | Бинарник / Docker / Удаление / Purge |
| 2 | Версия | Последняя или конкретный тег релиза |
| 3 | Сервер и сеть | Порт, IPv4/IPv6, макс. соединений, PROXY protocol |
| 4 | Режимы прокси | TLS / Secure / Classic (любая комбинация) |
| 5 | Анти-цензура | TLS-домен, masking, TLS emulation, unknown SNI action |
| 6 | Middle-End (ME) | ME-транспорт, fast mode, размер пула соединений |
| 7 | Пользователи | Неограниченное количество, автогенерация или ручной секрет |
| 8 | Ссылки | Public host/port, фильтр видимости ссылок |
| 9 | Ad tag | Тег спонсорского канала (@MTProxybot) |
| 10 | API и метрики | Admin REST API, Prometheus, whitelist, авторизация |
| 11 | Логирование | Уровень, ANSI-цвета, beobachten аналитика |
| 12 | Таймауты | Handshake, keepalive, idle (soft/hard), upstream |
| 13 | Продвинутые | KDF policy, pool floor mode, STUN, multipath |
| 14 | Сервис | Пути установки, systemd / OpenRC |

---

## Режимы прокси

| Режим | Префикс секрета | Описание |
|-------|----------------|----------|
| **TLS** | `ee` + secret | Рекомендуется. Маскируется под HTTPS-трафик |
| **Secure** | `dd` + secret | Шифрованный без TLS-маскировки |
| **Classic** | secret | Устаревший, для старых клиентов |

После установки скрипт выводит готовые ссылки для всех пользователей:

```
tg://proxy?server=YOUR_IP&port=443&secret=ee<32_hex_chars>
```

---

## Docker

При выборе Docker-установки скрипт генерирует `docker-compose.yml` с hardened-настройками:

```yaml
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./config.toml:/run/telemt/config.toml:ro
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
```

---

## Управление сервисом

```bash
systemctl status telemt      # статус
journalctl -u telemt -f      # логи live
systemctl restart telemt     # перезапуск
systemctl stop telemt        # остановка
```

---

## Удаление

Запустите установщик повторно и выберите:

- **Uninstall** — удаляет бинарник и сервис, оставляет конфиг и данные
- **Purge** — полное удаление: бинарник, сервис, конфиг, данные, системный пользователь

---

## Ссылки

- [Telemt — исходный код](https://github.com/telemt/telemt)
- [Документация по конфигурации](https://github.com/telemt/telemt/blob/main/docs/CONFIG_PARAMS.en.md)
- [Быстрый старт (RU)](https://github.com/telemt/telemt/blob/main/docs/QUICK_START_GUIDE.ru.md)
- [FAQ (RU)](https://github.com/telemt/telemt/blob/main/docs/FAQ.ru.md)
- Получить ad\_tag: [@MTProxybot](https://t.me/MTProxybot) в Telegram

---

## Лицензия

Данный установщик распространяется под лицензией MIT.
Сам Telemt имеет собственную лицензию — см. [LICENSE](https://github.com/telemt/telemt/blob/main/LICENSE).
