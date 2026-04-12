#!/usr/bin/env bash
# =============================================================================
#  Telemt MTProto Прокси — Интерактивный установщик для VPS
#  https://github.com/telemt/telemt
#
#  Одна команда (вставить в консоль VPS):
#    bash <(curl -fsSL https://raw.githubusercontent.com/medvedicos/MTProto-Go/main/install_telemt.sh)
#
#  Если не root:
#    sudo bash <(curl -fsSL https://raw.githubusercontent.com/medvedicos/MTProto-Go/main/install_telemt.sh)
# =============================================================================
set -euo pipefail

# Защита: curl | bash ломает интерактивный ввод — определяем и прерываем
if [ ! -t 0 ]; then
    echo ""
    echo "ОШИБКА: Этот скрипт интерактивный и не может работать через пайп (curl ... | bash)."
    echo ""
    echo "Используйте вместо этого:"
    echo ""
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/medvedicos/MTProto-Go/main/install_telemt.sh)"
    echo ""
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# КОНСТАНТЫ
# ──────────────────────────────────────────────────────────────────────────────
REPO="telemt/telemt"
BINARY_NAME="telemt"
INSTALL_DIR="/usr/bin"
CONFIG_DIR="/etc/telemt"
DATA_DIR="/var/lib/telemt"
SERVICE_USER="telemt"
SERVICE_GROUP="telemt"
CONFIG_FILE="${CONFIG_DIR}/telemt.toml"
SERVICE_FILE="/etc/systemd/system/telemt.service"
OPENRC_FILE="/etc/init.d/telemt"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
WHT='\033[1;37m'
DIM='\033[0;37m'
RST='\033[0m'
BOLD='\033[1m'

# ──────────────────────────────────────────────────────────────────────────────
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ──────────────────────────────────────────────────────────────────────────────
banner() {
    echo ""
    echo -e "${CYN}${BOLD}╔══════════════════════════════════════════════════════════╗${RST}"
    echo -e "${CYN}${BOLD}║       Telemt MTProto Прокси — Установщик для VPS         ║${RST}"
    echo -e "${CYN}${BOLD}║              https://github.com/telemt/telemt              ║${RST}"
    echo -e "${CYN}${BOLD}╚══════════════════════════════════════════════════════════╝${RST}"
    echo ""
}

step() { echo -e "\n${BLU}${BOLD}▶ $*${RST}"; }
info() { echo -e "  ${DIM}$*${RST}"; }
ok()   { echo -e "  ${GRN}✔ $*${RST}"; }
warn() { echo -e "  ${YLW}⚠ $*${RST}"; }
err()  { echo -e "  ${RED}✖ $*${RST}" >&2; }
die()  { err "$*"; exit 1; }

hr() { echo -e "${DIM}──────────────────────────────────────────────────────────${RST}"; }

# Запрос с значением по умолчанию
ask() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="$3"
    local answer

    if [[ -n "$default" ]]; then
        echo -ne "  ${WHT}${prompt}${RST} ${DIM}[${default}]${RST}: "
    else
        echo -ne "  ${WHT}${prompt}${RST}: "
    fi
    read -r answer
    answer="${answer:-$default}"
    printf -v "$var_name" '%s' "$answer"
}

# Запрос Да/Нет
ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local var_name="$3"
    local answer
    local hint
    if [[ "$default" == "y" ]]; then hint="Д/н"; else hint="д/Н"; fi

    echo -ne "  ${WHT}${prompt}${RST} ${DIM}[${hint}]${RST}: "
    read -r answer
    answer="${answer:-$default}"
    case "$answer" in
        [ДдYy]*) printf -v "$var_name" 'true'  ;;
        [НнNn]*) printf -v "$var_name" 'false' ;;
        *)       printf -v "$var_name" 'true'  ;;
    esac
}

# Выбор из меню
menu() {
    local prompt="$1"
    shift
    local options=("$@")
    local i answer
    echo -e "  ${WHT}${prompt}${RST}"
    for i in "${!options[@]}"; do
        echo -e "    ${CYN}$((i+1))${RST}) ${options[$i]}"
    done
    while true; do
        echo -ne "  Введите номер: "
        read -r answer
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
            MENU_RESULT="${options[$((answer-1))]}"
            MENU_IDX=$((answer-1))
            return 0
        fi
        warn "Неверный выбор. Введите число от 1 до ${#options[@]}"
    done
}

# Генерация случайного hex-секрета
gen_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 16
    elif [[ -r /dev/urandom ]]; then
        head -c 16 /dev/urandom | xxd -p | tr -d '\n'
    else
        die "Невозможно сгенерировать секрет: требуется openssl или /dev/urandom"
    fi
}

# Проверка hex-строки
is_hex32() { [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]; }

# Определение архитектуры
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)        ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) die "Неподдерживаемая архитектура: $machine" ;;
    esac
}

# Определение libc
detect_libc() {
    if ldd --version 2>&1 | grep -qi musl; then
        LIBC="musl"
    elif ldd --version 2>&1 | grep -qi "gnu\|glibc"; then
        LIBC="gnu"
    elif [[ -f /lib/libc.musl* ]]; then
        LIBC="musl"
    else
        LIBC="gnu"
    fi
}

# Определение менеджера служб
detect_service_manager() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        SVC_MGR="systemd"
    elif command -v rc-service &>/dev/null; then
        SVC_MGR="openrc"
    else
        SVC_MGR="none"
    fi
}

# Получение последней версии с GitHub
get_latest_version() {
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" | grep '"tag_name"' | cut -d'"' -f4
    elif command -v wget &>/dev/null; then
        wget -qO- "$url" | grep '"tag_name"' | cut -d'"' -f4
    else
        die "Требуется curl или wget"
    fi
}

# Загрузка файла
download() {
    local url="$1"
    local dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -qO "$dest" "$url"
    else
        die "Требуется curl или wget"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ
# ──────────────────────────────────────────────────────────────────────────────
preflight() {
    step "Проверка системных требований"

    if [[ $EUID -ne 0 ]]; then
        die "Скрипт должен быть запущен от имени root (или через sudo)"
    fi

    for cmd in grep sed awk cut tr head; do
        command -v "$cmd" &>/dev/null || die "Не найдена необходимая команда: $cmd"
    done
    ok "Запущен от root"

    detect_arch
    ok "Архитектура: ${ARCH}"

    detect_libc
    ok "Библиотека C: ${LIBC}"

    detect_service_manager
    ok "Менеджер служб: ${SVC_MGR}"
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 1 — МЕТОД УСТАНОВКИ
# ──────────────────────────────────────────────────────────────────────────────
step_method() {
    step "Метод установки"
    hr

    menu "Как установить Telemt?" \
        "Бинарник (скачать готовый релиз) [рекомендуется]" \
        "Docker / docker-compose" \
        "Удалить существующую установку" \
        "Полное удаление (включая данные и конфиг)"

    INSTALL_METHOD="$MENU_IDX"

    case "$INSTALL_METHOD" in
        0) INSTALL_TYPE="binary" ;;
        1) INSTALL_TYPE="docker" ;;
        2) INSTALL_TYPE="uninstall" ;;
        3) INSTALL_TYPE="purge" ;;
    esac

    if [[ "$INSTALL_TYPE" == "uninstall" || "$INSTALL_TYPE" == "purge" ]]; then
        do_uninstall
        exit 0
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 2 — ВЫБОР ВЕРСИИ
# ──────────────────────────────────────────────────────────────────────────────
step_version() {
    step "Выбор версии"
    hr

    info "Получаем информацию о последней версии..."
    LATEST_VER="$(get_latest_version || echo '')"
    if [[ -z "$LATEST_VER" ]]; then
        warn "Не удалось получить версию с GitHub"
        LATEST_VER="latest"
    else
        ok "Последняя версия: ${LATEST_VER}"
    fi

    ask "Версия для установки (оставьте пустым для последней)" "$LATEST_VER" SELECTED_VERSION
    SELECTED_VERSION="${SELECTED_VERSION:-latest}"

    if [[ "$SELECTED_VERSION" != "latest" ]] && ! [[ "$SELECTED_VERSION" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        die "Неверный формат версии: ${SELECTED_VERSION}"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 3 — СЕРВЕР И СЕТЬ
# ──────────────────────────────────────────────────────────────────────────────
step_server() {
    step "Настройка сервера и сети"
    hr

    ask "Порт сервера" "443" SERVER_PORT
    [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) \
        || die "Неверный порт: ${SERVER_PORT}"

    ask "IPv4-адрес для прослушивания (0.0.0.0 = все интерфейсы)" "0.0.0.0" LISTEN_IPV4

    ask_yn "Включить поддержку IPv6?" "n" ENABLE_IPV6
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ask "IPv6-адрес для прослушивания (:: = все интерфейсы)" "::" LISTEN_IPV6
    else
        LISTEN_IPV6="::"
    fi

    ask "Максимум одновременных подключений (0 = без ограничений)" "10000" MAX_CONNECTIONS

    ask_yn "Включить PROXY protocol (для HAProxy / Nginx)?" "n" PROXY_PROTOCOL
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 4 — РЕЖИМЫ ПРОКСИ
# ──────────────────────────────────────────────────────────────────────────────
step_modes() {
    step "Режимы прокси"
    hr
    info "Можно включить несколько режимов одновременно."
    info "Режим TLS рекомендуется для обхода блокировок."

    ask_yn "Включить TLS-режим (рекомендуется, обход блокировок)?" "y" MODE_TLS
    ask_yn "Включить Secure-режим?" "n" MODE_SECURE
    ask_yn "Включить Classic-режим (совместимость со старым MTProxy)?" "n" MODE_CLASSIC

    if [[ "$MODE_TLS" == "false" && "$MODE_SECURE" == "false" && "$MODE_CLASSIC" == "false" ]]; then
        warn "Ни один режим не выбран — включается TLS по умолчанию"
        MODE_TLS="true"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 5 — АНТИЦЕНЗУРА (TLS-МАСКИРОВКА)
# ──────────────────────────────────────────────────────────────────────────────
step_censorship() {
    step "Антицензура / TLS-маскировка"
    hr
    info "TLS-маскировка делает прокси неотличимым от обычного HTTPS-трафика."
    info "TLS-домен используется как SNI-имя хоста для камуфляжа."

    while true; do
        ask "Домен для TLS-маскировки (любой рабочий HTTPS-сайт)" "petrovich.ru" TLS_DOMAIN
        # Убираем любые не-ASCII и недопустимые символы (защита от мусора терминала)
        TLS_DOMAIN="$(printf '%s' "$TLS_DOMAIN" | tr -cd 'a-zA-Z0-9.-')"
        if [[ "$TLS_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
            break
        fi
        warn "Неверный формат домена. Введите корректный домен, например: google.com"
    done

    ask_yn "Включить маскировку (проксировать неизвестный TLS на реальный сервер)?" "y" MASK_ENABLED
    ask_yn "Включить эмуляцию TLS (имитировать поведение настоящего TLS-сервера)?" "y" TLS_EMULATION

    if [[ "$MASK_ENABLED" == "true" ]]; then
        info "Хост маскировки по умолчанию совпадает с TLS-доменом"
        ask "Переопределить хост маскировки (оставьте пустым = TLS-домен)" "" MASK_HOST
    fi

    info ""
    info "Действие при получении неизвестного SNI:"
    menu "Что делать с неизвестным SNI:" \
        "drop — закрыть соединение" \
        "mask — перенаправить на реальный сервер"
    case "$MENU_IDX" in
        0) UNKNOWN_SNI="drop" ;;
        1) UNKNOWN_SNI="mask" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 6 — MIDDLE-END (ME) ТРАНСПОРТ
# ──────────────────────────────────────────────────────────────────────────────
step_middle_proxy() {
    step "Middle-End (ME) транспорт"
    hr
    info "Middle proxy обеспечивает полный MTProto через официальную сеть ретрансляторов Telegram."
    info "Отключайте только если нужен режим прямого подключения к DC."

    ask_yn "Включить middle proxy (ME-транспорт)?" "y" USE_MIDDLE_PROXY

    if [[ "$USE_MIDDLE_PROXY" == "true" ]]; then
        ask_yn "Включить fast mode (оптимизация пропускной способности)?" "n" FAST_MODE
        ask_yn "Предпочитать IPv6 для исходящих подключений?" "n" PREFER_IPV6

        info ""
        info "Размер пула определяет количество активных ME-соединений."
        ask "Размер пула ME writer" "8" ME_POOL_SIZE
        ask "Количество тёплых резервных соединений ME" "16" ME_WARM_STANDBY
    else
        FAST_MODE="false"
        PREFER_IPV6="false"
        ME_POOL_SIZE="8"
        ME_WARM_STANDBY="16"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 7 — ПОЛЬЗОВАТЕЛИ И СЕКРЕТЫ
# ──────────────────────────────────────────────────────────────────────────────
step_users() {
    step "Настройка пользователей"
    hr
    info "Каждый пользователь получает уникальный 32-символьный hex-секрет."
    info "Подключение: tg://proxy?server=ХОСТ&port=ПОРТ&secret=СЕКРЕТ"

    USERS=()

    while true; do
        echo ""
        DEFAULT_NAME="user$((${#USERS[@]} + 1))"
        ask "Имя пользователя" "$DEFAULT_NAME" U_NAME

        ask_yn "Сгенерировать секрет автоматически для '${U_NAME}'?" "y" AUTO_SECRET
        if [[ "$AUTO_SECRET" == "true" ]]; then
            U_SECRET="$(gen_secret)"
            ok "Сгенерирован секрет: ${U_SECRET}"
        else
            while true; do
                ask "Секрет (32 hex-символа)" "" U_SECRET
                if is_hex32 "$U_SECRET"; then break; fi
                warn "Секрет должен содержать ровно 32 шестнадцатеричных символа"
            done
        fi

        USERS+=("${U_NAME}:${U_SECRET}")

        ask_yn "Добавить ещё одного пользователя?" "n" ADD_MORE
        if [[ "$ADD_MORE" == "false" ]]; then break; fi
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 8 — ПУБЛИЧНЫЕ ССЫЛКИ
# ──────────────────────────────────────────────────────────────────────────────
step_links() {
    step "Публичные ссылки для подключения"
    hr
    info "Эти настройки определяют tg://-ссылки, отображаемые после запуска."
    info "Оставьте хост пустым — IP будет определён автоматически."

    ask "Публичный хост или IP для ссылок (пусто = автоопределение)" "" PUBLIC_HOST
    if [[ -n "$PUBLIC_HOST" ]]; then
        ask "Публичный порт для ссылок" "$SERVER_PORT" PUBLIC_PORT
    else
        PUBLIC_PORT="$SERVER_PORT"
    fi

    info ""
    info "show_link — для каких пользователей показывать ссылку при запуске."
    menu "Показывать ссылки для:" \
        "Всех пользователей (*)" \
        "Никому (пустой список)" \
        "Конкретных пользователей (указать имена)"

    case "$MENU_IDX" in
        0) SHOW_LINK='"*"' ;;
        1) SHOW_LINK='[]' ;;
        2)
            ask "Имена пользователей через запятую" "" LINK_USERS
            IFS=',' read -ra LINK_ARR <<< "$LINK_USERS"
            TOML_LINK_ARR=""
            for u in "${LINK_ARR[@]}"; do
                u="$(echo "$u" | xargs)"
                TOML_LINK_ARR="${TOML_LINK_ARR}\"${u}\", "
            done
            SHOW_LINK="[${TOML_LINK_ARR%, }]"
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 9 — AD TAG (СПОНСОРСКИЙ КАНАЛ)
# ──────────────────────────────────────────────────────────────────────────────
step_adtag() {
    step "Спонсорский канал (ad_tag)"
    hr
    info "Если у вас есть Telegram-канал, вы можете монетизировать прокси."
    info "Получите ad_tag у бота @MTProxybot в Telegram."

    ask_yn "Настроить спонсорский канал (ad_tag)?" "n" WANT_ADTAG
    if [[ "$WANT_ADTAG" == "true" ]]; then
        while true; do
            ask "Ad tag (32 hex-символа от @MTProxybot)" "" AD_TAG
            if is_hex32 "$AD_TAG"; then break; fi
            warn "Ad tag должен содержать ровно 32 шестнадцатеричных символа"
        done
    else
        AD_TAG=""
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 10 — API И МЕТРИКИ
# ──────────────────────────────────────────────────────────────────────────────
step_api() {
    step "Административный API и метрики"
    hr
    info "REST API позволяет управлять прокси в режиме реального времени."
    info "Рекомендуется открывать только для localhost или доверенных сетей."

    ask_yn "Включить административный REST API?" "y" API_ENABLED
    if [[ "$API_ENABLED" == "true" ]]; then
        ask "Адрес:порт API" "127.0.0.1:9091" API_LISTEN
        ask "Разрешённые сети для API (CIDR через запятую)" "127.0.0.0/8" API_WHITELIST_RAW

        ask_yn "Включить режим только для чтения (read-only API)?" "n" API_READONLY
        ask_yn "Требовать заголовок Authorization?" "n" API_AUTH
        if [[ "$API_AUTH" == "true" ]]; then
            ask "Значение заголовка Authorization (например: Bearer мойтокен)" "" API_AUTH_HEADER
        else
            API_AUTH_HEADER=""
        fi
    fi

    echo ""
    ask_yn "Включить эндпоинт метрик Prometheus?" "n" METRICS_ENABLED
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        ask "Адрес:порт метрик" "127.0.0.1:9090" METRICS_LISTEN
        ask "Разрешённые сети для метрик (CIDR через запятую)" "127.0.0.1/32,::1/128" METRICS_WHITELIST_RAW
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 11 — ЛОГИРОВАНИЕ
# ──────────────────────────────────────────────────────────────────────────────
step_logging() {
    step "Логирование"
    hr

    menu "Уровень логирования:" \
        "normal — стандартный" \
        "verbose — подробный" \
        "debug — отладочный" \
        "silent — без логов"
    LOG_LEVEL="${MENU_RESULT%% *}"

    ask_yn "Отключить цвета ANSI в логах?" "n" NO_COLORS
    ask_yn "Включить аналитику по IP-адресам (beobachten)?" "y" BEOBACHTEN

    if [[ "$BEOBACHTEN" == "true" ]]; then
        ask "Период хранения данных наблюдения (минут)" "10" BEOB_MINUTES
        ask "Интервал сброса данных на диск (секунд)" "15" BEOB_FLUSH
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 12 — ТАЙМАУТЫ
# ──────────────────────────────────────────────────────────────────────────────
step_timeouts() {
    step "Таймауты соединений"
    hr
    info "Управляют поведением при установке соединения и простое."

    ask_yn "Настроить таймауты вручную?" "n" CUSTOM_TIMEOUTS
    if [[ "$CUSTOM_TIMEOUTS" == "true" ]]; then
        ask "Таймаут handshake клиента (секунд)" "30" TO_HANDSHAKE
        ask "Интервал keepalive клиента (секунд)" "15" TO_KEEPALIVE
        ask "Мягкий порог простоя relay (секунд)" "120" TO_IDLE_SOFT
        ask "Жёсткий порог простоя relay (секунд)" "360" TO_IDLE_HARD
        ask "Таймаут подключения к Telegram (секунд)" "10" TO_UPSTREAM
    else
        TO_HANDSHAKE="30"
        TO_KEEPALIVE="15"
        TO_IDLE_SOFT="120"
        TO_IDLE_HARD="360"
        TO_UPSTREAM="10"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 13 — РАСШИРЕННЫЕ НАСТРОЙКИ
# ──────────────────────────────────────────────────────────────────────────────
step_advanced() {
    step "Расширенные настройки"
    hr

    ask_yn "Настроить расширенные параметры?" "n" WANT_ADVANCED
    if [[ "$WANT_ADVANCED" == "false" ]]; then
        PREFER_NET=4
        NET_MULTIPATH="false"
        STUN_ENABLED="true"
        ME_POOL_FLOOR="adaptive"
        ME_KDF_POLICY="strict"
        HARDSWAP="true"
        FAST_MODE_MIN_TLS=0
        UPDATE_EVERY=300
        return
    fi

    info "Предпочтение IP-версии для исходящих соединений:"
    menu "Предпочитать:" "IPv4 (4)" "IPv6 (6)"
    PREFER_NET=$((MENU_IDX == 0 ? 4 : 6))

    ask_yn "Включить multipath (экспериментально)?" "n" NET_MULTIPATH
    ask_yn "Включить STUN для определения публичного IP (NAT)?" "y" STUN_ENABLED

    echo ""
    info "Режим нижней границы пула ME writer:"
    menu "Режим пула:" \
        "adaptive — автомасштабирование по нагрузке" \
        "static — фиксированный размер пула"
    ME_POOL_FLOOR="$([ "$MENU_IDX" -eq 0 ] && echo adaptive || echo static)"

    echo ""
    info "KDF-политика определяет криптографическую совместимость:"
    menu "Политика ME SOCKS KDF:" \
        "strict — строгая" \
        "compat — совместимая (шире поддержка клиентов)"
    ME_KDF_POLICY="$([ "$MENU_IDX" -eq 0 ] && echo strict || echo compat)"

    ask_yn "Включить hardswap (ротация пула по поколениям)?" "y" HARDSWAP
    ask "Минимальный размер TLS-записи для fast mode (0 = отключено)" "0" FAST_MODE_MIN_TLS
    ask "Интервал обновления конфигурации (секунд)" "300" UPDATE_EVERY
}

# ──────────────────────────────────────────────────────────────────────────────
# ШАГ 14 — НАСТРОЙКА СЛУЖБЫ
# ──────────────────────────────────────────────────────────────────────────────
step_service() {
    step "Настройка системной службы"
    hr

    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        ask "Директория проекта Docker Compose" "/opt/telemt" DOCKER_DIR
        return
    fi

    if [[ "$SVC_MGR" == "none" ]]; then
        warn "Менеджер служб не обнаружен. Telemt будет установлен, но не зарегистрирован как служба."
        warn "Запустите вручную: ${INSTALL_DIR}/${BINARY_NAME} ${CONFIG_FILE}"
        ENABLE_SERVICE="false"
        return
    fi

    ask_yn "Зарегистрировать и включить Telemt как системную службу?" "y" ENABLE_SERVICE
    ask_yn "Запустить службу Telemt сразу после установки?" "y" START_SERVICE

    ask "Директория для бинарного файла" "/usr/bin" INSTALL_DIR
    ask "Директория конфигурации" "/etc/telemt" CONFIG_DIR
    ask "Рабочая директория (данные)" "/var/lib/telemt" DATA_DIR
}

# ──────────────────────────────────────────────────────────────────────────────
# ПРОСМОТР И ПОДТВЕРЖДЕНИЕ
# ──────────────────────────────────────────────────────────────────────────────
review() {
    step "Сводка настроек"
    hr
    echo ""
    echo -e "  ${WHT}Тип установки     :${RST} ${INSTALL_TYPE}"
    echo -e "  ${WHT}Версия            :${RST} ${SELECTED_VERSION}"

    if [[ "$INSTALL_TYPE" == "binary" ]]; then
        echo -e "  ${WHT}Бинарный файл     :${RST} ${INSTALL_DIR}/${BINARY_NAME}"
        echo -e "  ${WHT}Файл конфигурации :${RST} ${CONFIG_FILE}"
        echo -e "  ${WHT}Директория данных :${RST} ${DATA_DIR}"
    fi

    echo -e "  ${WHT}Порт сервера      :${RST} ${SERVER_PORT}"
    echo -e "  ${WHT}Привязка IPv4     :${RST} ${LISTEN_IPV4}"
    echo -e "  ${WHT}IPv6              :${RST} ${ENABLE_IPV6}"
    echo -e "  ${WHT}Режимы            :${RST} TLS=${MODE_TLS}  Secure=${MODE_SECURE}  Classic=${MODE_CLASSIC}"
    echo -e "  ${WHT}TLS-домен         :${RST} ${TLS_DOMAIN}"
    echo -e "  ${WHT}Маскировка        :${RST} ${MASK_ENABLED}"
    echo -e "  ${WHT}Middle proxy (ME) :${RST} ${USE_MIDDLE_PROXY}"
    echo -e "  ${WHT}Уровень логов     :${RST} ${LOG_LEVEL}"

    echo ""
    echo -e "  ${WHT}Пользователи:${RST}"
    for u in "${USERS[@]}"; do
        local name="${u%%:*}"
        local secret="${u##*:}"
        echo -e "    ${CYN}${name}${RST}  →  ${DIM}${secret}${RST}"
    done

    [[ -n "$AD_TAG" ]] && echo -e "  ${WHT}Ad tag            :${RST} ${AD_TAG}"
    [[ "$API_ENABLED" == "true" ]] && echo -e "  ${WHT}API               :${RST} ${API_LISTEN}"
    [[ "$METRICS_ENABLED" == "true" ]] && echo -e "  ${WHT}Метрики           :${RST} ${METRICS_LISTEN}"

    echo ""
    hr
    ask_yn "Начать установку?" "y" CONFIRMED
    if [[ "$CONFIRMED" == "false" ]]; then die "Установка отменена."; fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ГЕНЕРАЦИЯ config.toml
# ──────────────────────────────────────────────────────────────────────────────
generate_config() {
    local api_wl_toml=""
    if [[ "$API_ENABLED" == "true" ]]; then
        IFS=',' read -ra wl_arr <<< "${API_WHITELIST_RAW:-127.0.0.0/8}"
        for cidr in "${wl_arr[@]}"; do
            cidr="$(echo "$cidr" | xargs)"
            api_wl_toml="${api_wl_toml}\"${cidr}\", "
        done
        api_wl_toml="[${api_wl_toml%, }]"
    fi

    local metrics_wl_toml=""
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        IFS=',' read -ra mwl_arr <<< "${METRICS_WHITELIST_RAW:-127.0.0.1/32}"
        for cidr in "${mwl_arr[@]}"; do
            cidr="$(echo "$cidr" | xargs)"
            metrics_wl_toml="${metrics_wl_toml}\"${cidr}\", "
        done
        metrics_wl_toml="[${metrics_wl_toml%, }]"
    fi

    local extra_domains=""
    [[ -n "$TLS_DOMAIN" ]] && extra_domains="tls_domains = []"

    local mask_host_line=""
    [[ -n "${MASK_HOST:-}" ]] && mask_host_line="mask_host = \"${MASK_HOST}\""

    local pub_host_line=""
    local pub_port_line=""
    [[ -n "${PUBLIC_HOST:-}" ]] && pub_host_line="public_host = \"${PUBLIC_HOST}\""
    [[ -n "${PUBLIC_PORT:-}" ]] && pub_port_line="public_port = ${PUBLIC_PORT}"

    local adtag_line=""
    [[ -n "${AD_TAG:-}" ]] && adtag_line="ad_tag = \"${AD_TAG}\""

    local auth_header_line=""
    [[ -n "${API_AUTH_HEADER:-}" ]] && auth_header_line="auth_header = \"${API_AUTH_HEADER}\""

    CONFIG_CONTENT="# =============================================================================
# Telemt MTProto Прокси — Конфигурация
# Сгенерировано install_telemt.sh от $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Полный справочник: https://github.com/telemt/telemt/blob/main/docs/CONFIG_PARAMS.en.md
# =============================================================================

# Видимость ссылок — для каких пользователей показывать tg://-ссылку при запуске
show_link = ${SHOW_LINK}

# =============================================================================
[general]
# =============================================================================

use_middle_proxy = ${USE_MIDDLE_PROXY}
fast_mode        = ${FAST_MODE}
log_level        = \"${LOG_LEVEL}\"
disable_colors   = ${NO_COLORS}
hardswap         = ${HARDSWAP}
beobachten       = ${BEOBACHTEN}
beobachten_minutes = ${BEOB_MINUTES:-10}
beobachten_flush_secs = ${BEOB_FLUSH:-15}
beobachten_file  = \"cache/beobachten.txt\"
fast_mode_min_tls_record = ${FAST_MODE_MIN_TLS:-0}
update_every     = ${UPDATE_EVERY:-300}
$([ -n "$adtag_line" ] && echo "$adtag_line" || true)
$([ -n "$adtag_line" ] || echo "# ad_tag = \"\"  # Раскомментируйте и укажите тег от @MTProxybot")

# Пул Middle-End соединений
middle_proxy_pool_size    = ${ME_POOL_SIZE}
middle_proxy_warm_standby = ${ME_WARM_STANDBY}
me_floor_mode             = \"${ME_POOL_FLOOR:-adaptive}\"
me_socks_kdf_policy       = \"${ME_KDF_POLICY:-strict}\"

# =============================================================================
[general.modes]
# =============================================================================

classic = ${MODE_CLASSIC}
secure  = ${MODE_SECURE}
tls     = ${MODE_TLS}

# =============================================================================
[general.links]
# =============================================================================

$([ -n "$pub_host_line" ] && echo "$pub_host_line" || echo "# public_host = \"ваш.ip.или.домен\"")
$([ -n "$pub_port_line" ] && echo "$pub_port_line" || echo "# public_port = ${SERVER_PORT}")

# =============================================================================
[general.telemetry]
# =============================================================================

core_enabled = true
user_enabled = true
me_level     = \"normal\"

# =============================================================================
[network]
# =============================================================================

ipv4      = true
ipv6      = ${ENABLE_IPV6}
prefer    = ${PREFER_NET:-4}
multipath = ${NET_MULTIPATH:-false}
stun_use  = ${STUN_ENABLED:-true}

# =============================================================================
[server]
# =============================================================================

port             = ${SERVER_PORT}
listen_addr_ipv4 = \"${LISTEN_IPV4}\"
$([ "$ENABLE_IPV6" == "true" ] && echo "listen_addr_ipv6 = \"${LISTEN_IPV6}\"" || echo "# listen_addr_ipv6 = \"::\"")
proxy_protocol   = ${PROXY_PROTOCOL}
max_connections  = ${MAX_CONNECTIONS}

$([ "$METRICS_ENABLED" == "true" ] && echo "metrics_listen    = \"${METRICS_LISTEN}\"" || echo "# metrics_listen = \"127.0.0.1:9090\"")
$([ "$METRICS_ENABLED" == "true" ] && echo "metrics_whitelist = ${metrics_wl_toml}" || echo "# metrics_whitelist = [\"127.0.0.1/32\"]")

# =============================================================================
[server.api]
# =============================================================================

enabled   = ${API_ENABLED}
$([ "$API_ENABLED" == "true" ] && echo "listen    = \"${API_LISTEN}\"" || echo "# listen = \"127.0.0.1:9091\"")
$([ "$API_ENABLED" == "true" ] && echo "whitelist = ${api_wl_toml}" || echo "# whitelist = [\"127.0.0.0/8\"]")
$([ "${API_READONLY:-false}" == "true" ] && echo "read_only = true" || echo "read_only = false")
$([ -n "$auth_header_line" ] && echo "$auth_header_line" || true)
minimal_runtime_enabled      = true
minimal_runtime_cache_ttl_ms = 1000

# =============================================================================
[[server.listeners]]
# =============================================================================

ip = \"${LISTEN_IPV4}\"

# =============================================================================
[timeouts]
# =============================================================================

client_handshake              = ${TO_HANDSHAKE}
client_keepalive              = ${TO_KEEPALIVE}
relay_idle_policy_v2_enabled  = true
relay_client_idle_soft_secs   = ${TO_IDLE_SOFT}
relay_client_idle_hard_secs   = ${TO_IDLE_HARD}
tg_connect                    = ${TO_UPSTREAM}

# =============================================================================
[censorship]
# =============================================================================

tls_domain        = \"${TLS_DOMAIN}\"
${extra_domains}
unknown_sni_action = \"${UNKNOWN_SNI}\"
mask              = ${MASK_ENABLED}
$([ -n "$mask_host_line" ] && echo "$mask_host_line" || true)
tls_emulation     = ${TLS_EMULATION}
tls_front_dir     = \"tlsfront\"
mask_shape_hardening = true

[access.users]
"

    for u in "${USERS[@]}"; do
        local uname="${u%%:*}"
        local usecret="${u##*:}"
        CONFIG_CONTENT+="${uname} = \"${usecret}\"
"
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# УСТАНОВКА БИНАРНИКА
# ──────────────────────────────────────────────────────────────────────────────
install_binary() {
    step "Загрузка бинарного файла Telemt"
    hr

    local version="$SELECTED_VERSION"
    if [[ "$version" == "latest" ]]; then
        version="$(get_latest_version)" || die "Не удалось получить последнюю версию"
    fi

    # Реальный формат архивов: telemt-{ARCH}-linux-{LIBC}.tar.gz (без версии в имени)
    local asset="telemt-${ARCH}-linux-${LIBC}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/${version}/${asset}"

    info "Загрузка: ${url}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" EXIT

    download "$url" "${tmpdir}/${asset}"
    ok "Загружен: ${asset}"

    info "Распаковка..."
    tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}/"
    local extracted_bin
    extracted_bin="$(find "${tmpdir}" -type f -name "${BINARY_NAME}" | head -1)"
    if [[ -z "$extracted_bin" ]]; then die "Бинарный файл не найден в архиве"; fi

    install -Dm755 "$extracted_bin" "${INSTALL_DIR}/${BINARY_NAME}"
    ok "Установлен: ${INSTALL_DIR}/${BINARY_NAME}"

    if command -v setcap &>/dev/null; then
        setcap cap_net_bind_service+eip "${INSTALL_DIR}/${BINARY_NAME}"
        ok "Установлена capability CAP_NET_BIND_SERVICE"
    else
        warn "setcap не найден — для привязки к порту ${SERVER_PORT} может потребоваться root"
        warn "Установите: libcap2-bin (Debian/Ubuntu) или libcap (RHEL/Alpine)"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ, ДИРЕКТОРИЙ, КОНФИГУРАЦИИ
# ──────────────────────────────────────────────────────────────────────────────
setup_environment() {
    step "Создание пользователя, директорий и конфигурации"
    hr

    if ! getent group "$SERVICE_GROUP" &>/dev/null; then
        groupadd --system "$SERVICE_GROUP"
        ok "Создана группа: ${SERVICE_GROUP}"
    fi
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd --system --gid "$SERVICE_GROUP" \
            --no-create-home --shell /sbin/nologin \
            --home-dir "$DATA_DIR" "$SERVICE_USER"
        ok "Создан пользователь: ${SERVICE_USER}"
    fi

    install -dm750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$CONFIG_DIR"
    install -dm750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$DATA_DIR"
    install -dm750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "${DATA_DIR}/cache"
    install -dm750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "${DATA_DIR}/tlsfront"
    ok "Директории созданы"

    generate_config
    echo "$CONFIG_CONTENT" > "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    chown "$SERVICE_USER":"$SERVICE_GROUP" "$CONFIG_FILE"
    ok "Конфигурация записана: ${CONFIG_FILE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# SYSTEMD СЛУЖБА
# ──────────────────────────────────────────────────────────────────────────────
install_systemd() {
    step "Установка systemd-службы"
    hr

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Telemt MTProto Прокси
Documentation=https://github.com/telemt/telemt
Wants=network-online.target
After=multi-user.target network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_DIR}/${BINARY_NAME} ${CONFIG_FILE}
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    ok "Systemd unit установлен: ${SERVICE_FILE}"

    if [[ "${ENABLE_SERVICE:-true}" == "true" ]]; then
        systemctl enable telemt
        ok "Служба включена (автозапуск при старте системы)"
    fi

    if [[ "${START_SERVICE:-true}" == "true" ]]; then
        systemctl start telemt
        sleep 1
        if systemctl is-active --quiet telemt; then
            ok "Служба успешно запущена"
        else
            warn "Не удалось запустить службу. Проверьте логи:"
            warn "  journalctl -u telemt -n 50 --no-pager"
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# OPENRC СЛУЖБА
# ──────────────────────────────────────────────────────────────────────────────
install_openrc() {
    step "Установка OpenRC-службы"
    hr

    cat > "$OPENRC_FILE" << EOF
#!/sbin/openrc-run

name="telemt"
description="Telemt MTProto Прокси"
command="${INSTALL_DIR}/${BINARY_NAME}"
command_args="${CONFIG_FILE}"
command_user="${SERVICE_USER}:${SERVICE_GROUP}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
directory="${DATA_DIR}"

depend() {
    after net
    use logger
}
EOF
    chmod 755 "$OPENRC_FILE"
    ok "OpenRC-служба установлена: ${OPENRC_FILE}"

    if [[ "${ENABLE_SERVICE:-true}" == "true" ]]; then
        rc-update add telemt default
        ok "Служба включена (автозапуск)"
    fi

    if [[ "${START_SERVICE:-true}" == "true" ]]; then
        rc-service telemt start
        ok "Служба запущена"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# DOCKER УСТАНОВКА
# ──────────────────────────────────────────────────────────────────────────────
install_docker() {
    step "Настройка Docker-развёртывания"
    hr

    command -v docker &>/dev/null || die "Docker не установлен. Сначала установите Docker: https://docs.docker.com/engine/install/"

    mkdir -p "${DOCKER_DIR}"
    generate_config
    echo "$CONFIG_CONTENT" > "${DOCKER_DIR}/config.toml"
    chmod 644 "${DOCKER_DIR}/config.toml"
    ok "Конфигурация записана: ${DOCKER_DIR}/config.toml"

    local image_tag="latest"
    [[ "$SELECTED_VERSION" != "latest" ]] && image_tag="$SELECTED_VERSION"

    local metrics_port_line=""
    [[ "$METRICS_ENABLED" == "true" ]] && metrics_port_line="      - \"127.0.0.1:9090:9090\""

    local api_port_line=""
    [[ "$API_ENABLED" == "true" ]] && api_port_line="      - \"127.0.0.1:9091:9091\""

    cat > "${DOCKER_DIR}/docker-compose.yml" << EOF
# Сгенерировано install_telemt.sh
services:
  telemt:
    image: ghcr.io/telemt/telemt:${image_tag}
    container_name: telemt
    restart: unless-stopped
    ports:
      - "${SERVER_PORT}:${SERVER_PORT}"
${api_port_line:+$api_port_line}
${metrics_port_line:+$metrics_port_line}
    volumes:
      - ./config.toml:/run/telemt/config.toml:ro
    tmpfs:
      - /run/telemt:exec,mode=1777,size=1m
    environment:
      RUST_LOG: info
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    working_dir: /run/telemt
EOF

    ok "docker-compose.yml записан: ${DOCKER_DIR}/docker-compose.yml"

    ask_yn "Запустить контейнер сейчас?" "y" START_DOCKER
    if [[ "$START_DOCKER" == "true" ]]; then
        cd "${DOCKER_DIR}"
        if docker compose version &>/dev/null 2>&1; then
            docker compose up -d
        else
            docker-compose up -d
        fi
        ok "Контейнер запущен"
    else
        info "Запустите вручную: cd ${DOCKER_DIR} && docker compose up -d"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ВЕБ-ПАНЕЛЬ
# ──────────────────────────────────────────────────────────────────────────────
step_web_dashboard() {
    step "Веб-панель управления"
    hr
    info "Веб-панель позволяет управлять пользователями, лимитами и конфигом через браузер."
    echo ""
    ask_yn "Установить веб-панель?" "y" INSTALL_WEB

    if [[ "$INSTALL_WEB" == "false" ]]; then
        info "Веб-панель не будет установлена."
        return
    fi

    ask "Пароль для входа в панель" "changeme" WEB_PASSWORD
    ask "Порт панели" "8080" WEB_PORT
}

install_web_dashboard() {
    [[ "${INSTALL_WEB:-false}" == "false" ]] && return

    step "Установка веб-панели"
    hr

    local WEB_DIR="/opt/telemt-web"
    local WEB_SERVICE="/etc/systemd/system/telemt-web.service"
    local WEB_RAW="https://raw.githubusercontent.com/medvedicos/MTProto-Go/main/telemt-web.py"

    # Зависимости
    info "Проверка Python3 и pip..."
    if command -v apt-get &>/dev/null; then
        local py_ver
        py_ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"
        # DEBIAN_FRONTEND=noninteractive подавляет интерактивные запросы (needrestart и др.)
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
            apt-get install -y -q python3 python3-pip \
            ${py_ver:+python${py_ver}-venv} python3-venv 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y -q python3 python3-pip 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q python3 python3-pip 2>/dev/null || true
    fi
    command -v python3 &>/dev/null || die "Не удалось установить Python3"
    ok "Python3: $(python3 --version)"

    # Директория
    mkdir -p "$WEB_DIR"

    # Virtualenv: пересоздаём если pip отсутствует (защита от неполного venv)
    if [[ ! -x "${WEB_DIR}/venv/bin/python3" ]]; then
        python3 -m venv "${WEB_DIR}/venv" || die "Не удалось создать virtualenv. Попробуйте: apt install python3-venv"
        ok "Создан virtualenv: ${WEB_DIR}/venv"
    fi

    # Зависимости Python — используем python3 -m pip (надёжнее прямого вызова pip)
    "${WEB_DIR}/venv/bin/python3" -m pip install -q --upgrade pip
    "${WEB_DIR}/venv/bin/python3" -m pip install -q flask requests
    ok "Flask и requests установлены"

    # Скачиваем скрипт
    if command -v curl &>/dev/null; then
        curl -fsSL "$WEB_RAW" -o "${WEB_DIR}/telemt-web.py"
    else
        wget -qO "${WEB_DIR}/telemt-web.py" "$WEB_RAW"
    fi
    ok "Скрипт загружен: ${WEB_DIR}/telemt-web.py"

    # Systemd-служба
    cat > "$WEB_SERVICE" << EOF
[Unit]
Description=Telemt Web Dashboard
After=network.target telemt.service

[Service]
Type=simple
User=root
WorkingDirectory=${WEB_DIR}
ExecStart=${WEB_DIR}/venv/bin/python3 ${WEB_DIR}/telemt-web.py
Restart=on-failure
RestartSec=5
Environment=DASHBOARD_PASSWORD=${WEB_PASSWORD}
Environment=DASHBOARD_PORT=${WEB_PORT}
Environment=DASHBOARD_HOST=0.0.0.0
Environment=CONFIG_FILE=${CONFIG_FILE}
Environment=TELEMT_API=http://127.0.0.1:9091

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable telemt-web
    systemctl start telemt-web
    sleep 1

    if systemctl is-active --quiet telemt-web; then
        ok "Веб-панель запущена"
    else
        warn "Не удалось запустить веб-панель. Проверьте:"
        warn "  journalctl -u telemt-web -n 30 --no-pager"
    fi

    # Определяем внешний IP
    local server_ip
    server_ip="$(curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "<IP_СЕРВЕРА>")"

    echo ""
    echo -e "  ${GRN}${BOLD}Веб-панель доступна:${RST}"
    echo -e "  ${CYN}  http://${server_ip}:${WEB_PORT}${RST}"
    echo -e "  ${WHT}  Пароль: ${WEB_PASSWORD}${RST}"
    echo ""
    warn "Панель работает по HTTP (не HTTPS). Не открывайте порт ${WEB_PORT} публично без firewall!"
    info "Рекомендуется: nginx reverse proxy + SSL, или доступ только через SSH-туннель."
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# ВЫВОД ССЫЛОК ДЛЯ ПОДКЛЮЧЕНИЯ
# ──────────────────────────────────────────────────────────────────────────────
print_links() {
    step "Ссылки для подключения"
    hr

    local host="${PUBLIC_HOST}"
    if [[ -z "$host" ]]; then
        if command -v curl &>/dev/null; then
            host="$(curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "")"
        fi
        [[ -z "$host" ]] && host="<IP_ВАШЕГО_СЕРВЕРА>"
    fi

    local port="${PUBLIC_PORT:-$SERVER_PORT}"

    echo ""
    echo -e "  ${WHT}Скопируйте ссылку и отправьте пользователям:${RST}"
    echo ""

    for u in "${USERS[@]}"; do
        local uname="${u%%:*}"
        local usecret="${u##*:}"
        local tls_secret="ee${usecret}"

        echo -e "  ${CYN}── Пользователь: ${uname} ──${RST}"

        if [[ "$MODE_TLS" == "true" ]]; then
            echo -e "    ${GRN}[TLS]${RST}     tg://proxy?server=${host}&port=${port}&secret=${tls_secret}"
        fi
        if [[ "$MODE_SECURE" == "true" ]]; then
            local dd_secret="dd${usecret}"
            echo -e "    ${YLW}[Secure]${RST}  tg://proxy?server=${host}&port=${port}&secret=${dd_secret}"
        fi
        if [[ "$MODE_CLASSIC" == "true" ]]; then
            echo -e "    ${DIM}[Classic]${RST} tg://proxy?server=${host}&port=${port}&secret=${usecret}"
        fi
        echo ""
    done

    hr
    echo ""
    echo -e "  ${WHT}Полезные команды:${RST}"
    if [[ "$INSTALL_TYPE" == "binary" ]]; then
        if [[ "$SVC_MGR" == "systemd" ]]; then
            echo -e "    Статус  : ${CYN}systemctl status telemt${RST}"
            echo -e "    Логи    : ${CYN}journalctl -u telemt -f${RST}"
            echo -e "    Рестарт : ${CYN}systemctl restart telemt${RST}"
            echo -e "    Стоп    : ${CYN}systemctl stop telemt${RST}"
        elif [[ "$SVC_MGR" == "openrc" ]]; then
            echo -e "    Статус  : ${CYN}rc-service telemt status${RST}"
            echo -e "    Рестарт : ${CYN}rc-service telemt restart${RST}"
        fi
        echo -e "    Конфиг  : ${CYN}${CONFIG_FILE}${RST}"
    elif [[ "$INSTALL_TYPE" == "docker" ]]; then
        echo -e "    Статус  : ${CYN}cd ${DOCKER_DIR} && docker compose ps${RST}"
        echo -e "    Логи    : ${CYN}cd ${DOCKER_DIR} && docker compose logs -f${RST}"
        echo -e "    Рестарт : ${CYN}cd ${DOCKER_DIR} && docker compose restart${RST}"
    fi
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# УДАЛЕНИЕ
# ──────────────────────────────────────────────────────────────────────────────
do_uninstall() {
    step "Удаление"
    hr

    local is_purge="false"
    [[ "$INSTALL_TYPE" == "purge" ]] && is_purge="true"

    if command -v systemctl &>/dev/null && systemctl list-units --full -all 2>/dev/null | grep -q "telemt.service"; then
        systemctl stop telemt 2>/dev/null || true
        systemctl disable telemt 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        ok "Systemd-служба удалена"
    fi
    if command -v rc-service &>/dev/null; then
        rc-service telemt stop 2>/dev/null || true
        rc-update del telemt 2>/dev/null || true
        rm -f "$OPENRC_FILE"
        ok "OpenRC-служба удалена"
    fi

    rm -f "${INSTALL_DIR}/${BINARY_NAME}"
    ok "Бинарный файл удалён"

    if [[ "$is_purge" == "true" ]]; then
        rm -rf "$CONFIG_DIR" "$DATA_DIR"
        ok "Директории конфигурации и данных удалены"

        if id "$SERVICE_USER" &>/dev/null; then
            userdel "$SERVICE_USER" 2>/dev/null || true
            ok "Пользователь '${SERVICE_USER}' удалён"
        fi
        if getent group "$SERVICE_GROUP" &>/dev/null; then
            groupdel "$SERVICE_GROUP" 2>/dev/null || true
            ok "Группа '${SERVICE_GROUP}' удалена"
        fi
        ok "Полная очистка завершена"
    else
        ok "Удаление завершено (конфигурация и данные сохранены)"
        info "Конфиг: ${CONFIG_FILE}"
        info "Данные: ${DATA_DIR}"
        info "Для полного удаления запустите снова и выберите 'Полное удаление'"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ТОЧКА ВХОДА
# ──────────────────────────────────────────────────────────────────────────────
main() {
    banner
    preflight
    step_method
    step_version
    step_server
    step_modes
    step_censorship
    step_middle_proxy
    step_users
    step_links
    step_adtag
    step_api
    step_logging
    step_timeouts
    step_advanced
    step_service
    step_web_dashboard
    review

    echo ""
    step "Установка"
    hr

    if [[ "$INSTALL_TYPE" == "binary" ]]; then
        install_binary
        setup_environment

        if [[ "$SVC_MGR" == "systemd" ]]; then
            install_systemd
        elif [[ "$SVC_MGR" == "openrc" ]]; then
            install_openrc
        else
            warn "Менеджер служб не найден — запустите вручную:"
            warn "  sudo -u ${SERVICE_USER} ${INSTALL_DIR}/${BINARY_NAME} ${CONFIG_FILE}"
        fi

    elif [[ "$INSTALL_TYPE" == "docker" ]]; then
        install_docker
    fi

    install_web_dashboard
    print_links

    echo -e "\n  ${GRN}${BOLD}Установка завершена!${RST}\n"
}

main "$@"
