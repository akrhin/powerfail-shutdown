#!/bin/bash
# Update powerfail-proxmox.sh from GitHub
# Usage: bash update.sh

RAW="https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main"

BIN_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/powerfail"

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

# Выбираем загрузчик
DL=""
if command -v wget &>/dev/null; then
    DL="wget -q -O"
elif command -v curl &>/dev/null; then
    DL="curl -sL --connect-timeout 10 --max-time 30 -o"
else
    err "Ни wget, ни curl не найдены"
    exit 1
fi

# --- Резервная копия ---
if [ -f "$BIN_DIR/$SCRIPT" ]; then
    BACKUP="$BIN_DIR/$SCRIPT.bak.$(date +%Y%m%d%H%M%S)"
    cp "$BIN_DIR/$SCRIPT" "$BACKUP"
    ok "Резервная копия: $BACKUP"
fi

# --- Скачивание ---
for pair in "$SCRIPT:$BIN_DIR/$SCRIPT" "$SERVICE:$SERVICE_DIR/$SERVICE" "$TIMER:$SERVICE_DIR/$TIMER" "powerfail.conf.example:$SERVICE_DIR/powerfail.conf.example"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if ! $DL "$dst" "$RAW/$src"; then
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

# --- Конфиг (если не существует) ---
if [ ! -f "$CONFIG_DIR/powerfail.conf" ]; then
    mkdir -p "$CONFIG_DIR"
    cp "$SERVICE_DIR/powerfail.conf.example" "$CONFIG_DIR/powerfail.conf" 2>/dev/null
    chmod 600 "$CONFIG_DIR/powerfail.conf" 2>/dev/null
    ok "Создан $CONFIG_DIR/powerfail.conf"
fi

# --- Применение ---
systemctl daemon-reload
if systemctl is-active "$SERVICE" &>/dev/null; then
    systemctl stop "$SERVICE"
    systemctl disable "$SERVICE" 2>/dev/null
fi

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
echo "  systemctl status $TIMER"
echo "  journalctl -u $SERVICE -f"
echo ""
