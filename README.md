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
  ├── [PROXMOX] systemd timer → раз в 30 сек
  │   ├── powerfail-proxmox.sh (oneshot)
  │   ├── 1-2 провала → ждёт следующего тика
  │   ├── 3 провала → shutdown sequence:
  │   │   1. CT 107 (FS) — pct shutdown
  │   │   2. VM 100 (Xpenology) — qm shutdown
  │   │   3. Остальные VM и LXC — параллельно
  │   │   4. Force-stop остатков
  │   │   5. shutdown -h now
  │   └── ИБП держит ~30 мин — запас колоссальный
  │
  └── [XPENOLOGY] powerfail-xpenology.sh (резерв, crontab)
      ├── пинг роутера, 3 провала → poweroff
      └── страховка если proxmox завис
```

## Установка на Proxmox

```bash
bash <(curl -sL https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main/install.sh)
```

Скрипт скачает и установит:
- `/usr/local/bin/powerfail-proxmox.sh` — скрипт проверки
- `/etc/systemd/system/powerfail-proxmox.service` — oneshot
- `/etc/systemd/system/powerfail-proxmox.timer` — таймер на каждые 30 сек

## Настройка

Отредактируй переменные в начале `/usr/local/bin/powerfail-proxmox.sh`:

| Переменная | По умолчанию | Описание |
|-----------|-------------|----------|
| `ROUTER` | 192.168.1.1 | IP роутера (НЕ в ИБП) |
| `THRESHOLD` | 3 | Провалов пинга до shutdown |
| `XPENOLOGY_VMID` | 100 | ID VM с Xpenology |
| `FSCT_VMID` | 107 | ID CT с файловым сервером |
| `SHUTDOWN_TIMEOUT` | 600 | Ждать остановки VM (сек) |

## Порядок выключения

1. **CT 107** (FS) — первым, корректно размонтировать
2. **VM 100** (Xpenology) — NFS-сервер
3. **Остальные VM и LXC** — параллельно (NFS уже нет)
4. **Force-stop** — добиваем зависшие
5. **Proxmox host** — последним

## Тестирование

```bash
# Проверка сети и список VM/CT
/usr/local/bin/powerfail-proxmox.sh test-network

# Сухой прогон (ничего не выключает)
/usr/local/bin/powerfail-proxmox.sh --dry-run --debug
```

Чтобы проверить сценарий — выдерни кабель из роутера на 2 минуты.
Счётчик в `/tmp/powerfail_proxmox_counter` покажет 1→2→3 → shutdown.

## Обновление

```bash
bash <(curl -sL https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main/update.sh)
```

Сохранит резервную копию и перезапустит таймер.

## Логи

```bash
journalctl -u powerfail-proxmox.service -f
journalctl -t POWERFAIL
```

## Команды systemd

| Команда | Действие |
|---------|----------|
| `systemctl status powerfail-proxmox.timer` | Статус таймера |
| `systemctl status powerfail-proxmox.service` | Последний запуск |
| `journalctl -u powerfail-proxmox.service -f` | Лог в реальном времени |

## Настройка порогов

Если роутер иногда флапает — увеличь `THRESHOLD` до 5.
При THRESHOLD=5 и интервале 30 сек — до shutdown проходит **2.5 мин**.
ИБП держит ~30 мин — запас >10x.

## Установка на Xpenology (Synology DSM)

Xpenology выключается сама, Proxmox гасит её через qm — дополнительный скрипт страхует.

1. Загрузить `powerfail-xpenology.sh` на Xpenology
2. Создать задачу в планировщике: **каждые 5 минут**, пользователь root
3. Команда: `/volume1/scripts/powerfail-xpenology.sh`
