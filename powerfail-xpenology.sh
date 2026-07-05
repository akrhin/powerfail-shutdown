#!/bin/bash
# ==============================================================
# UPS Power Failure Shutdown — Xpenology (страховочный скрипт)
# 
# Версия: 1.1
# Режимы:
#   Реальный — при 3 провалах пинга → poweroff
#   --dry-run — пишет в лог, не выключает
#   --debug — подробный вывод каждой проверки
#
# Установка на Synology: см. README.md
# ==============================================================

ROUTER="${ROUTER:-192.168.1.1}"
COUNTER_FILE="${COUNTER_FILE:-/tmp/powerfail_xpenology_counter}"
XPENOLOGY_COUNTER_FILE="${COUNTER_FILE}"
THRESHOLD="${THRESHOLD:-3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
LOG_TAG="POWERFAIL"

# Парсинг аргументов
DRY_RUN=false
DEBUG=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --debug)   DEBUG=true ;;
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

# Проверка зависимостей
command -v ping >/dev/null 2>&1 || die "ping not found"
command -v poweroff >/dev/null 2>&1 || die "poweroff not found (Synology run this?)"

$DEBUG && log "DEBUG: ROUTER=$ROUTER THRESHOLD=$THRESHOLD COUNTER=$COUNTER_FILE DRY_RUN=$DRY_RUN"

# === Проверка ===
counter=0
if [ -f "$COUNTER_FILE" ]; then
    counter=$(cat "$COUNTER_FILE" 2>/dev/null)
    counter=${counter:-0}
fi

if ping -c 1 -W 3 "$ROUTER" >/dev/null 2>&1; then
    # Роутер жив
    $DEBUG && log "DEBUG: Router $ROUTER is UP — resetting counter"
    echo 0 > "$COUNTER_FILE"
    log "OK — router $ROUTER reachable, counter reset"
    exit 0
fi

# Роутер не ответил
counter=$((counter + 1))
echo "$counter" > "$COUNTER_FILE"
log "WARN — router $ROUTER unreachable (attempt $counter/$THRESHOLD)"

if [ "$counter" -lt "$THRESHOLD" ]; then
    exit 0
fi

# === Достигнут порог — действуем ===
log "!!! POWER FAILURE DETECTED — router $ROUTER unreachable for $THRESHOLD checks"

if $DRY_RUN; then
    log "DRY-RUN: Would execute: poweroff"
    log "DRY-RUN: Xpenology shutdown SIMULATED (not actually shutting down)"
    echo 0 > "$COUNTER_FILE"
    exit 0
fi

log "EXECUTING: poweroff (shutting down Xpenology)"
poweroff

# Страховка если poweroff не сработал
sleep 30
die "poweroff did not execute — manual intervention required"
