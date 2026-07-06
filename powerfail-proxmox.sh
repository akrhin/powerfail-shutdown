#!/bin/bash
# ==============================================================
# UPS Power Failure Shutdown — Proxmox
#
# Запускается systemd-таймером раз в 30 секунд.
#
# Детекция: Home Assistant (умная розетка) + пинг интернета.
# Роутер в ИБП — локальная сеть жива при отключении эл-ва.
#
# Пост-уведомление: флаг на диске → после reboot → Telegram.
#
# Версия: 4.0
# Установка: https://github.com/akrhin/powerfail-shutdown
# ==============================================================

# === Настраиваемые параметры ===
THRESHOLD="${THRESHOLD:-3}"
XPENOLOGY_VMID="${XPENOLOGY_VMID:-100}"
FSCT_VMID="${FSCT_VMID:-107}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-600}"
LOG_TAG="POWERFAIL"

# Home Assistant (опционально)
# HA_API_URL — эндпоинт статуса розетки
# HA_API_TOKEN — bearer токен HA
HA_API_URL="${HA_API_URL:-}"
HA_API_TOKEN="${HA_API_TOKEN:-}"

# Telegram (опционально)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
TG_PROXY="${TG_PROXY:-}"

# Читаем конфиг (если не systemd — подставляет переменные)
if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    [ -f "/etc/powerfail/powerfail.conf" ] && source "/etc/powerfail/powerfail.conf"
fi

# Прокси для curl
[ -n "$TG_PROXY" ] && export https_proxy="$TG_PROXY" http_proxy="$TG_PROXY"

COUNTER_FILE="${COUNTER_FILE:-/tmp/powerfail_proxmox_counter}"
POWERFAIL_FILE="${POWERFAIL_FILE:-/tmp/.powerfail_active}"
# Флаг AFTER shutdown — сохраняется после reboot (не в /tmp)
OCCURRED_FILE="/root/.powerfail_occurred"
OCCURRED_LOG="/root/.powerfail_occurred.log"

# === Парсинг аргументов ===
DRY_RUN=false
DEBUG=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --debug)   DEBUG=true ;;
        test-network) TEST_MODE=true ;;
        --test-telegram) TEST_TELEGRAM=true ;;
    esac
done

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
}

die() {
    log "FATAL: $1"
    exit 1
}

_tg_send() {
    local msg="$1"
    [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && return 0
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    curl -s -o /dev/null --connect-timeout 10 --max-time 15 -k \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":${TG_CHAT_ID},\"text\":\"[${ts}] ${msg}\",\"disable_web_page_preview\":true}" \
        || log "WARN: telegram sendMessage failed"
}

# === Проверка: есть ли доступ в интернет ===
_internet_ok() {
    ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1
}

# === Проверка розетки через HA API ===
_ha_outlet_ok() {
    [ -z "$HA_API_URL" ] || [ -z "$HA_API_TOKEN" ] && return 0  # не настроено — считаем ок
    local result
    result=$(curl -s --connect-timeout 5 --max-time 10 \
        -H "Authorization: Bearer ${HA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "$HA_API_URL" 2>/dev/null)
    echo "$result" | grep -q '"state":"on"' && return 0
    return 1
}

_pct_stop() {
    local ctid="$1"
    if $DRY_RUN; then log "[DRY-RUN] pct shutdown $ctid --timeout 30"; return 0; fi
    pct shutdown "$ctid" --timeout 30 2>/dev/null && return 0
    log "  WARN: pct shutdown $ctid failed, force stop..."
    sleep 2; pct stop "$ctid" --force 2>/dev/null
}

_qm_stop() {
    local vmid="$1"
    if $DRY_RUN; then log "[DRY-RUN] qm shutdown $vmid --timeout 120"; return 0; fi
    if ! qm shutdown "$vmid" --timeout 120 2>/dev/null; then
        log "  WARN: qm shutdown $vmid failed, force stop..."
        qm stop "$vmid" 2>/dev/null
    fi
    local waited=0
    while [ "$waited" -lt "$SHUTDOWN_TIMEOUT" ]; do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        [ "$status" = "stopped" ] && log "  VM $vmid stopped (${waited}s)" && return 0
        sleep 10; waited=$((waited + 10))
    done
    log "  WARN: VM $vmid not stopping after ${SHUTDOWN_TIMEOUT}s, force..."
    qm stop "$vmid" 2>/dev/null
}

# === Зависимости ===
command -v ping >/dev/null 2>&1 || die "ping not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v qm >/dev/null 2>&1 || die "qm not found (not Proxmox?)"
command -v pct >/dev/null 2>&1 || die "pct not found (not Proxmox?)"
command -v shutdown >/dev/null 2>&1 || die "shutdown not found"

# =========================================================
# РЕЖИМ: test-network
# =========================================================
if [ "${TEST_MODE:-false}" = true ]; then
    echo "=== Powerfail Network Test ==="
    echo ""
    echo "🌐 Интернет:"
    if _internet_ok; then echo "  ✅ 8.8.8.8 — доступен"; else echo "  ❌ 8.8.8.8 — нет доступа"; fi

    echo ""
    echo "🔌 Розетка (HA):"
    if [ -z "$HA_API_URL" ]; then
        echo "  ⏭️  HA не настроен"
    elif _ha_outlet_ok; then
        echo "  ✅ Розетка: ON (есть питание)"
    else
        echo "  ❌ Розетка: OFF (нет питания)"
    fi

    echo ""
    echo "Running VMs:"
    qm list 2>/dev/null | awk 'NR==1 || $3=="running" {printf "  %-5s %-30s %s\n", $1, $2, $3}'
    echo "Running CTs:"
    pct list 2>/dev/null | awk 'NR==1{printf "  %-5s %-10s\n", $1, $2} NR>1{printf "  %-5s %-10s\n", $1, $2}'

    if [ -f "$OCCURRED_FILE" ]; then
        echo ""
        echo "⚠️  Флаг аварийного отключения: $(cat "$OCCURRED_FILE")"
    fi

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        echo ""
        echo "📨 Telegram: настроен"
    fi

    echo ""
    echo "Test complete."
    exit 0
fi

# =========================================================
# РЕЖИМ: test-telegram
# =========================================================
if [ "${TEST_TELEGRAM:-false}" = true ]; then
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        echo "❌ Telegram не настроен. Заполни /etc/powerfail/powerfail.conf"
        echo "   TG_BOT_TOKEN='${TG_BOT_TOKEN:+set}' (длина: ${#TG_BOT_TOKEN})"
        echo "   TG_CHAT_ID='${TG_CHAT_ID:+set}' (длина: ${#TG_CHAT_ID})"
        exit 1
    fi
    echo "📨 Отправляю тестовое сообщение в Telegram..."
    echo "   chat_id: $TG_CHAT_ID"
    [ -n "$TG_PROXY" ] && echo "   proxy: $TG_PROXY"
    _ts="$(date '+%Y-%m-%d %H:%M:%S')"
    _http_code="$(curl -s -o /tmp/powerfail_tg_test.json -w '%{http_code}' \
        --connect-timeout 10 --max-time 15 -k \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":${TG_CHAT_ID},\"text\":\"[${_ts}] ✅ Тест — powerfail-shutdown работает.\",\"disable_web_page_preview\":true}" 2>&1)"
    _response="$(cat /tmp/powerfail_tg_test.json 2>/dev/null || echo 'no response file')"
    rm -f /tmp/powerfail_tg_test.json 2>/dev/null
    echo "   HTTP: $_http_code"
    echo "   Ответ: $_response"
    if echo "$_response" | grep -q '"ok":true'; then
        echo "✅ Сообщение отправлено!"
    else
        echo "❌ Ошибка."
    fi
    exit 0
fi

# =========================================================
# ОСНОВНАЯ ЛОГИКА
# =========================================================

# --- Этап 0: Пост-уведомление после восстановления питания ---
if [ -f "$OCCURRED_FILE" ]; then
    if _internet_ok; then
        local occurred_at=$(cat "$OCCURRED_FILE")
        _tg_send "⚡ Питание восстановлено. Аварийное отключение было в ${occurred_at}. Все сервисы запущены."
        log "Power restored. Sent post-recovery notification (occurred: $occurred_at)"
        rm -f "$OCCURRED_FILE" "$OCCURRED_LOG" 2>/dev/null
    fi
    exit 0
fi

# --- Этап 1: Уже в процессе shutdown — пропускаем ---
if [ -f "$POWERFAIL_FILE" ]; then
    exit 0
fi

# --- Этап 2: Детекция пропажи электричества ---
#   Розетка через HA — основной индикатор
#   Пинг 8.8.8.8 — подтверждение (интернет пропал)
power_gone=false

if [ -n "$HA_API_URL" ]; then
    if ! _ha_outlet_ok; then
        log "🔌 Розетка OFF — питание пропало"
        power_gone=true
    fi
fi

if ! _internet_ok; then
    log "🌐 Интернет недоступен"
    [ -z "$HA_API_URL" ] && power_gone=true
fi

if ! $power_gone; then
    # Всё в порядке — сбрасываем счётчик (если был)
    if [ -f "$COUNTER_FILE" ]; then
        echo 0 > "$COUNTER_FILE"
        rm -f "$(dirname "$COUNTER_FILE")/.powerfail_ha_counter" 2>/dev/null
    fi
    exit 0
fi

# --- Этап 3: Достигли порога? ---
# Читаем счётчик HA-провалов (отдельно от ping)
ha_counter=0
if [ -f "$(dirname "$COUNTER_FILE")/.powerfail_ha_counter" ]; then
    ha_counter=$(cat "$(dirname "$COUNTER_FILE")/.powerfail_ha_counter" 2>/dev/null || echo 0)
fi
ha_counter=$((ha_counter + 1))
echo "$ha_counter" > "$(dirname "$COUNTER_FILE")/.powerfail_ha_counter"
log "⚠️  Power failure suspicion (attempt $ha_counter/$THRESHOLD)"

if [ "$ha_counter" -lt "$THRESHOLD" ]; then
    exit 0
fi

# =========================================================
# ПОДТВЕРЖДЕНО — shutdown sequence
# =========================================================
log "!!! POWER FAILURE CONFIRMED — initiating shutdown sequence"
touch "$POWERFAIL_FILE"

# Запись времени для пост-уведомления
_ts=$(date '+%Y-%m-%d %H:%M:%S')
echo "$_ts" > "$OCCURRED_FILE"

_tg_send "⚠️ POWER FAILURE (${_ts}) — питание пропало. Запускаю shutdown."

# Фаза 1: CT 107 (FS)
log "Phase 1/5: Shutting down CT $FSCT_VMID (FS)..."
_pct_stop "$FSCT_VMID"

# Фаза 2: Xpenology (VM 100)
log "Phase 2/5: Shutting down Xpenology (VM $XPENOLOGY_VMID)..."
_qm_stop "$XPENOLOGY_VMID"

# Фаза 3: остальные
log "Phase 3/5: Shutting down remaining VMs and containers..."
if $DRY_RUN; then
    log "[DRY-RUN] Would shut down remaining VMs and CTs"
else
    for vmid in $(qm list 2>/dev/null | awk -v skip="$XPENOLOGY_VMID" 'NR>1 && $3=="running" && $1+0!=skip {print $1}'); do
        log "  Shutting down VM $vmid..."
        qm shutdown "$vmid" --timeout 60 &
    done
    for ctid in $(pct list 2>/dev/null | awk -v skip="$FSCT_VMID" 'NR>1 && $2=="running" && $1+0!=skip {print $1}'); do
        log "  Shutting down CT $ctid..."
        pct shutdown "$ctid" --timeout 30 &
    done
    wait
fi

# Фаза 4: добиваем
log "Phase 4/5: Final check — force-stop remaining..."
if ! $DRY_RUN; then
    for vmid in $(qm list 2>/dev/null | awk 'NR>1 && $3!="stopped" {print $1}'); do
        log "  Force stopping VM $vmid..."; qm stop "$vmid" 2>/dev/null
    done
    for ctid in $(pct list 2>/dev/null | awk 'NR>1 && $2!="stopped" {print $1}'); do
        log "  Force stopping CT $ctid..."; pct stop "$ctid" 2>/dev/null
    done
fi

# Фаза 5: хост
log "Phase 5/5: Shutting down Proxmox host."
_tg_send "🛑 Power failure shutdown complete — host ${_ts}."

if $DRY_RUN; then
    log "[DRY-RUN] *** SHUTDOWN SIMULATED ***"
    echo 0 > "$COUNTER_FILE"
    rm -f "$POWERFAIL_FILE" "$(dirname "$COUNTER_FILE")/.powerfail_ha_counter" 2>/dev/null
    exit 0
fi

log "GOODBYE — shutting down host"
shutdown -h now
sleep 300
die "shutdown did not execute!"
