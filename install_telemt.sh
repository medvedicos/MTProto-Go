#!/usr/bin/env bash
# =============================================================================
#  Telemt MTProto Proxy — Interactive VPS Installer
#  https://github.com/telemt/telemt
#
#  Usage:
#    chmod +x install_telemt.sh
#    sudo ./install_telemt.sh
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONSTANTS
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
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────
banner() {
    echo ""
    echo -e "${CYN}${BOLD}╔══════════════════════════════════════════════════════════╗${RST}"
    echo -e "${CYN}${BOLD}║        Telemt MTProto Proxy — Interactive Installer       ║${RST}"
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

# Prompt with default value
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

# Yes/No prompt
ask_yn() {
    local prompt="$1"
    local default="${2:-y}"  # y or n
    local var_name="$3"
    local answer
    local hint
    if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi

    echo -ne "  ${WHT}${prompt}${RST} ${DIM}[${hint}]${RST}: "
    read -r answer
    answer="${answer:-$default}"
    case "$answer" in
        [Yy]*) printf -v "$var_name" 'true'  ;;
        [Nn]*) printf -v "$var_name" 'false' ;;
        *)     printf -v "$var_name" 'true'  ;;
    esac
}

# Menu selection
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
        echo -ne "  Enter number: "
        read -r answer
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
            MENU_RESULT="${options[$((answer-1))]}"
            MENU_IDX=$((answer-1))
            return 0
        fi
        warn "Invalid choice. Enter 1-${#options[@]}"
    done
}

# Generate random hex secret
gen_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 16
    elif [[ -r /dev/urandom ]]; then
        head -c 16 /dev/urandom | xxd -p | tr -d '\n'
    else
        die "Cannot generate random secret: openssl or /dev/urandom required"
    fi
}

# Validate hex string
is_hex32() { [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]; }

# Detect architecture
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) die "Unsupported architecture: $machine" ;;
    esac
}

# Detect libc
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

# Detect service manager
detect_service_manager() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        SVC_MGR="systemd"
    elif command -v rc-service &>/dev/null; then
        SVC_MGR="openrc"
    else
        SVC_MGR="none"
    fi
}

# Get latest release tag from GitHub
get_latest_version() {
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" | grep '"tag_name"' | cut -d'"' -f4
    elif command -v wget &>/dev/null; then
        wget -qO- "$url" | grep '"tag_name"' | cut -d'"' -f4
    else
        die "curl or wget is required"
    fi
}

# Download file
download() {
    local url="$1"
    local dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -qO "$dest" "$url"
    else
        die "curl or wget is required"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# PREFLIGHT CHECKS
# ──────────────────────────────────────────────────────────────────────────────
preflight() {
    step "Checking system requirements"

    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (or with sudo)"
    fi

    for cmd in grep sed awk cut tr head; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
    ok "Running as root"

    detect_arch
    ok "Architecture: ${ARCH}"

    detect_libc
    ok "C library: ${LIBC}"

    detect_service_manager
    ok "Service manager: ${SVC_MGR}"
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 1 — INSTALLATION METHOD & VERSION
# ──────────────────────────────────────────────────────────────────────────────
step_method() {
    step "Installation method"
    hr

    menu "How would you like to install Telemt?" \
        "Binary (download pre-built release) [recommended]" \
        "Docker / docker-compose" \
        "Uninstall existing installation" \
        "Purge (uninstall + remove all data & config)"

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
# STEP 2 — VERSION SELECTION
# ──────────────────────────────────────────────────────────────────────────────
step_version() {
    step "Version selection"
    hr

    info "Fetching latest release version..."
    LATEST_VER="$(get_latest_version || echo '')"
    if [[ -z "$LATEST_VER" ]]; then
        warn "Could not fetch latest version from GitHub"
        LATEST_VER="latest"
    else
        ok "Latest release: ${LATEST_VER}"
    fi

    ask "Version to install (leave empty for latest)" "$LATEST_VER" SELECTED_VERSION
    SELECTED_VERSION="${SELECTED_VERSION:-latest}"

    # Validate version format
    if [[ "$SELECTED_VERSION" != "latest" ]] && ! [[ "$SELECTED_VERSION" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        die "Invalid version format: ${SELECTED_VERSION}"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 3 — SERVER PORT & NETWORK
# ──────────────────────────────────────────────────────────────────────────────
step_server() {
    step "Server & Network configuration"
    hr

    ask "Server listen port" "443" SERVER_PORT
    [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) \
        || die "Invalid port: ${SERVER_PORT}"

    ask "Bind IPv4 address (0.0.0.0 = all interfaces)" "0.0.0.0" LISTEN_IPV4

    ask_yn "Enable IPv6 support?" "n" ENABLE_IPV6
    if [[ "$ENABLE_IPV6" == "true" ]]; then
        ask "Bind IPv6 address (:: = all interfaces)" "::" LISTEN_IPV6
    else
        LISTEN_IPV6="::"
    fi

    ask "Maximum concurrent connections (0 = unlimited)" "10000" MAX_CONNECTIONS

    ask_yn "Enable PROXY protocol (for HAProxy / Nginx reverse proxy)?" "n" PROXY_PROTOCOL
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 4 — PROXY MODES
# ──────────────────────────────────────────────────────────────────────────────
step_modes() {
    step "Proxy modes"
    hr
    info "You can enable one or more modes simultaneously."
    info "TLS mode is recommended for censorship bypass."

    ask_yn "Enable TLS mode (recommended, anti-censorship)" "y" MODE_TLS
    ask_yn "Enable Secure mode" "n" MODE_SECURE
    ask_yn "Enable Classic mode (legacy MTProxy compatibility)" "n" MODE_CLASSIC

    if [[ "$MODE_TLS" == "false" && "$MODE_SECURE" == "false" && "$MODE_CLASSIC" == "false" ]]; then
        warn "No modes enabled — defaulting to TLS mode"
        MODE_TLS="true"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 5 — ANTI-CENSORSHIP (TLS MASKING)
# ──────────────────────────────────────────────────────────────────────────────
step_censorship() {
    step "Anti-censorship / TLS masking"
    hr
    info "TLS masking makes the proxy look like regular HTTPS traffic."
    info "The TLS domain is used as the SNI hostname for camouflage."

    ask "TLS masking domain (any valid HTTPS domain)" "petrovich.ru" TLS_DOMAIN

    ask_yn "Enable masking (forward unknown TLS connections to real server)?" "y" MASK_ENABLED
    ask_yn "Enable TLS emulation (mimic real TLS server behaviour)?" "y" TLS_EMULATION

    if [[ "$MASK_ENABLED" == "true" ]]; then
        info "Mask host defaults to TLS domain if left empty"
        ask "Mask host override (leave empty = same as TLS domain)" "" MASK_HOST
    fi

    info ""
    info "unknown_sni_action controls what happens when an unknown SNI arrives:"
    menu "Unknown SNI action:" "drop (close connection)" "mask (forward to real server)"
    case "$MENU_IDX" in
        0) UNKNOWN_SNI="drop" ;;
        1) UNKNOWN_SNI="mask" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 6 — MIDDLE PROXY (ME TRANSPORT)
# ──────────────────────────────────────────────────────────────────────────────
step_middle_proxy() {
    step "Middle-End (ME) transport"
    hr
    info "Middle proxy enables full MTProto over the official Telegram relay network."
    info "Disable only if you need direct-DC mode."

    ask_yn "Enable middle proxy (ME transport)?" "y" USE_MIDDLE_PROXY

    if [[ "$USE_MIDDLE_PROXY" == "true" ]]; then
        ask_yn "Enable fast mode (optimized throughput)?" "n" FAST_MODE
        ask_yn "Prefer IPv6 for upstream connections?" "n" PREFER_IPV6

        info ""
        info "Pool size controls how many ME writer connections are maintained."
        ask "ME writer pool size" "8" ME_POOL_SIZE
        ask "ME warm standby connections" "16" ME_WARM_STANDBY
    else
        FAST_MODE="false"
        PREFER_IPV6="false"
        ME_POOL_SIZE="8"
        ME_WARM_STANDBY="16"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 7 — USERS & SECRETS
# ──────────────────────────────────────────────────────────────────────────────
step_users() {
    step "User access configuration"
    hr
    info "Each user gets a unique 32-character hex secret."
    info "Users connect with: tg://proxy?server=HOST&port=PORT&secret=SECRET"

    USERS=()

    while true; do
        echo ""
        DEFAULT_NAME="user$((${#USERS[@]} + 1))"
        ask "Username" "$DEFAULT_NAME" U_NAME

        ask_yn "Auto-generate secret for '${U_NAME}'?" "y" AUTO_SECRET
        if [[ "$AUTO_SECRET" == "true" ]]; then
            U_SECRET="$(gen_secret)"
            ok "Generated secret: ${U_SECRET}"
        else
            while true; do
                ask "Secret (32 hex chars)" "" U_SECRET
                if is_hex32 "$U_SECRET"; then break; fi
                warn "Secret must be exactly 32 hexadecimal characters"
            done
        fi

        USERS+=("${U_NAME}:${U_SECRET}")

        ask_yn "Add another user?" "n" ADD_MORE
        [[ "$ADD_MORE" == "false" ]] && break
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 8 — PUBLIC LINKS
# ──────────────────────────────────────────────────────────────────────────────
step_links() {
    step "Public connection links"
    hr
    info "These settings control the tg:// links shown after startup."
    info "Leave public_host empty to auto-detect your server IP."

    ask "Public hostname or IP for proxy links (empty = auto-detect)" "" PUBLIC_HOST
    if [[ -n "$PUBLIC_HOST" ]]; then
        ask "Public port override for links" "$SERVER_PORT" PUBLIC_PORT
    else
        PUBLIC_PORT="$SERVER_PORT"
    fi

    info ""
    info "show_link controls which users get their link displayed."
    menu "Show proxy links for:" \
        "All users (*)" \
        "No users (empty list)" \
        "Specific users (enter names)"

    case "$MENU_IDX" in
        0) SHOW_LINK='"*"' ;;
        1) SHOW_LINK='[]' ;;
        2)
            ask "Comma-separated usernames to show links for" "" LINK_USERS
            # Convert to TOML array format
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
# STEP 9 — AD TAG (SPONSORED CHANNEL)
# ──────────────────────────────────────────────────────────────────────────────
step_adtag() {
    step "Sponsored channel (ad_tag)"
    hr
    info "If you have a Telegram channel, you can monetise your proxy."
    info "Get your ad_tag from @MTProxybot on Telegram."

    ask_yn "Configure a sponsored channel ad_tag?" "n" WANT_ADTAG
    if [[ "$WANT_ADTAG" == "true" ]]; then
        while true; do
            ask "Ad tag (32 hex chars from @MTProxybot)" "" AD_TAG
            if is_hex32 "$AD_TAG"; then break; fi
            warn "Ad tag must be exactly 32 hexadecimal characters"
        done
    else
        AD_TAG=""
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 10 — API & METRICS
# ──────────────────────────────────────────────────────────────────────────────
step_api() {
    step "Admin API & Metrics"
    hr
    info "The admin REST API allows runtime management (add/remove users, stats, etc.)."
    info "It should only be accessible from localhost or trusted networks."

    ask_yn "Enable admin REST API?" "y" API_ENABLED
    if [[ "$API_ENABLED" == "true" ]]; then
        ask "API listen address:port" "127.0.0.1:9091" API_LISTEN
        ask "API whitelist CIDRs (comma-separated)" "127.0.0.0/8" API_WHITELIST_RAW

        ask_yn "Enable read-only API mode?" "n" API_READONLY
        ask_yn "Require Authorization header?" "n" API_AUTH
        if [[ "$API_AUTH" == "true" ]]; then
            ask "Authorization header value (e.g. Bearer mysecrettoken)" "" API_AUTH_HEADER
        else
            API_AUTH_HEADER=""
        fi
    fi

    echo ""
    ask_yn "Enable Prometheus metrics endpoint?" "n" METRICS_ENABLED
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        ask "Metrics listen address:port" "127.0.0.1:9090" METRICS_LISTEN
        ask "Metrics whitelist CIDRs (comma-separated)" "127.0.0.1/32,::1/128" METRICS_WHITELIST_RAW
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 11 — LOGGING
# ──────────────────────────────────────────────────────────────────────────────
step_logging() {
    step "Logging"
    hr

    menu "Log level:" "normal" "verbose" "debug" "silent"
    LOG_LEVEL="$MENU_RESULT"

    ask_yn "Disable ANSI colors in logs?" "n" NO_COLORS
    ask_yn "Enable per-IP observation / analytics (beobachten)?" "y" BEOBACHTEN

    if [[ "$BEOBACHTEN" == "true" ]]; then
        ask "Observation retention window (minutes)" "10" BEOB_MINUTES
        ask "Observation flush interval (seconds)" "15" BEOB_FLUSH
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 12 — TIMEOUTS
# ──────────────────────────────────────────────────────────────────────────────
step_timeouts() {
    step "Timeouts"
    hr
    info "These control connection and idle behaviour."

    ask_yn "Customise timeout settings?" "n" CUSTOM_TIMEOUTS
    if [[ "$CUSTOM_TIMEOUTS" == "true" ]]; then
        ask "Client handshake timeout (seconds)" "30" TO_HANDSHAKE
        ask "Client keepalive interval (seconds)" "15" TO_KEEPALIVE
        ask "Relay idle soft threshold (seconds)" "120" TO_IDLE_SOFT
        ask "Relay idle hard threshold (seconds)" "360" TO_IDLE_HARD
        ask "Upstream connect timeout (seconds)" "10" TO_UPSTREAM
    else
        TO_HANDSHAKE="30"
        TO_KEEPALIVE="15"
        TO_IDLE_SOFT="120"
        TO_IDLE_HARD="360"
        TO_UPSTREAM="10"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 13 — ADVANCED / OPTIONAL
# ──────────────────────────────────────────────────────────────────────────────
step_advanced() {
    step "Advanced options"
    hr

    ask_yn "Configure advanced options?" "n" WANT_ADVANCED
    if [[ "$WANT_ADVANCED" == "false" ]]; then
        # Set defaults
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

    info "Network preferences:"
    menu "Prefer IP family for upstream connections:" "IPv4 (4)" "IPv6 (6)"
    PREFER_NET=$((MENU_IDX == 0 ? 4 : 6))

    ask_yn "Enable multipath (experimental)?" "n" NET_MULTIPATH
    ask_yn "Enable STUN for NAT IP detection?" "y" STUN_ENABLED

    echo ""
    info "ME writer pool floor mode:"
    menu "Pool floor mode:" "adaptive (auto-scale with traffic)" "static (fixed pool size)"
    ME_POOL_FLOOR="$([ "$MENU_IDX" -eq 0 ] && echo adaptive || echo static)"

    echo ""
    info "KDF policy controls cryptographic compatibility:"
    menu "ME SOCKS KDF policy:" "strict" "compat (wider compatibility)"
    ME_KDF_POLICY="$([ "$MENU_IDX" -eq 0 ] && echo strict || echo compat)"

    ask_yn "Enable hardswap (generation-based pool rotation)?" "y" HARDSWAP
    ask "Fast mode minimum TLS record size (0 = disabled)" "0" FAST_MODE_MIN_TLS
    ask "Unified config refresh interval (seconds)" "300" UPDATE_EVERY
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 14 — SERVICE CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
step_service() {
    step "Service configuration"
    hr

    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        ask "Docker Compose project directory" "/opt/telemt" DOCKER_DIR
        return
    fi

    if [[ "$SVC_MGR" == "none" ]]; then
        warn "No service manager detected. Telemt will be installed but not registered as a service."
        warn "Start manually with: ${INSTALL_DIR}/${BINARY_NAME} ${CONFIG_FILE}"
        ENABLE_SERVICE="false"
        return
    fi

    ask_yn "Register and enable telemt as a system service?" "y" ENABLE_SERVICE
    ask_yn "Start telemt service immediately after install?" "y" START_SERVICE

    ask "Install directory for binary" "/usr/bin" INSTALL_DIR
    ask "Configuration directory" "/etc/telemt" CONFIG_DIR
    ask "Data / working directory" "/var/lib/telemt" DATA_DIR
}

# ──────────────────────────────────────────────────────────────────────────────
# REVIEW & CONFIRM
# ──────────────────────────────────────────────────────────────────────────────
review() {
    step "Configuration summary"
    hr
    echo ""
    echo -e "  ${WHT}Install type      :${RST} ${INSTALL_TYPE}"
    echo -e "  ${WHT}Version           :${RST} ${SELECTED_VERSION}"

    if [[ "$INSTALL_TYPE" == "binary" ]]; then
        echo -e "  ${WHT}Binary path       :${RST} ${INSTALL_DIR}/${BINARY_NAME}"
        echo -e "  ${WHT}Config file       :${RST} ${CONFIG_FILE}"
        echo -e "  ${WHT}Data directory    :${RST} ${DATA_DIR}"
    fi

    echo -e "  ${WHT}Server port       :${RST} ${SERVER_PORT}"
    echo -e "  ${WHT}IPv4 bind         :${RST} ${LISTEN_IPV4}"
    echo -e "  ${WHT}IPv6 enabled      :${RST} ${ENABLE_IPV6}"
    echo -e "  ${WHT}Modes             :${RST} TLS=${MODE_TLS}  Secure=${MODE_SECURE}  Classic=${MODE_CLASSIC}"
    echo -e "  ${WHT}TLS domain        :${RST} ${TLS_DOMAIN}"
    echo -e "  ${WHT}Masking           :${RST} ${MASK_ENABLED}"
    echo -e "  ${WHT}Middle proxy (ME) :${RST} ${USE_MIDDLE_PROXY}"
    echo -e "  ${WHT}Log level         :${RST} ${LOG_LEVEL}"

    echo ""
    echo -e "  ${WHT}Users:${RST}"
    for u in "${USERS[@]}"; do
        local name="${u%%:*}"
        local secret="${u##*:}"
        echo -e "    ${CYN}${name}${RST}  →  ${DIM}${secret}${RST}"
    done

    if [[ -n "$AD_TAG" ]]; then
        echo -e "  ${WHT}Ad tag            :${RST} ${AD_TAG}"
    fi

    if [[ "$API_ENABLED" == "true" ]]; then
        echo -e "  ${WHT}API               :${RST} ${API_LISTEN}"
    fi
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        echo -e "  ${WHT}Metrics           :${RST} ${METRICS_LISTEN}"
    fi

    echo ""
    hr
    ask_yn "Proceed with installation?" "y" CONFIRMED
    [[ "$CONFIRMED" == "false" ]] && die "Installation cancelled."
}

# ──────────────────────────────────────────────────────────────────────────────
# GENERATE config.toml
# ──────────────────────────────────────────────────────────────────────────────
generate_config() {
    # Build API whitelist TOML array
    local api_wl_toml=""
    if [[ "$API_ENABLED" == "true" ]]; then
        IFS=',' read -ra wl_arr <<< "${API_WHITELIST_RAW:-127.0.0.0/8}"
        for cidr in "${wl_arr[@]}"; do
            cidr="$(echo "$cidr" | xargs)"
            api_wl_toml="${api_wl_toml}\"${cidr}\", "
        done
        api_wl_toml="[${api_wl_toml%, }]"
    fi

    # Build metrics whitelist TOML array
    local metrics_wl_toml=""
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        IFS=',' read -ra mwl_arr <<< "${METRICS_WHITELIST_RAW:-127.0.0.1/32}"
        for cidr in "${mwl_arr[@]}"; do
            cidr="$(echo "$cidr" | xargs)"
            metrics_wl_toml="${metrics_wl_toml}\"${cidr}\", "
        done
        metrics_wl_toml="[${metrics_wl_toml%, }]"
    fi

    # Build TLS domains list
    local extra_domains=""
    [[ -n "$TLS_DOMAIN" ]] && extra_domains="tls_domains = []"

    # Build MASK HOST
    local mask_host_line=""
    [[ -n "${MASK_HOST:-}" ]] && mask_host_line="mask_host = \"${MASK_HOST}\""

    # Build public host lines
    local pub_host_line=""
    local pub_port_line=""
    [[ -n "${PUBLIC_HOST:-}" ]] && pub_host_line="public_host = \"${PUBLIC_HOST}\""
    [[ -n "${PUBLIC_PORT:-}" ]] && pub_port_line="public_port = ${PUBLIC_PORT}"

    # Build ad_tag line
    local adtag_line=""
    [[ -n "${AD_TAG:-}" ]] && adtag_line="ad_tag = \"${AD_TAG}\""

    # Auth header line
    local auth_header_line=""
    [[ -n "${API_AUTH_HEADER:-}" ]] && auth_header_line="auth_header = \"${API_AUTH_HEADER}\""

    CONFIG_CONTENT="# =============================================================================
# Telemt MTProto Proxy Configuration
# Generated by install_telemt.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Full reference: https://github.com/telemt/telemt/blob/main/docs/CONFIG_PARAMS.en.md
# =============================================================================

# Link visibility — which users see their tg:// link on startup
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
$([ -n "$adtag_line" ] && echo "$adtag_line")
$([ -n "$adtag_line" ] || echo "# ad_tag = \"\"  # Uncomment and set your 32-char hex tag from @MTProxybot")

# Middle-End pool
middle_proxy_pool_size  = ${ME_POOL_SIZE}
middle_proxy_warm_standby = ${ME_WARM_STANDBY}
me_floor_mode           = \"${ME_POOL_FLOOR:-adaptive}\"
me_socks_kdf_policy     = \"${ME_KDF_POLICY:-strict}\"

# =============================================================================
[general.modes]
# =============================================================================

classic = ${MODE_CLASSIC}
secure  = ${MODE_SECURE}
tls     = ${MODE_TLS}

# =============================================================================
[general.links]
# =============================================================================

$([ -n "$pub_host_line" ] && echo "$pub_host_line" || echo "# public_host = \"your.server.ip\"")
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

ipv4       = true
ipv6       = ${ENABLE_IPV6}
prefer     = ${PREFER_NET:-4}
multipath  = ${NET_MULTIPATH:-false}
stun_use   = ${STUN_ENABLED:-true}

# =============================================================================
[server]
# =============================================================================

port              = ${SERVER_PORT}
listen_addr_ipv4  = \"${LISTEN_IPV4}\"
$([ "$ENABLE_IPV6" == "true" ] && echo "listen_addr_ipv6  = \"${LISTEN_IPV6}\"" || echo "# listen_addr_ipv6 = \"::\"")
proxy_protocol    = ${PROXY_PROTOCOL}
max_connections   = ${MAX_CONNECTIONS}

$([ "$METRICS_ENABLED" == "true" ] && echo "metrics_listen    = \"${METRICS_LISTEN}\"" || echo "# metrics_listen = \"127.0.0.1:9090\"")
$([ "$METRICS_ENABLED" == "true" ] && echo "metrics_whitelist = ${metrics_wl_toml}" || echo "# metrics_whitelist = [\"127.0.0.1/32\"]")

# =============================================================================
[server.api]
# =============================================================================

enabled        = ${API_ENABLED}
$([ "$API_ENABLED" == "true" ] && echo "listen         = \"${API_LISTEN}\"" || echo "# listen = \"127.0.0.1:9091\"")
$([ "$API_ENABLED" == "true" ] && echo "whitelist      = ${api_wl_toml}" || echo "# whitelist = [\"127.0.0.0/8\"]")
$([ "${API_READONLY:-false}" == "true" ] && echo "read_only      = true" || echo "read_only      = false")
$([ -n "$auth_header_line" ] && echo "$auth_header_line")
minimal_runtime_enabled  = true
minimal_runtime_cache_ttl_ms = 1000

# =============================================================================
[[server.listeners]]
# =============================================================================

ip = \"${LISTEN_IPV4}\"

# =============================================================================
[timeouts]
# =============================================================================

client_handshake           = ${TO_HANDSHAKE}
client_keepalive           = ${TO_KEEPALIVE}
relay_idle_policy_v2_enabled = true
relay_client_idle_soft_secs  = ${TO_IDLE_SOFT}
relay_client_idle_hard_secs  = ${TO_IDLE_HARD}
tg_connect                 = ${TO_UPSTREAM}

# =============================================================================
[censorship]
# =============================================================================

tls_domain       = \"${TLS_DOMAIN}\"
${extra_domains}
unknown_sni_action = \"${UNKNOWN_SNI}\"
mask             = ${MASK_ENABLED}
$([ -n "$mask_host_line" ] && echo "$mask_host_line")
tls_emulation    = ${TLS_EMULATION}
tls_front_dir    = \"tlsfront\"
mask_shape_hardening = true

# =============================================================================
[access]
# =============================================================================
"

    # Append each user
    for u in "${USERS[@]}"; do
        local uname="${u%%:*}"
        local usecret="${u##*:}"
        CONFIG_CONTENT+="
[[access.user]]
name   = \"${uname}\"
secret = \"${usecret}\"
"
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# INSTALL BINARY
# ──────────────────────────────────────────────────────────────────────────────
install_binary() {
    step "Downloading Telemt binary"
    hr

    # Resolve version
    local version="$SELECTED_VERSION"
    if [[ "$version" == "latest" ]]; then
        version="$(get_latest_version)" || die "Failed to fetch latest version"
    fi
    # Remove leading 'v' if present for archive naming
    local ver_clean="${version#v}"

    # Build asset name
    local asset="telemt-${ver_clean}-${ARCH}-unknown-linux-${LIBC}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/${version}/${asset}"

    info "Downloading: ${url}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" EXIT

    download "$url" "${tmpdir}/${asset}"
    ok "Downloaded ${asset}"

    info "Extracting..."
    tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}/"
    local extracted_bin
    extracted_bin="$(find "${tmpdir}" -type f -name "${BINARY_NAME}" | head -1)"
    [[ -z "$extracted_bin" ]] && die "Binary not found in archive"

    install -Dm755 "$extracted_bin" "${INSTALL_DIR}/${BINARY_NAME}"
    ok "Installed: ${INSTALL_DIR}/${BINARY_NAME}"

    # Grant capability to bind low ports without root
    if command -v setcap &>/dev/null; then
        setcap cap_net_bind_service+eip "${INSTALL_DIR}/${BINARY_NAME}"
        ok "Set CAP_NET_BIND_SERVICE capability"
    else
        warn "setcap not found — you may need root to bind port ${SERVER_PORT}"
        warn "Install libcap2-bin (Debian/Ubuntu) or libcap (RHEL/Alpine)"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# CREATE USER, DIRS, CONFIG
# ──────────────────────────────────────────────────────────────────────────────
setup_environment() {
    step "Setting up user, directories and configuration"
    hr

    # Create user/group
    if ! getent group "$SERVICE_GROUP" &>/dev/null; then
        groupadd --system "$SERVICE_GROUP"
        ok "Created group: ${SERVICE_GROUP}"
    fi
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd --system --gid "$SERVICE_GROUP" \
            --no-create-home --shell /sbin/nologin \
            --home-dir "$DATA_DIR" "$SERVICE_USER"
        ok "Created user: ${SERVICE_USER}"
    fi

    # Create directories
    install -dm750 "$CONFIG_DIR"
    install -dm750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$DATA_DIR"
    install -dm750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "${DATA_DIR}/cache"
    install -dm750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "${DATA_DIR}/tlsfront"
    ok "Created directories"

    # Write config
    generate_config
    echo "$CONFIG_CONTENT" > "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    chown root:"$SERVICE_GROUP" "$CONFIG_FILE"
    ok "Config written: ${CONFIG_FILE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# SYSTEMD SERVICE
# ──────────────────────────────────────────────────────────────────────────────
install_systemd() {
    step "Installing systemd service"
    hr

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Telemt MTProto Proxy
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
    ok "Systemd unit installed: ${SERVICE_FILE}"

    if [[ "${ENABLE_SERVICE:-true}" == "true" ]]; then
        systemctl enable telemt
        ok "Service enabled (auto-start on boot)"
    fi

    if [[ "${START_SERVICE:-true}" == "true" ]]; then
        systemctl start telemt
        sleep 1
        if systemctl is-active --quiet telemt; then
            ok "Service started successfully"
        else
            warn "Service failed to start. Check logs:"
            warn "  journalctl -u telemt -n 50 --no-pager"
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# OPENRC SERVICE
# ──────────────────────────────────────────────────────────────────────────────
install_openrc() {
    step "Installing OpenRC service"
    hr

    cat > "$OPENRC_FILE" << EOF
#!/sbin/openrc-run

name="telemt"
description="Telemt MTProto Proxy"
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
    ok "OpenRC service installed: ${OPENRC_FILE}"

    if [[ "${ENABLE_SERVICE:-true}" == "true" ]]; then
        rc-update add telemt default
        ok "Service enabled (auto-start)"
    fi

    if [[ "${START_SERVICE:-true}" == "true" ]]; then
        rc-service telemt start
        ok "Service started"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# DOCKER INSTALL
# ──────────────────────────────────────────────────────────────────────────────
install_docker() {
    step "Setting up Docker deployment"
    hr

    command -v docker &>/dev/null || die "Docker is not installed. Install Docker first: https://docs.docker.com/engine/install/"
    command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1 \
        || warn "docker compose plugin not found — trying docker-compose command"

    mkdir -p "${DOCKER_DIR}"
    generate_config
    echo "$CONFIG_CONTENT" > "${DOCKER_DIR}/config.toml"
    chmod 644 "${DOCKER_DIR}/config.toml"
    ok "Config written: ${DOCKER_DIR}/config.toml"

    # Resolve tag
    local image_tag="latest"
    [[ "$SELECTED_VERSION" != "latest" ]] && image_tag="$SELECTED_VERSION"

    # Metrics port line (optional)
    local metrics_port_line=""
    [[ "$METRICS_ENABLED" == "true" ]] && metrics_port_line="      - \"127.0.0.1:9090:9090\""

    # API port line
    local api_port_line=""
    [[ "$API_ENABLED" == "true" ]] && api_port_line="      - \"127.0.0.1:9091:9091\""

    cat > "${DOCKER_DIR}/docker-compose.yml" << EOF
# Generated by install_telemt.sh
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

    ok "docker-compose.yml written: ${DOCKER_DIR}/docker-compose.yml"

    ask_yn "Start the container now?" "y" START_DOCKER
    if [[ "$START_DOCKER" == "true" ]]; then
        cd "${DOCKER_DIR}"
        if docker compose version &>/dev/null 2>&1; then
            docker compose up -d
        else
            docker-compose up -d
        fi
        ok "Container started"
    else
        info "Start manually: cd ${DOCKER_DIR} && docker compose up -d"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# PRINT PROXY LINKS
# ──────────────────────────────────────────────────────────────────────────────
print_links() {
    step "Proxy connection links"
    hr

    # Try to detect public IP if no public_host was set
    local host="${PUBLIC_HOST}"
    if [[ -z "$host" ]]; then
        if command -v curl &>/dev/null; then
            host="$(curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "")"
        fi
        [[ -z "$host" ]] && host="<YOUR_SERVER_IP>"
    fi

    local port="${PUBLIC_PORT:-$SERVER_PORT}"

    echo ""
    echo -e "  ${WHT}Share these links with your Telegram clients:${RST}"
    echo ""

    for u in "${USERS[@]}"; do
        local uname="${u%%:*}"
        local usecret="${u##*:}"

        # TLS mode secret prefix
        local tls_secret="ee${usecret}"

        echo -e "  ${CYN}── User: ${uname} ──${RST}"

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
    echo -e "  ${WHT}Useful commands:${RST}"
    if [[ "$INSTALL_TYPE" == "binary" ]]; then
        if [[ "$SVC_MGR" == "systemd" ]]; then
            echo -e "    Status : ${CYN}systemctl status telemt${RST}"
            echo -e "    Logs   : ${CYN}journalctl -u telemt -f${RST}"
            echo -e "    Restart: ${CYN}systemctl restart telemt${RST}"
            echo -e "    Stop   : ${CYN}systemctl stop telemt${RST}"
        elif [[ "$SVC_MGR" == "openrc" ]]; then
            echo -e "    Status : ${CYN}rc-service telemt status${RST}"
            echo -e "    Restart: ${CYN}rc-service telemt restart${RST}"
        fi
        echo -e "    Config : ${CYN}${CONFIG_FILE}${RST}"
    elif [[ "$INSTALL_TYPE" == "docker" ]]; then
        echo -e "    Status : ${CYN}cd ${DOCKER_DIR} && docker compose ps${RST}"
        echo -e "    Logs   : ${CYN}cd ${DOCKER_DIR} && docker compose logs -f${RST}"
        echo -e "    Restart: ${CYN}cd ${DOCKER_DIR} && docker compose restart${RST}"
    fi
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ──────────────────────────────────────────────────────────────────────────────
do_uninstall() {
    step "Uninstall"
    hr

    local is_purge="false"
    [[ "$INSTALL_TYPE" == "purge" ]] && is_purge="true"

    # Stop & disable service
    if command -v systemctl &>/dev/null && systemctl list-units --full -all 2>/dev/null | grep -q "telemt.service"; then
        systemctl stop telemt 2>/dev/null || true
        systemctl disable telemt 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        ok "Systemd service removed"
    fi
    if command -v rc-service &>/dev/null; then
        rc-service telemt stop 2>/dev/null || true
        rc-update del telemt 2>/dev/null || true
        rm -f "$OPENRC_FILE"
        ok "OpenRC service removed"
    fi

    # Remove binary
    rm -f "${INSTALL_DIR}/${BINARY_NAME}"
    ok "Binary removed"

    if [[ "$is_purge" == "true" ]]; then
        rm -rf "$CONFIG_DIR" "$DATA_DIR"
        ok "Config and data directories removed"

        if id "$SERVICE_USER" &>/dev/null; then
            userdel "$SERVICE_USER" 2>/dev/null || true
            ok "User '${SERVICE_USER}' removed"
        fi
        if getent group "$SERVICE_GROUP" &>/dev/null; then
            groupdel "$SERVICE_GROUP" 2>/dev/null || true
            ok "Group '${SERVICE_GROUP}' removed"
        fi
        ok "Purge complete"
    else
        ok "Uninstall complete (config and data preserved)"
        info "Config: ${CONFIG_FILE}"
        info "Data:   ${DATA_DIR}"
        info "To remove all data: re-run with Purge option"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
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
    review

    echo ""
    step "Installing"
    hr

    if [[ "$INSTALL_TYPE" == "binary" ]]; then
        install_binary
        setup_environment

        if [[ "$SVC_MGR" == "systemd" ]]; then
            install_systemd
        elif [[ "$SVC_MGR" == "openrc" ]]; then
            install_openrc
        else
            warn "No service manager — start manually:"
            warn "  sudo -u ${SERVICE_USER} ${INSTALL_DIR}/${BINARY_NAME} ${CONFIG_FILE}"
        fi

    elif [[ "$INSTALL_TYPE" == "docker" ]]; then
        install_docker
    fi

    print_links

    echo -e "\n  ${GRN}${BOLD}Installation complete!${RST}\n"
}

main "$@"
