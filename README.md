# UPS Power Failure Shutdown

Два скрипта для автоматического отключения сервера при пропадании электричества.

## Принцип работы

Детекция пропажи электричества через **ESP32-розетку** (пинг). Розетка подключена **перед ИБП** — если пропало 220В, она перестаёт пинговаться.  
Роутер в ИБП — локальная сеть и интернет остаются живы при отключении.

```
Пропало 220В
  │
  ├── ESP32-розетка перестаёт пинговаться
  ├── Proxmox считает провалы (THRESHOLD=3)
  ├── Порог достигнут → shutdown sequence
  │   1. CT 107 (FS) — pct shutdown
  │   2. VM 100 (Xpenology) — qm shutdown + ожидание остановки
  │   3. Остальные VM и LXC
  │   4. Force-stop оставшихся
  │   5. poweroff (хоста)
  │   6. Через 30c — ESPHome отключает розетку (физически режет 220В перед ИБП)
  │
  └── 220В вернулось → ESP32 включается → Proxmox стартует
      → таймер видит флаг → интернет есть → Telegram: ⚡ восстановлено
```

Уведомления в Telegram — **до** shutdown (пока есть интернет) и **после** восстановления (через флаг на диске).

## Установка

```bash
bash <(curl -sL https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main/install.sh)
```

## Настройка

Параметры в начале `/usr/local/bin/powerfail-proxmox.sh`:

| Переменная | По умолчанию | Описание |
|------------|-------------|----------|
| `ROUTER` | 192.168.1.1 | Роутер (не в ИБП, но в локальной сети) |
| `SOCKET_IP` | 192.168.1.100 | ESP32-розетка (без 220В не пингуется) |
| `THRESHOLD` | 3 | Провалов детекции до shutdown |
| `XPENOLOGY_VMID` | 100 | ID VM с Xpenology |
| `FSCT_VMID` | 107 | ID CT с файловым сервером |
| `SHUTDOWN_TIMEOUT` | 600 | Ждать остановки Xpenology (сек) |
| `POWEROFF_DELAY` | 30 | Пауза после poweroff перед отключением розетки |

## Telegram

Создай `/etc/powerfail/powerfail.conf` (не попадёт в git):

```bash
TG_BOT_TOKEN="***"
TG_CHAT_ID="123456789"
TG_PROXY="socks5h://192.168.1.100:1080"
```

Если Telegram не настроен — скрипт работает без уведомлений.

## Тестирование

```bash
/usr/local/bin/powerfail-proxmox.sh test-network
/usr/local/bin/powerfail-proxmox.sh --test-telegram
/usr/local/bin/powerfail-proxmox.sh --dry-run --debug
```

## Обновление

```bash
bash <(curl -sL https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main/update.sh)
```

## Порядок выключения

1. CT 107 (FS)
2. VM 100 (Xpenology — NFS) — ожидание полной остановки
3. Остальные VM/LXC
4. Force-stop
5. poweroff хоста
6. Отключение розетки (обесточивание ИБП)

## Архитектура

```
220В ──→ [ESP32-розетка] ──→ [ИБП] ──→ [Proxmox, роутер]
            ping  ↑                    ↑
              └──── Proxmox ───────────┘
```

Розетка **перед** ИБП — как только 220В пропадает, она перестаёт отвечать на ping.  
Роутер **после** ИБП — сеть и интернет живут ещё ~30-60 минут (ёмкости ИБП хватает на shutdown).

### Страховочный скрипт для Xpenology

`powerfail-xpenology.sh` работает на самом Xpenology — он проверяет связь с роутером.  
Установка на Synology/Xpenology через Task Scheduler (запуск раз в минуту).
