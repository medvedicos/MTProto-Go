# MTProto-Go — Telemt Installer

Интерактивный установщик для [Telemt](https://github.com/telemt/telemt) — высокопроизводительного MTProto-прокси для Telegram, написанного на Rust.

---

## Возможности

- Пошаговый wizard с настройкой всех параметров прокси
- Установка бинарника **или** развёртывание через **Docker / docker-compose**
- Автоопределение архитектуры (x86\_64 / aarch64) и libc (gnu / musl)
- Настройка системного сервиса (**systemd** / **OpenRC**)
- Генерация готового `config.toml` с комментариями
- Автопечать ссылок `tg://` для Telegram-клиентов
- Поддержка Uninstall и Purge

---

## Быстрый старт

```bash
# Скачать установщик
curl -fsSL https://raw.githubusercontent.com/medvedicos/MTProto-Go/main/install_telemt.sh -o install_telemt.sh

# Дать права на выполнение
chmod +x install_telemt.sh

# Запустить от root
sudo ./install_telemt.sh
```

> **Требования:** Linux x86\_64 или aarch64, root-доступ, `curl` или `wget`.

---

## Шаги установки

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

## Анти-цензура

Telemt маскирует трафик под HTTPS, отвечая как настоящий HTTPS-сервер на неизвестные подключения. Настраивается:

- **TLS domain** — домен для SNI-маскировки (по умолчанию: `petrovich.ru`)
- **Masking** — проксирование неизвестного трафика на реальный сервер
- **TLS emulation** — точное воспроизведение поведения TLS-сервера
- **unknown\_sni\_action** — `drop` или `mask`

---

## Docker

Скрипт генерирует готовый `docker-compose.yml` с hardened-настройками:

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

```bash
cd /opt/telemt
docker compose up -d
docker compose logs -f
```

---

## Управление сервисом

```bash
# Статус
systemctl status telemt

# Логи (live)
journalctl -u telemt -f

# Перезапуск
systemctl restart telemt

# Остановка
systemctl stop telemt
```

---

## Удаление

Повторно запустите скрипт и выберите:

- **Uninstall** — удаляет бинарник и сервис, оставляет конфиг и данные
- **Purge** — полное удаление: бинарник, сервис, конфиг, данные, пользователь системы

---

## Конфигурация

После установки конфиг находится в `/etc/telemt/telemt.toml`.

Пример минимальной конфигурации:

```toml
show_link = "*"

[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
tls     = true
secure  = false
classic = false

[server]
port = 443

[censorship]
tls_domain = "petrovich.ru"
mask       = true

[[access.user]]
name   = "myuser"
secret = "0123456789abcdef0123456789abcdef"
```

Полная документация по параметрам: [CONFIG_PARAMS.en.md](https://github.com/telemt/telemt/blob/main/docs/CONFIG_PARAMS.en.md)

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
