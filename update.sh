#!/bin/bash
# Update powerfail-proxmox.sh from GitHub
# Usage: bash update.sh

RAW="https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main"

BIN_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"

SCRIPT="powerfail-proxmox.sh"
SERVICE="powerfail-proxmox.service"
TIMER="powerfail-proxmox.timer"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok(){ echo -e "  ${GREEN}✅${NC} $1"; }
warn(){ echo -e "  ${YELLOW}⚠️ $1${NC}"; }
err(){ echo -e "  ${RED}❌${NC} $1"; }

echo ""
echo "============================================"
echo "  powerfail-shutdown — обновление"
echo "============================================"
echo ""

[ "$(id -u)" -ne 0 ] && { err "Запусти от root."; exit 1; }

# --- Резервная копия ---
if [ -f "$BIN_DIR/$SCRIPT" ]; then
    BACKUP="$BIN_DIR/$SCRIPT.bak.$(date +%Y%m%d%H%M%S)"
    cp "$BIN_DIR/$SCRIPT" "$BACKUP"
    ok "Резервная копия: $BACKUP"
fi

# --- Скачивание ---
for pair in "$SCRIPT:$BIN_DIR/$SCRIPT" "$SERVICE:$SERVICE_DIR/$SERVICE" "$TIMER:$SERVICE_DIR/$TIMER"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if ! curl -sL --connect-timeout 10 --max-time 30 "$RAW/$src" -o "$dst"; then
        err "Не удалось скачать $src"
        if [ -n "$BACKUP" ] && [ "$src" = "$SCRIPT" ]; then
            cp "$BACKUP" "$BIN_DIR/$SCRIPT"
            ok "Откат до резервной копии"
        fi
        exit 1
    fi
    chmod +x "$dst" 2>/dev/null
    ok "$dst"
done

# --- Применение ---
systemctl daemon-reload

# Если был старый сервис (Type=simple) — глушим и переключаем на timer
if systemctl is-active "$SERVICE" &>/dev/null; then
    systemctl stop "$SERVICE"
    systemctl disable "$SERVICE" 2>/dev/null
fi

# Включаем timer если ещё не включён
if ! systemctl is-enabled "$TIMER" &>/dev/null; then
    systemctl enable "$TIMER"
fi
systemctl restart "$TIMER" 2>/dev/null

sleep 1

if systemctl is-active "$TIMER" &>/dev/null; then
    ok "Таймер работает"
else
    err "Таймер не запустился"
fi

echo ""
echo "============================================"
echo "  Обновление завершено!"
echo "============================================"
echo ""
echo "  Таймер:"
echo "    systemctl status $TIMER"
echo ""
echo "  Логи:"
echo "    journalctl -u $SERVICE -f"
echo ""
