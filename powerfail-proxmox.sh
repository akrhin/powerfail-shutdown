#!/bin/bash
# ==============================================================
# UPS Power Failure Shutdown — Proxmox (основной оркестратор)
#
# Версия: 2.0
# Режимы:
#   Реальный — полный shutdown последовательности
#   --dry-run — логирует все шаги, не выключает
#   --debug — подробный вывод каждой проверки
#   test-network — однократная проверка связи (для ручного теста)
#
# Установка: https://github.com/akrhin/powerfail-shutdown
# ==============================================================

# === Настраиваемые параметры ===
ROUTER="${ROUTER:-192.168.1.1}"
THRESHOLD="${THRESHOLD:-3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
XPENOLOGY_VMID="${XPENOLOGY_VMID:-100}"
FSCT_VMID="${FSCT_VMID:-107}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-600}"
LOG_TAG="POWERFAIL"

COUNTER_FILE="${COUNTER_FILE:-/tmp/powerfail_proxmox_counter}"
POWERFAIL_FILE="${POWERFAIL_FILE:-/tmp/.powerfail_active}"

# === Парсинг аргументов ===
DRY_RUN=false
DEBUG=false
TEST_MODE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --debug)   DEBUG=true ;;
        test-network) TEST_MODE=true ;;
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

_pct_stop() {
    local ctid="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] pct shutdown $ctid --timeout 30"
        return 0
    fi
    pct shutdown "$ctid" --timeout 30 2>/dev/null && return 0
    log "  WARN: pct shutdown $ctid failed, trying force stop..."
    sleep 2
    pct stop "$ctid" --force 2>/dev/null
}

_qm_stop() {
    local vmid="$1"
    local timeout="${2:-120}"
    if $DRY_RUN; then
        log "[DRY-RUN] qm shutdown $vmid --timeout $timeout"
        return 0
    fi
    if ! qm shutdown "$vmid" --timeout "$timeout" 2>/dev/null; then
        log "  WARN: qm shutdown $vmid failed, trying force stop..."
        qm stop "$vmid" 2>/dev/null
    fi

    # Ждём когда остановится
    local waited=0
    while [ "$waited" -lt "$SHUTDOWN_TIMEOUT" ]; do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        [ "$status" = "stopped" ] && log "  VM $vmid stopped (${waited}s)" && return 0
        sleep 10
        waited=$((waited + 10))
    done
    log "  WARN: VM $vmid did not stop within ${SHUTDOWN_TIMEOUT}s, force stopping..."
    qm stop "$vmid" 2>/dev/null
}

# === Проверка зависимостей ===
command -v ping >/dev/null 2>&1 || die "ping not found"
command -v qm >/dev/null 2>&1 || die "qm not found (not Proxmox?)"
command -v pct >/dev/null 2>&1 || die "pct not found (not Proxmox?)"
command -v shutdown >/dev/null 2>&1 || die "shutdown not found"

# === Режим test-network: однократная проверка ===
if $TEST_MODE; then
    echo "=== Powerfail Network Test ==="
    echo "Router: $ROUTER"
    echo "Threshold: $THRESHOLD failures"
    echo ""

    for i in $(seq 1 "$THRESHOLD"); do
        if ping -c 1 -W 2 "$ROUTER" >/dev/null 2>&1; then
            echo "[$i/$THRESHOLD] ✅ Router $ROUTER — UP"
        else
            echo "[$i/$THRESHOLD] ❌ Router $ROUTER — DOWN"
        fi
    done

    echo ""
    echo "Running VMs:"
    qm list 2>/dev/null | awk 'NR==1 || $3=="running" {printf "  %-5s %-30s %s\n", $1, $2, $3}'
    echo ""
    echo "Running CTs:"
    pct list 2>/dev/null | awk 'NR==1 || $3=="running" {printf "  %-5s %-30s %s\n", $1, $2, $3}'
    echo ""
    echo "Test complete. Use --dry-run for a full shutdown simulation."
    exit 0
fi

# === Основной мониторинг ===
log "Starting UPS power failure monitor (router=$ROUTER)"
$DEBUG && log "DEBUG: THRESHOLD=$THRESHOLD CHECK_INTERVAL=$CHECK_INTERVAL DRY_RUN=$DRY_RUN"

while true; do
    counter=0
    if [ -f "$COUNTER_FILE" ]; then
        counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    fi

    # === Проверка связи ===
    if ping -c 1 -W 3 "$ROUTER" >/dev/null 2>&1; then
        # Роутер жив
        $DEBUG && log "DEBUG: Router $ROUTER is UP — resetting counter"
        echo 0 > "$COUNTER_FILE"
        rm -f "$POWERFAIL_FILE" 2>/dev/null
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # Роутер не ответил
    counter=$((counter + 1))
    echo "$counter" > "$COUNTER_FILE"
    log "WARN — router $ROUTER unreachable (attempt $counter/$THRESHOLD)"

    if [ "$counter" -lt "$THRESHOLD" ]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # === Достигнут порог — начинаем последовательность отключения ===
    log "!!! POWER FAILURE DETECTED — initiating shutdown sequence"
    touch "$POWERFAIL_FILE"

    # -------------------
    # Фаза 1: CT 107 (FS)
    # -------------------
    log "Phase 1/5: Shutting down CT $FSCT_VMID (FS)..."
    _pct_stop "$FSCT_VMID"

    # -------------------
    # Фаза 2: XPEnology (VM 100) — с неё NFS
    # -------------------
    log "Phase 2/5: Shutting down Xpenology (VM $XPENOLOGY_VMID)..."
    _qm_stop "$XPENOLOGY_VMID"

    # -------------------
    # Фаза 3: остальные VM и LXC
    # -------------------
    log "Phase 3/5: Shutting down remaining VMs and containers..."

    if $DRY_RUN; then
        log "[DRY-RUN] Would shut down remaining VMs:"
        qm list 2>/dev/null | awk 'NR>1 && $3=="running" && $1!='"$XPENOLOGY_VMID"' {print "  - VM " $1 " (" $2 ")"}' | while read -r line; do log "[DRY-RUN] $line"; done
        log "[DRY-RUN] Would shut down remaining CTs:"
        pct list 2>/dev/null | awk 'NR>1 && $3=="running" && $1!='"$FSCT_VMID"' {print "  - CT " $1 " (" $2 ")"}' | while read -r line; do log "[DRY-RUN] $line"; done
    else
        for vmid in $(qm list 2>/dev/null | awk 'NR>1 && $3=="running" && $1!='"$XPENOLOGY_VMID"' {print $1}'); do
            log "  Shutting down VM $vmid..."
            qm shutdown "$vmid" --timeout 60 &
        done
        for ctid in $(pct list 2>/dev/null | awk 'NR>1 && $3=="running" && $1!='"$FSCT_VMID"' {print $1}'); do
            log "  Shutting down CT $ctid..."
            pct shutdown "$ctid" --timeout 30 &
        done
        wait
    fi
    $DRY_RUN || log "Phase 3 complete."

    # -------------------
    # Фаза 4: финальная проверка
    # -------------------
    log "Phase 4/5: Final check — force-stop any remaining VMs/CTs..."

    if $DRY_RUN; then
        log "[DRY-RUN] Would force-stop remaining VMs and CTs"
    else
        for vmid in $(qm list 2>/dev/null | awk 'NR>1 && $3!="stopped" {print $1}'); do
            log "  Force stopping VM $vmid..."
            qm stop "$vmid" 2>/dev/null
        done
        for ctid in $(pct list 2>/dev/null | awk 'NR>1 && $3!="stopped" {print $1}'); do
            log "  Force stopping CT $ctid..."
            pct stop "$ctid" 2>/dev/null
        done
    fi

    # -------------------
    # Фаза 5: хост
    # -------------------
    log "Phase 5/5: Shutting down Proxmox host."

    if $DRY_RUN; then
        log "=========================================="
        log "[DRY-RUN] *** SHUTDOWN SIMULATED ***"
        log "[DRY-RUN] Would execute: shutdown -h now"
        log "[DRY-RUN] No actual shutdown performed."
        log "=========================================="
        echo 0 > "$COUNTER_FILE"
        rm -f "$POWERFAIL_FILE" 2>/dev/null
        log "DRY-RUN complete. Exiting monitor loop."
        exit 0
    else
        log "GOODBYE — shutting down host"
        shutdown -h now
        sleep 300  # страховка
        die "shutdown did not execute!"
    fi

    sleep "$CHECK_INTERVAL"
done
