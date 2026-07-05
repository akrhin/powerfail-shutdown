#!/bin/bash
# ==============================================================
# UPS Power Failure Shutdown — Proxmox (основной оркестратор)
#
# Версия: 1.1
# Режимы:
#   Реальный — полный shutdown последовательности
#   --dry-run — логирует все шаги, не выключает
#   --debug — подробный вывод каждой проверки
#   test-network — однократная проверка связи (для ручного теста)
#
# Установка: см. README.md
# ==============================================================

# === Настраиваемые параметры ===
ROUTER="${ROUTER:-192.168.1.1}"
THRESHOLD="${THRESHOLD:-3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
XPENOLOGY_VMID="${XPENOLOGY_VMID:-100}"
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
log "Starting UPS power failure monitor (router=$ROUTER, xpenology_vmid=$XPENOLOGY_VMID)"
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
    # Фаза 1: XPEnology (VM 100) — выключается первой, с неё NFS
    # Остальные VM/CT монтируют NFS с XPEnology, поэтому НЕЛЬЗЯ
    # выключать их до того как XPEnology встала
    # -------------------
    log "Phase 1/4: Waiting for Xpenology (VM $XPENOLOGY_VMID) to shut down..."

    if $DRY_RUN; then
        log "[DRY-RUN] Xpenology (VM $XPENOLOGY_VMID) shuts down FIRST (its own powerfail script)"
        log "[DRY-RUN] Would wait up to ${SHUTDOWN_TIMEOUT}s for VM $XPENOLOGY_VMID to stop"
        log "[DRY-RUN] Xpenology shutdown SIMULATED (status=stopped)"
    else
        # XPEnology уже запустила свой скрипт — ждём когда она выключится
        waited=0
        while [ "$waited" -lt "$SHUTDOWN_TIMEOUT" ]; do
            status=$(qm status "$XPENOLOGY_VMID" 2>/dev/null | awk '{print $2}')
            if [ "$status" = "stopped" ]; then
                log "Xpenology VM $XPENOLOGY_VMID is now stopped (${waited}s)"
                break
            fi
            sleep 10
            waited=$((waited + 10))
        done

        if [ "$waited" -ge "$SHUTDOWN_TIMEOUT" ]; then
            log "WARNING: Xpenology did not stop within ${SHUTDOWN_TIMEOUT}s. Force stopping..."
            qm stop "$XPENOLOGY_VMID"
            sleep 5
        fi
    fi

    # -------------------
    # Фаза 2: остальные VM и LXC (NFS уже неактивна)
    # -------------------
    log "Phase 2/4: Shutting down remaining VMs and containers..."

    if $DRY_RUN; then
        log "[DRY-RUN] Would shut down VMs:"
        qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print "  - VM " $1 " (" $2 ")"}' | while read -r line; do log "[DRY-RUN] $line"; done
        log "[DRY-RUN] Would shut down containers:"
        pct list 2>/dev/null | awk 'NR>1 && $3=="running" {print "  - CT " $1 " (" $2 ")"}' | while read -r line; do log "[DRY-RUN] $line"; done
    else
        for vmid in $(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'); do
            log "  Shutting down VM $vmid..."
            qm shutdown "$vmid" --timeout 60 &
        done
        for ctid in $(pct list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'); do
            log "  Shutting down CT $ctid..."
            pct shutdown "$ctid" --timeout 30 &
        done
        wait
        log "Phase 2 complete."
    fi

    # -------------------
    # Фаза 3: финальная проверка
    # -------------------
    log "Phase 3/4: Final check — shutting down any remaining VMs/CTs..."

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
    # Фаза 4: хост
    # -------------------
    log "Phase 4/4: Shutting down Proxmox host."

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
