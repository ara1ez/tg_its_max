#!/bin/bash
# ============================================================
#  MTProxy — Telegram Proxy
#  Установка и управление на Linux (Ubuntu/Debian/CentOS)
#  Использование: sudo bash install_mtproxy.sh [install|start|stop|status|link]
# ============================================================

set -e

INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="mtproxy"
PORT=8443              # Порт прокси (8443 — альтернативный HTTPS порт)
FAKE_TLS_DOMAIN="www.max.ru"  # Домен для маскировки FakeTLS (в белом списке провайдера)
TAG=""                 # Опционально: промо-тег Telegram (можно оставить пустым)

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

# ── Определяем ОС ─────────────────────────────────────────
detect_os() {
    if [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/redhat-release ]; then
        OS="redhat"
    else
        err "Неподдерживаемая ОС. Нужен Ubuntu/Debian или CentOS/RHEL."
    fi
}

# ── Зависимости ───────────────────────────────────────────
install_deps() {
    log "Устанавливаем зависимости..."
    if [ "$OS" = "debian" ]; then
        apt-get update -qq
        apt-get install -y git curl build-essential libssl-dev zlib1g-dev \
                           openssl wget net-tools 2>/dev/null
    else
        yum groupinstall -y "Development Tools"
        yum install -y openssl-devel git curl wget net-tools
    fi
}

# ── Клонируем и собираем MTProxy ──────────────────────────
build_mtproxy() {
    log "Скачиваем исходники MTProxy..."
    rm -rf "$INSTALL_DIR"
    git clone https://github.com/TelegramMessenger/MTProxy.git "$INSTALL_DIR"
    
    cd "$INSTALL_DIR"
    log "Компилируем MTProxy..."
    make -j"$(nproc)" 2>/dev/null
    
    if [ ! -f "$INSTALL_DIR/objs/bin/mtproto-proxy" ]; then
        err "Компиляция не удалась. Проверьте зависимости."
    fi
    log "MTProxy скомпилирован успешно!"
}

# ── Генерируем секрет и скачиваем конфиг ─────────────────
setup_config() {
    log "Генерируем случайный секрет..."
    SECRET=$(openssl rand -hex 16)
    
    log "Скачиваем актуальный список серверов Telegram..."
    curl -s https://core.telegram.org/getProxyConfig -o "$INSTALL_DIR/proxy-multi.conf"
    
    # Сохраняем секрет, порт и домен
    echo "$SECRET"           > "$INSTALL_DIR/secret.txt"
    echo "$PORT"             > "$INSTALL_DIR/port.txt"
    echo "$FAKE_TLS_DOMAIN"  > "$INSTALL_DIR/domain.txt"
    
    log "Секрет сгенерирован: ${GREEN}$SECRET${NC}"
}

# ── Создаём systemd сервис ────────────────────────────────
create_service() {
    SECRET=$(cat "$INSTALL_DIR/secret.txt")
    PORT=$(cat "$INSTALL_DIR/port.txt")
    DOMAIN=$(cat "$INSTALL_DIR/domain.txt")
    
    TAG_PARAM=""
    [ -n "$TAG" ] && TAG_PARAM="-P $TAG"
    
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Telegram MTProxy
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStartPre=/bin/sh -c 'curl -s https://core.telegram.org/getProxyConfig -o ${INSTALL_DIR}/proxy-multi.conf'
ExecStart=${INSTALL_DIR}/objs/bin/mtproto-proxy \\
    -u nobody \\
    -p 8888 \\
    -H ${PORT} \\
    -S ${SECRET} \\
    -D ${DOMAIN} \\
    ${TAG_PARAM} \\
    --aes-pwd ${INSTALL_DIR}/proxy-multi.conf \\
    -M 1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
    log "Systemd сервис создан и включён в автозапуск"
}

# ── Открываем порт в firewall ─────────────────────────────
open_firewall() {
    PORT=$(cat "$INSTALL_DIR/port.txt")
    
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$PORT"/tcp
        log "UFW: порт $PORT открыт"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/tcp"
        firewall-cmd --reload
        log "firewalld: порт $PORT открыт"
    else
        warn "Firewall не обнаружен — убедись вручную что порт $PORT открыт"
    fi
}

# ── Получаем публичный IP ─────────────────────────────────
get_ip() {
    curl -s https://api.ipify.org 2>/dev/null || \
    curl -s https://ifconfig.me 2>/dev/null || \
    hostname -I | awk '{print $1}'
}

# ── Показываем ссылку для подключения ─────────────────────
show_link() {
    if [ ! -f "$INSTALL_DIR/secret.txt" ]; then
        err "MTProxy не установлен. Сначала запусти: $0 install"
    fi
    
    SECRET=$(cat "$INSTALL_DIR/secret.txt")
    PORT=$(cat "$INSTALL_DIR/port.txt")
    DOMAIN=$(cat "$INSTALL_DIR/domain.txt" 2>/dev/null || echo "")
    IP=$(get_ip)
    
    # ee-секрет = FakeTLS + random padding
    # Формат: ee + HEX(домен) + секрет
    DOMAIN_HEX=$(echo -n "$DOMAIN" | xxd -p | tr -d '\n')
    DOMAIN_LEN=$(printf '%02x' ${#DOMAIN})
    SECRET_EE="ee${DOMAIN_LEN}${DOMAIN_HEX}${SECRET}"
    
    LINK="https://t.me/proxy?server=${IP}&port=${PORT}&secret=${SECRET_EE}"
    
    echo ""
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  🔐 Твой Telegram MTProxy готов!${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}IP сервера:${NC}  $IP"
    echo -e "  ${YELLOW}Порт:${NC}        $PORT"
    echo -e "  ${YELLOW}Маскировка:${NC}  $DOMAIN"
    echo -e "  ${YELLOW}Секрет:${NC}      $SECRET_EE"
    echo ""
    echo -e "  ${GREEN}Ссылка для подключения:${NC}"
    echo -e "  ${BLUE}$LINK${NC}"
    echo ""
    echo -e "  Отправь эту ссылку в Telegram — она откроет"
    echo -e "  настройки прокси автоматически."
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo ""
}

# ── Статус ────────────────────────────────────────────────
show_status() {
    echo ""
    systemctl status ${SERVICE_NAME} --no-pager -l
    echo ""
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        PORT=$(cat "$INSTALL_DIR/port.txt" 2>/dev/null || echo "$PORT")
        CONNECTIONS=$(ss -tn | grep ":${PORT}" | wc -l)
        info "Активных подключений: $CONNECTIONS"
    fi
}

# ── Обновление конфига серверов Telegram ──────────────────
update_config() {
    log "Обновляем конфиг серверов Telegram..."
    curl -s https://core.telegram.org/getProxyConfig -o "$INSTALL_DIR/proxy-multi.conf"
    systemctl restart ${SERVICE_NAME}
    log "Конфиг обновлён, сервис перезапущен"
}

# ── Полная установка ──────────────────────────────────────
do_install() {
    echo ""
    info "Начинаем установку MTProxy для Telegram..."
    echo ""
    
    detect_os
    install_deps
    build_mtproxy
    setup_config
    create_service
    open_firewall
    
    systemctl start ${SERVICE_NAME}
    sleep 2
    
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        log "MTProxy запущен успешно!"
        show_link
    else
        err "MTProxy не запустился. Проверь: journalctl -u ${SERVICE_NAME} -n 50"
    fi
}

# ── Точка входа ───────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && err "Запускай от root: sudo bash $0 $1"

case "${1:-install}" in
    install) do_install ;;
    start)   systemctl start  ${SERVICE_NAME} && log "Запущен" ;;
    stop)    systemctl stop   ${SERVICE_NAME} && log "Остановлен" ;;
    restart) systemctl restart ${SERVICE_NAME} && log "Перезапущен" ;;
    status)  show_status ;;
    link)    show_link ;;
    update)  update_config ;;
    *)
        echo "Использование: sudo bash $0 {install|start|stop|restart|status|link|update}"
        exit 1
        ;;
esac
