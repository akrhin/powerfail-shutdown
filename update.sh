#!/bin/bash
# ==============================================================
# Update powerfail-proxmox.sh на Proxmox хосте из GitHub
# Usage: bash update.sh
# ==============================================================

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
    err "Запусти от root."
    exit 1
fi

# --- Резервное копирование ---
if [ -f "$BIN_DIR/$SCRIPT" ]; then
    BACKUP="$BIN_DIR/$SCRIPT.bak.$(date +%Y%m%d%H%M%S)"
    cp "$BIN_DIR/$SCRIPT" "$BACKUP"
    ok "Сохранена резервная копия: $BACKUP"
else
    warn "Текущий скрипт не найден в $BIN_DIR. Будет выполнена чистая установка."
fi

# --- Скачивание скрипта ---
echo "📥 Скачиваю $SCRIPT..."
if ! curl -sL --connect-timeout 10 --max-time 30 "$RAW_BASE/$SCRIPT" -o "$BIN_DIR/$SCRIPT"; then
    err "Не удалось скачать $SCRIPT"
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$BIN_DIR/$SCRIPT"
        ok "Откат до резервной копии"
    fi
    exit 1
fi
chmod +x "$BIN_DIR/$SCRIPT"
ok "Скрипт обновлён"

# --- Скачивание systemd unit ---
echo "📥 Скачиваю $SERVICE..."
if curl -sL --connect-timeout 10 --max-time 15 "$RAW_BASE/$SERVICE" -o "$SERVICE_DIR/$SERVICE" 2>/dev/null; then
    ok "Unit обновлён"
else
    warn "Unit не скачался (возможно, не изменился на GitHub)"
fi

# --- Применение ---
systemctl daemon-reload

if systemctl is-active "$SERVICE" &>/dev/null; then
    echo "🔄 Перезапускаю сервис..."
    systemctl restart "$SERVICE" 2>/dev/null &
    sleep 2

    if systemctl is-active "$SERVICE" &>/dev/null; then
        ok "Сервис перезапущен и работает"
    else
        err "Сервис не запустился после обновления."
        if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
            echo "   Откатываю..."
            cp "$BACKUP" "$BIN_DIR/$SCRIPT"
            chmod +x "$BIN_DIR/$SCRIPT"
            systemctl restart "$SERVICE" 2>/dev/null &
            sleep 2
            if systemctl is-active "$SERVICE" &>/dev/null; then
                ok "Откат выполнен, сервис работает"
            fi
        fi
    fi
else
    warn "Сервис не был запущен. Запускаю..."
    systemctl start "$SERVICE" 2>/dev/null &
    sleep 2
    if systemctl is-active "$SERVICE" &>/dev/null; then
        ok "Сервис запущен"
    fi
fi

echo ""
echo "============================================"
echo "  Обновление завершено!"
echo "============================================"
echo ""
echo "  Текущая версия: $(head -5 "$BIN_DIR/$SCRIPT" | grep -iE 'версия|version' | head -1)"
echo ""
echo "  Логи:"
echo "    journalctl -u $SERVICE -f"
echo ""
