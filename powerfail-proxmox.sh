#!/bin/bash
# ==============================================================
# UPS Power Failure Shutdown — Proxmox
#
# Запускается systemd-таймером раз в 30 секунд.
#
# Детекция: ESP32-розетка (192.168.1.100) + пинг роутера.
# Розетка стоит ПЕРЕД ИБП — если нет 220В, она не пингуется.
# Роутер в ИБП — локальная сеть и интернет живы при отключении.
#
# При подтверждённом пропадании питания:
#   1. Shutdown всех VM/CT
#   2. Shutdown хоста (systemctl poweroff)
#   3. Выключение розетки (ESPHome API) — обесточивает ИБП
#   4. При восстановлении 220В розетка включается → сервер стартует
#
# Уведомление в Telegram ДО shutdown (пока есть интернет)
# и ПОСЛЕ восстановления питания (через флаг на диске).
#
# Версия: 5.0
# Установка: https://github.com/akrhin/powerfail-shutdown
# ==============================================================

# === Настраиваемые параметры ===
ROUTER="${ROUTER:-192.168.1.1}"
SOCKET_IP="${SOCKET_IP:-192.168.1.100}"
THRESHOLD="${THRESHOLD:-3}"
XPENOLOGY_VMID="${XPENOLOGY_VMID:-100}"
FSCT_VMID="${FSCT_VMID:-107}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-600}"
LOG_TAG="POWERFAIL"
POWEROFF_DELAY="${POWEROFF_DELAY:-30}"  # секунд ждать после shutdown перед отключением розетки

# Telegram (опционально)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
TG_PROXY="${TG_PROXY:-}"

# Подгрузка конфига
if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    [ -f "/etc/powerfail/powerfail.conf" ] && source "/etc/powerfail/powerfail.conf"
fi

[ -n "$TG_PROXY" ] && export https_proxy="$TG_PROXY" http_proxy="$TG_PROXY"

COUNTER_FILE="${COUNTER_FILE:-/tmp/powerfail_proxmox_counter}"
POWERFAIL_FILE="${POWERFAIL_FILE:-/tmp/.powerfail_active}"
OCCURRED_FILE="/root/.powerfail_occurred"

# === Парсинг аргументов ===
DRY_RUN=false; DEBUG=false
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

die() { log "FATAL: $1"; exit 1; }

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

_socket_api() {
    local action="$1"  # status, turn_off
    case "$action" in
        status)
            curl -s --connect-timeout 5 --max-time 10 \
                "http://${SOCKET_IP}/switch/0" 2>/dev/null || return 1
            ;;
        turn_off)
            curl -s --connect-timeout 5 --max-time 10 \
                -X POST "http://${SOCKET_IP}/switch/0/turn_off" 2>/dev/null || return 1
            ;;
    esac
}

# === Проверка розетки (ESP32) ===
_socket_ok() {
    # Пинг — розетка без питания не отвечает
    ping -c 1 -W 2 "$SOCKET_IP" >/dev/null 2>&1
}

# === Проверка роутера (локальная сеть) ===
_router_ok() {
    ping -c 1 -W 2 "$ROUTER" >/dev/null 2>&1
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

_shutdown_sequence() {
    local ts=$1
    log "!!! POWER FAILURE CONFIRMED — initiating shutdown sequence"

    # Уведомление ДО shutdown (интернет пока есть — роутер в ИБП)
    _tg_send "⚠️ POWER FAILURE (${ts}) — питание пропало. Запускаю shutdown sequence."

    # Флаг для пост-уведомления после восстановления
    echo "$ts" > "/root/.powerfail_occurred"
    touch "$POWERFAIL_FILE"

    log "Phase 1/5: Shutting down CT $FSCT_VMID (FS)..."
    _pct_stop "$FSCT_VMID"

    log "Phase 2/5: Shutting down Xpenology (VM $XPENOLOGY_VMID)..."
    _qm_stop "$XPENOLOGY_VMID"

    log "Phase 3/5: Shutting down remaining VMs and containers..."
    if $DRY_RUN; then
        log "[DRY-RUN] Would shut down remaining VMs and CTs"
    else
        for vmid in $(qm list 2>/dev/null | awk -v skip="$XPENOLOGY_VMID" 'NR>1 && $3=="running" && $1+0!=skip {print $1}'); do
            log "  Shutting down VM $vmid..."; qm shutdown "$vmid" --timeout 60 &
        done
        for ctid in $(pct list 2>/dev/null | awk -v skip="$FSCT_VMID" 'NR>1 && $2=="running" && $1+0!=skip {print $1}'); do
            log "  Shutting down CT $ctid..."; pct shutdown "$ctid" --timeout 30 &
        done
        wait
    fi

    log "Phase 4/5: Final check — force-stop remaining..."
    if ! $DRY_RUN; then
        for vmid in $(qm list 2>/dev/null | awk 'NR>1 && $3!="stopped" {print $1}'); do
            log "  Force stopping VM $vmid..."; qm stop "$vmid" 2>/dev/null
        done
        for ctid in $(pct list 2>/dev/null | awk 'NR>1 && $2!="stopped" {print $1}'); do
            log "  Force stopping CT $ctid..."; pct stop "$ctid" 2>/dev/null
        done
    fi

    log "Phase 5/6: Shutting down Proxmox host (poweroff)..."
    _tg_send "🛑 Power failure — shutting down host (${ts})."

    if $DRY_RUN; then
        log "[DRY-RUN] *** SHUTDOWN SIMULATED ***"
        echo 0 > "$COUNTER_FILE"
        rm -f "$POWERFAIL_FILE" 2>/dev/null
        exit 0
    fi

    # POWEROFF, не halt!
    log "GOODBYE — poweroff host"
    poweroff &
    POWEROFF_PID=$!

    # Ждём пока сервер выключится, потом отключаем розетку
    log "Phase 6/6: Waiting ${POWEROFF_DELAY}s for shutdown, then turning off socket..."
    sleep "$POWEROFF_DELAY"

    # Отключаем розетку (ESPHome API) — обесточиваем ИБП
    log "Turning off smart socket at $SOCKET_IP..."
    _socket_api turn_off || log "WARN: failed to turn off socket (expected if already off)"

    # Ждём пока нас не вырубят
    sleep 300
    die "Poweroff did not execute!"
}

# === Зависимости ===
command -v ping >/dev/null 2>&1 || die "ping not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v qm >/dev/null 2>&1 || die "qm not found (not Proxmox?)"
command -v pct >/dev/null 2>&1 || die "pct not found (not Proxmox?)"
command -v poweroff >/dev/null 2>&1 || die "poweroff not found"

# =========================================================
# РЕЖИМ: test-network
# =========================================================
if [ "${TEST_MODE:-false}" = true ]; then
    echo "=== Powerfail Network Test ==="
    echo ""

    if _router_ok; then echo "🌐 Роутер ($ROUTER): ✅ UP"; else echo "🌐 Роутер ($ROUTER): ❌ DOWN"; fi

    if _socket_ok; then
        echo "🔌 Розетка ($SOCKET_IP): ✅ ON"
    else
        echo "🔌 Розетка ($SOCKET_IP): ❌ OFF"
    fi

    echo ""
    echo "ВМ:"
    qm list 2>/dev/null | awk 'NR==1 || $3=="running" {printf "  %-5s %-30s %s\n", $1, $2, $3}'
    echo "СТ:"
    pct list 2>/dev/null | awk 'NR==1{printf "  %-5s %-10s\n", $1, $2} NR>1{printf "  %-5s %-10s\n", $1, $2}'

    if [ -f "$OCCURRED_FILE" ]; then
        echo ""
        echo "⚠️  Флаг аварийного отключения: $(cat "$OCCURRED_FILE")"
    fi
    if [ -f "$COUNTER_FILE" ]; then
        echo "📊 Счётчик подозрений: $(cat "$COUNTER_FILE")"
    fi
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
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
    echo "📨 Отправляю тестовое сообщение..."
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
    echo "$_response" | grep -q '"ok":true' && echo "✅ Отправлено!" || echo "❌ Ошибка."
    exit 0
fi

# =========================================================
# ОСНОВНАЯ ЛОГИКА
# =========================================================

# --- Этап 0: Пост-уведомление после восстановления ---
if [ -f "$OCCURRED_FILE" ]; then
    occurred_at=$(cat "$OCCURRED_FILE")
    if _router_ok; then
        _tg_send "⚡ Питание восстановлено. Аварийное отключение было в ${occurred_at}."
        log "Power restored. Post-recovery notification sent (occurred: $occurred_at)"
        rm -f "$OCCURRED_FILE" 2>/dev/null
    fi
    exit 0
fi

# --- Этап 1: Уже shutdown — пропуск ---
if [ -f "$POWERFAIL_FILE" ]; then
    exit 0
fi

# --- Этап 2: Детекция ---
socket_ok=true
router_ok=true

if ! _socket_ok; then
    socket_ok=false
    log "🔌 Розетка ($SOCKET_IP) OFF — питание не обнаружено"
fi

if ! _router_ok; then
    router_ok=false
    log "📡 Роутер $ROUTER — не отвечает"
fi

# Если всё ОК — сброс счетчика
if $socket_ok && $router_ok; then
    [ -f "$COUNTER_FILE" ] && echo 0 > "$COUNTER_FILE"
    exit 0
fi

# Если хотя бы один источник сигналит о проблеме — увеличиваем счётчик
counter=0
[ -f "$COUNTER_FILE" ] && counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
counter=$((counter + 1))
echo "$counter" > "$COUNTER_FILE"

# Определяем причину в лог
if ! $socket_ok && ! $router_ok; then
    log "⚠️  Power failure suspicion $counter/$THRESHOLD — розетка OFF + роутер DOWN"
elif ! $socket_ok; then
    log "⚠️  Power failure suspicion $counter/$THRESHOLD — розетка OFF (роутер жив)"
else
    log "⚠️  Power failure suspicion $counter/$THRESHOLD — роутер DOWN (розетка ОК)"
fi

if [ "$counter" -lt "$THRESHOLD" ]; then
    exit 0
fi

# =========================================================
# Достигнут порог — shutdown
# =========================================================
_ts=$(date '+%Y-%m-%d %H:%M:%S')
_shutdown_sequence "$_ts"
