#!/bin/bash
# Install powerfail-proxmox.sh on Proxmox host
# Usage: bash <(curl -sL ...)

REPO="https://github.com/akrhin/powerfail-shutdown"
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
echo "  powerfail-shutdown — установка на Proxmox"
echo "============================================"
echo ""

[ "$(id -u)" -ne 0 ] && { err "Запусти от root."; exit 1; }
! command -v qm &>/dev/null && { err "Это не Proxmox (qm не найден)"; exit 1; }

# Выбираем загрузчик: wget надёжнее, curl fallback
DL=""
if command -v wget &>/dev/null; then
    DL="wget -q -O"
elif command -v curl &>/dev/null; then
    DL="curl -sL --connect-timeout 10 --max-time 30 -o"
else
    err "Ни wget, ни curl не найдены"
    exit 1
fi

echo "Скачиваю файлы..."

for pair in "$SCRIPT:$BIN_DIR/$SCRIPT" "$SERVICE:$SERVICE_DIR/$SERVICE" "$TIMER:$SERVICE_DIR/$TIMER" "powerfail.conf.example:$SERVICE_DIR/powerfail.conf.example"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if ! $DL "$dst" "$RAW/$src"; then
        err "Не удалось скачать $src"
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
    ok "Создан $CONFIG_DIR/powerfail.conf — заполни TG_BOT_TOKEN и TG_CHAT_ID"
fi

# --- Параметры ---
echo ""
echo "Параметры по умолчанию:"
echo "   ROUTER       = 192.168.1.1  (роутер НЕ в ИБП)"
echo "   THRESHOLD    = 3            (провалов пинга до shutdown)"
echo "   XPENOLOGY    = 100          (VM ID)"
echo "   FSCT         = 107          (CT ID)"
echo "   CHECK_EVERY  = 30 сек       (systemd timer)"
echo ""

# --- Активация таймера ---
systemctl daemon-reload
systemctl stop "$SERVICE" 2>/dev/null
systemctl disable "$SERVICE" 2>/dev/null

systemctl enable "$TIMER" 2>/dev/null && ok "Таймер добавлен в автозагрузку" || err "Не удалось включить таймер"
systemctl start "$TIMER" 2>/dev/null && ok "Таймер запущен" || err "Не удалось запустить таймер"

# Первый запуск
systemctl start "$SERVICE" 2>/dev/null &
sleep 1

echo ""
systemctl status "$TIMER" --no-pager -l 2>&1 | head -5

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
echo "  Таймер:"
echo "    systemctl status $TIMER"
echo ""
echo "  Telegram: настроить $CONFIG_DIR/powerfail.conf"
echo ""
echo "  Подробнее: $REPO"
echo ""
