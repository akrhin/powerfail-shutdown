#!/bin/bash
# ==============================================================
# Update powerfail-proxmox.sh на Proxmox хосте из GitHub
# Usage: sudo bash update.sh
# ==============================================================

set -e

RAW_BASE="https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main"

BIN_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"

SCRIPT="powerfail-proxmox.sh"
SERVICE="powerfail-proxmox.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()  { echo -e "  ${GREEN}✅${NC} $1"; }
warn(){ echo -e "  ${YELLOW}⚠️ $1${NC}"; }
err() { echo -e "  ${RED}❌${NC} $1"; }

echo ""
echo "============================================"
echo "  powerfail-shutdown — обновление"
echo "============================================"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    err "Запусти от root: sudo bash update.sh"
    exit 1
fi

# --- Резервное копирование текущей конфигурации ---
if [ -f "$BIN_DIR/$SCRIPT" ]; then
    BACKUP="$BIN_DIR/$SCRIPT.bak.$(date +%Y%m%d%H%M%S)"
    cp "$BIN_DIR/$SCRIPT" "$BACKUP"
    ok "Сохранена резервная копия: $BACKUP"
fi

# --- Скачивание свежей версии ---
echo "📥 Скачиваю $SCRIPT..."
if ! curl -sL "$RAW_BASE/$SCRIPT" -o "$BIN_DIR/$SCRIPT"; then
    err "Не удалось скачать $SCRIPT"
    exit 1
fi
chmod +x "$BIN_DIR/$SCRIPT"
ok "Скрипт обновлён: $BIN_DIR/$SCRIPT"

# --- Скачивание systemd unit ---
echo "📥 Скачиваю $SERVICE..."
if ! curl -sL "$RAW_BASE/$SERVICE" -o "$SERVICE_DIR/$SERVICE"; then
    warn "Не удалось скачать $SERVICE (может не изменился)"
fi
ok "Unit обновлён: $SERVICE_DIR/$SERVICE"

# --- Применение изменений ---
systemctl daemon-reload

if systemctl is-active "$SERVICE" &>/dev/null; then
    systemctl restart "$SERVICE"
    ok "Сервис перезапущен"
    sleep 1

    if systemctl is-active "$SERVICE" &>/dev/null; then
        ok "Сервис работает: $(systemctl is-active "$SERVICE")"
    else
        err "Сервис не запустился. Откат..."
        if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
            cp "$BACKUP" "$BIN_DIR/$SCRIPT"
            chmod +x "$BIN_DIR/$SCRIPT"
            systemctl restart "$SERVICE"
            ok "Откат до предыдущей версии выполнен"
        fi
    fi
else
    warn "Сервис не был запущен. Запускаю..."
    systemctl start "$SERVICE"
fi

echo ""
echo "============================================"
echo "  Обновление завершено!"
echo "============================================"
echo ""
echo "  Текущая версия: $(head -5 "$BIN_DIR/$SCRIPT" | grep -i 'версия\|version' | head -1)"
echo ""
echo "  Логи:"
echo "    journalctl -u $SERVICE -f"
echo ""
