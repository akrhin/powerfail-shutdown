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

DL=""
if command -v wget &>/dev/null; then
    DL="wget --retry-connrefused --timeout=15 -q -O"
elif command -v curl &>/dev/null; then
    DL="curl -sL --connect-timeout 15 --max-time 30 --retry 3 -o"
else
    err "Ни wget, ни curl не найдены"
    exit 1
fi

_dl() {
    local src="$1" dst="$2" i
    for i in 1 2 3; do
        $DL "$dst" "$RAW/$src" 2>/dev/null
        [ -s "$dst" ] && return 0
        [ $i -lt 3 ] && sleep 2
    done
    return 1
}

# --- Резервная копия ---
if [ -f "$BIN_DIR/$SCRIPT" ]; then
    BACKUP="$BIN_DIR/$SCRIPT.bak.$(date +%Y%m%d%H%M%S)"
    cp "$BIN_DIR/$SCRIPT" "$BACKUP"
    ok "Резервная копия: $BACKUP"
fi

# --- Скачивание ---
if _dl "$SCRIPT" "$BIN_DIR/$SCRIPT"; then
    chmod +x "$BIN_DIR/$SCRIPT"
    ok "скрипт"
else
    err "Не удалось скачать $SCRIPT"
    [ -n "$BACKUP" ] && cp "$BACKUP" "$BIN_DIR/$SCRIPT" && ok "откат"
    exit 1
fi

_dl "$SERVICE" "$SERVICE_DIR/$SERVICE" && ok "service" || warn "service не обновлён"

if _dl "$TIMER" "$SERVICE_DIR/$TIMER"; then
    ok "timer"
else
    warn "timer не скачался, создаю встроенный"
    cat > "$SERVICE_DIR/$TIMER" << 'TIMEREOF'
[Unit]
Description=UPS Power Failure Monitor (check router every 30s)
Requires=powerfail-proxmox.service

[Timer]
OnCalendar=*-*-* *:*:0/30
Persistent=false
AccuracySec=1

[Install]
WantedBy=timers.target
TIMEREOF
    ok "timer (встроенный)"
fi

_dl "powerfail.conf.example" "$SERVICE_DIR/powerfail.conf.example" || true

# --- Конфиг ---
if [ ! -f "$CONFIG_DIR/powerfail.conf" ]; then
    mkdir -p "$CONFIG_DIR"
    [ -f "$SERVICE_DIR/powerfail.conf.example" ] && cp "$SERVICE_DIR/powerfail.conf.example" "$CONFIG_DIR/powerfail.conf"
    chmod 600 "$CONFIG_DIR/powerfail.conf" 2>/dev/null
    ok "создан /etc/powerfail/powerfail.conf"
fi

# --- Применение ---
systemctl daemon-reload
systemctl stop "$SERVICE" 2>/dev/null
systemctl disable "$SERVICE" 2>/dev/null

systemctl enable "$TIMER" 2>/dev/null
systemctl restart "$TIMER" 2>/dev/null
sleep 1

if systemctl is-active "$TIMER" &>/dev/null; then
    ok "Таймер работает"
else
    err "Таймер не запустился"
fi

echo ""
echo "============================================"
echo "  Готово!"
echo "============================================"
echo ""
echo "  systemctl status $TIMER"
echo "  journalctl -u $SERVICE -f"
echo ""
