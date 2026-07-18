#!/bin/bash
# Powerfail Xpenology — страховочный скрипт
# Ставится на сам Xpenology через Task Scheduler (каждую минуту).
# Если /root/.powerfail_occurred существует → выключение.
#
# Установка:
#   curl -sL https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main/deploy/powerfail-xpenology.sh \
#     -o /root/powerfail-xpenology.sh
#   chmod +x /root/powerfail-xpenology.sh
#   # Добавить в Task Scheduler: run every 1 minute

set -euo pipefail

FLAG="/root/.powerfail_occurred"

if [[ -f "$FLAG" ]]; then
  logger -t powerfail-xpenology "Powerfail flag detected — shutting down"
  poweroff
fi
