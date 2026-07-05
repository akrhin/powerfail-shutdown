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
  │   │   1. Ждёт пока Xpenology (VM 100) выключится (свой скрипт)
  │   │   2. Гасит остальные VM и LXC (NFS уже неактивна)
  │   │   3. Force-stop остатков
  │   │   4. shutdown -h now
  │   └── Время: ~3-5 мин, ИБП держит ~30 мин
  │
  └── [XPENOLOGY] powerfail-xpenology.sh (резерв, crontab)
      ├── пинг роутера, 3 провала → poweroff
      └── страховка если proxmox завис
```

Запас по батарее колоссальный — можно не спешить.

---

## Установка на Proxmox

### 1. Скопировать скрипты

```bash
# На proxmox хосте
scp powerfail-proxmox.sh root@proxmox-host:/usr/local/bin/
scp powerfail-proxmox.service root@proxmox-host:/etc/systemd/system/
chmod +x /usr/local/bin/powerfail-proxmox.sh
```

*(Или скопируй через веб-интерфейс Proxmox в shell)*

### 2. Настроить параметры (опционально)

Отредактируй переменные в начале скрипта:

```bash
ROUTER="192.168.1.1"        # IP роутера
THRESHOLD=3                  # сколько провалов пинга до shutdown
CHECK_INTERVAL=30            # секунд между проверками
XPENOLOGY_VMID=100           # ID VM с Xpenology
SHUTDOWN_TIMEOUT=600         # макс ждать xpenology (сек)
```

### 3. Запустить как systemd-сервис

```bash
systemctl daemon-reload
systemctl enable powerfail-proxmox.service
systemctl start powerfail-proxmox.service
systemctl status powerfail-proxmox.service  # проверить
```

### 4. Проверить что работает

```bash
# Режим test-network — однократная проверка связи
/usr/local/bin/powerfail-proxmox.sh test-network

# Режим сухого прогона — имитация shutdown без выключения
/usr/local/bin/powerfail-proxmox.sh --dry-run --debug
```

---

## Установка на Xpenology (Synology DSM)

### 1. Создать задачу в планировщике

- **Панель управления → Планировщик задач → Создать → Запланированная задача → Пользовательский скрипт**
- **Общие:** Включить, пользователь `root`
- **Расписание:** «Выполнять каждые 5 минут» (Run every 5 minutes)
- **Настройки задачи — Код:**

```bash
# Путь к скрипту (измени если положил в другое место)
/volume1/scripts/powerfail-xpenology.sh
```

### 2. Или как скрипт запуска — положить в автозагрузку

```bash
# Положить скрипт в /usr/local/etc/rc.d/ и chmod +x
# DSM сам подхватит при старте (но cron надёжнее)
```

### 3. Сначала протестировать

```bash
# сухой прогон на время теста
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

# 3. Если всё устраивает — удали --dry-run и дай настоящий тест
```

### На Xpenology:

```bash
# 1. Проверка пинга
/volume1/scripts/powerfail-xpenology.sh --dry-run --debug

# 2. Сделай роутер недоступным
# Через 3 цикла (15 мин в cron) скрипт скажет "POWER FAILURE — would poweroff"
```

### Поведение счётчика:

Чтобы проверить сценарий «пропало электричество» — выдерни кабель из роутера или выключи его на 2 минуты. Счётчик в `/tmp/powerfail_proxmox_counter` покажет `1`, потом `2`, потом `3` → shutdown.

Если кабель вернуть — счётчик сбросится в `0`.

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
# Логи в syslog
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
2026-07-05 18:01:30 [POWERFAIL] Phase 1/4: Shutting down non-critical VMs...
2026-07-05 18:01:30 [POWERFAIL] [DRY-RUN] Would shut down VM 101 (plex)
2026-07-05 18:01:30 [POWERFAIL] Phase 2/4: Shutting down Xpenology (VM 100)...
2026-07-05 18:01:30 [POWERFAIL] [DRY-RUN] Xpenology shutdown SIMULATED
2026-07-05 18:01:30 [POWERFAIL] Phase 4/4: Shutting down Proxmox host...
2026-07-05 18:01:30 [POWERFAIL] [DRY-RUN] *** SHUTDOWN SIMULATED ***
```

---

## Настройка порогов

Если роутер иногда флапает (перезагружается, лаги):

```bash
# В начале каждого скрипта поправить:
THRESHOLD=5    # вместо 3 — больше толерантности
CHECK_INTERVAL=60  # раз в минуту вместо 30 сек
```

При THRESHOLD=5 и интервале 30 сек — с момента пропажи до shutdown проходит **2.5 минуты**. ИБП держит ~30 минут — запас >10x.

---

## Файлы

| Файл | Размер | Назначение |
|------|--------|-----------|
| `powerfail-proxmox.sh` | ~4 KB | Основной оркестратор на Proxmox |
| `powerfail-proxmox.service` | 250 B | systemd unit |
| `powerfail-xpenology.sh` | ~2 KB | Резервный скрипт на Xpenology |
| `README.md` | — | Эта документация |
