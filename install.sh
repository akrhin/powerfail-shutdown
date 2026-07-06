#!/bin/bash
# ==============================================================
# Install powerfail-proxmox.sh on Proxmox host
# Usage: curl -sL https://git.io/... | bash
#    or: bash install.sh
# ==============================================================

set -e

REPO="https://github.com/akrhin/powerfail-shutdown"
RAW_BASE="https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main"

BIN_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"

SCRIPT="powerfail-proxmox.sh"
SERVICE="powerfail-proxmox.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ok()  { echo -e "  ${GREEN}✅${NC} $1"; }
warn(){ echo -e "  ${YELLOW}⚠️ $1${NC}"; }
err() { echo -e "  ${RED}❌${NC} $1"; }

echo ""
echo "============================================"
echo "  powerfail-shutdown — установка на Proxmox"
echo "============================================"
echo ""

# --- Проверка: запущен ли скрипт на Proxmox ---
if ! command -v qm &>/dev/null || ! command -v pct &>/dev/null; then
    err "Это не Proxmox (qm/pct не найдены). Установка прервана."
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    err "Запусти от root: sudo bash install.sh"
    exit 1
fi

# --- Скачивание скрипта ---
echo "📥 Скачиваю $SCRIPT..."
if ! curl -sL "$RAW_BASE/$SCRIPT" -o "$BIN_DIR/$SCRIPT"; then
    err "Не удалось скачать $SCRIPT"
    exit 1
fi
chmod +x "$BIN_DIR/$SCRIPT"
ok "Скрипт установлен: $BIN_DIR/$SCRIPT"

# --- Скачивание systemd unit ---
echo "📥 Скачиваю $SERVICE..."
if ! curl -sL "$RAW_BASE/$SERVICE" -o "$SERVICE_DIR/$SERVICE"; then
    err "Не удалось скачать $SERVICE"
    exit 1
fi
ok "Unit установлен: $SERVICE_DIR/$SERVICE"

# --- Настройка параметров ---
echo ""
echo "⚙️  Параметры по умолчанию:"
echo "   ROUTER       = 192.168.1.1  (роутер НЕ в ИБП)"
echo "   THRESHOLD    = 3            (провалов пинга до shutdown)"
echo "   XPENOLOGY    = 100          (VM ID)"
echo "   FSCT         = 107          (CT ID)"
echo ""
echo "   Чтобы изменить — отредактируй переменные в начале"
echo "   $BIN_DIR/$SCRIPT"

# --- Активация сервиса ---
echo ""
systemctl daemon-reload

if systemctl is-enabled "$SERVICE" &>/dev/null; then
    ok "Сервис уже включён в автозагрузку"
else
    systemctl enable "$SERVICE"
    ok "Сервис добавлен в автозагрузку"
fi

if systemctl is-active "$SERVICE" &>/dev/null; then
    warn "Сервис уже запущен. Перезапускаю..."
    systemctl restart "$SERVICE"
    ok "Сервис перезапущен"
else
    systemctl start "$SERVICE"
    ok "Сервис запущен"
fi

# --- Проверка ---
sleep 1
if systemctl is-active "$SERVICE" &>/dev/null; then
    ok "Сервис работает: $(systemctl is-active "$SERVICE")"
else
    err "Сервис не запустился. Лог: journalctl -u $SERVICE -n 20 --no-pager"
fi

echo ""
echo "============================================"
echo "  Установка завершена!"
echo "============================================"
echo ""
echo "  Тестирование:"
echo "    $BIN_DIR/$SCRIPT test-network"
echo "    $BIN_DIR/$SCRIPT --dry-run --debug"
echo ""
echo "  Логи:"
echo "    journalctl -u $SERVICE -f"
echo ""
echo "  Подробнее: $REPO"
echo ""
