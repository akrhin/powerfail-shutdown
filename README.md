# UPS Power Failure Shutdown

Два скрипта для автоматического отключения сервера при пропадании электричества.
APC Back-UPS ES 400, без USB/сеть, ~60 Вт нагрузка.

## Принцип работы

Роутер **не подключён к ИБП** — он умирает первым при отключении электричества.
Сервер (в ИБП) пингует роутер. Если роутер не отвечает 3 раза подряд → электричества нет → shutdown.

```
Пропало Электричество
  │
  ├── Роутер (НЕ в ИБП) → умер (0 сек)
  │
  ├── [PROXMOX] powerfail-proxmox.sh (основной, systemd)
  │   ├── пинг роутера каждые 30 сек
  │   ├── 3 провала → shutdown sequence:
  │   │   1. CT 107 (FS) — pct shutdown
  │   │   2. VM 100 (Xpenology) — qm shutdown, ждёт stopped
  │   │   3. Остальные VM и LXC — параллельно
  │   │   4. Force-stop остатков
  │   │   5. shutdown -h now
  │   └── Время: ~3-5 мин, ИБП держит ~30 мин
  │
  └── [XPENOLOGY] powerfail-xpenology.sh (резерв, crontab)
      ├── пинг роутера, 3 провала → poweroff
      └── страховка если proxmox завис
```

Запас по батарее колоссальный — можно не спешить.

---

## Установка на Proxmox

### 1. Клонировать репозиторий

```bash
# На proxmox хосте (или любом Linux с доступом по ssh)
git clone https://github.com/akrhin/powerfail-shutdown.git
cd powerfail-shutdown
```

### 2. Скопировать скрипты

```bash
cp powerfail-proxmox.sh /usr/local/bin/
cp powerfail-proxmox.service /etc/systemd/system/
chmod +x /usr/local/bin/powerfail-proxmox.sh
```

### 3. Настроить параметры (опционально)

Отредактируй переменные в начале `/usr/local/bin/powerfail-proxmox.sh`:

```bash
ROUTER="192.168.1.1"        # IP роутера (не в ИБП)
THRESHOLD=3                  # сколько провалов пинга до shutdown
CHECK_INTERVAL=30            # секунд между проверками
XPENOLOGY_VMID=100           # ID VM с Xpenology
FSCT_VMID=107                # ID CT с файловым сервером (выключается первым)
SHUTDOWN_TIMEOUT=600         # макс ждать выключения VM (сек)
```

### 4. Запустить как systemd-сервис

```bash
systemctl daemon-reload
systemctl enable powerfail-proxmox.service
systemctl start powerfail-proxmox.service
systemctl status powerfail-proxmox.service
```

### 5. Проверить что работает

```bash
# Режим test-network — однократная проверка связи + список VM/CT
/usr/local/bin/powerfail-proxmox.sh test-network

# Режим сухого прогона — имитация shutdown без выключения
/usr/local/bin/powerfail-proxmox.sh --dry-run --debug
```

---

## Установка на Xpenology (Synology DSM)

Xpenology выключается сама (страховочный скрипт), но работает медленнее — раз в 5 минут. Proxmox не ждёт её скрипта, а гасит через qm.

### 1. Клонировать

Через веб-интерфейс DSM — File Station → загрузить файл `powerfail-xpenology.sh`,
или по ssh:

```bash
git clone https://github.com/akrhin/powerfail-shutdown.git
cp powerfail-xpenology.sh /volume1/scripts/
chmod +x /volume1/scripts/powerfail-xpenology.sh
```

### 2. Создать задачу в планировщике

- **Панель управления → Планировщик задач → Создать → Запланированная задача → Пользовательский скрипт**
- **Общие:** Включить, пользователь `root`
- **Расписание:** «Выполнять каждые 5 минут» (Run every 5 minutes)
- **Настройки задачи — Код:**

```bash
/volume1/scripts/powerfail-xpenology.sh
```

### 3. Сначала протестировать

```bash
# сухой прогон (не выключает)
/volume1/scripts/powerfail-xpenology.sh --dry-run --debug
```

---

## Тестирование (dry-run mode)

**Перед тем как доверить скрипту реальное выключение — протестируй.**

### На Proxmox:

```bash
# 1. Проверка сети и список VM
/usr/local/bin/powerfail-proxmox.sh test-network

# 2. Сухой прогон (имитирует shutdown, НИЧЕГО не выключает)
# Сделай роутер временно недоступным (выдерни кабель на 2 мин):
/usr/local/bin/powerfail-proxmox.sh --dry-run --debug
# → Вывод: [DRY-RUN] на каждом шаге, реального выключения нет

# 3. Если всё устраивает — убери --dry-run
```

### На Xpenology:

```bash
/volume1/scripts/powerfail-xpenology.sh --dry-run --debug
```

### Поведение счётчика:

Чтобы проверить сценарий «пропало электричество» — выдерни кабель из роутера или выключи его на 2 минуты. Счётчик в `/tmp/powerfail_proxmox_counter` покажет `1`, потом `2`, потом `3` → shutdown.

Если кабель вернуть — счётчик сбросится в `0`.

---

## Порядок выключения

1. **CT 107** (FS) — первым, чтобы корректно размонтировать файловые системы
2. **VM 100** (Xpenology) — NFS-сервер, выключается перед остальными
3. **Все остальные VM и LXC** — параллельно (NFS уже неактивна)
4. **Force-stop** — добиваем зависшие
5. **Proxmox host** — последним

---

## Логи

**Proxmox:**
```bash
journalctl -u powerfail-proxmox.service -f
# или
journalctl -t POWERFAIL
```

**Xpenology:**
```bash
cat /var/log/messages | grep POWERFAIL
```

---

## Отладка

| Команда | Что делает |
|---------|-----------|
| `test-network` | Разовая проверка + список VM/CT |
| `--dry-run` | Сухой прогон (логирует, не выключает) |
| `--debug` | Подробный вывод каждой проверки |
| `--dry-run --debug` | Всё вместе |

Пример сухого прогона:

```
2026-07-05 18:00:00 [POWERFAIL] Starting UPS power failure monitor
2026-07-05 18:00:30 [POWERFAIL] WARN — router 192.168.1.1 unreachable (attempt 1/3)
2026-07-05 18:01:00 [POWERFAIL] WARN — router 192.168.1.1 unreachable (attempt 2/3)
2026-07-05 18:01:30 [POWERFAIL] WARN — router 192.168.1.1 unreachable (attempt 3/3)
2026-07-05 18:01:30 [POWERFAIL] !!! POWER FAILURE DETECTED
2026-07-05 18:01:30 [POWERFAIL] Phase 1/5: Shutting down CT 107 (FS)...
...
```

---

## Настройка порогов

Если роутер иногда флапает (перезагружается, лаги):

- `THRESHOLD=5` — больше толерантности
- `CHECK_INTERVAL=60` — раз в минуту вместо 30 сек

При THRESHOLD=5 и интервале 30 сек — с момента пропажи до shutdown проходит **2.5 минуты**. ИБП держит ~30 минут — запас >10x.
