# UPS Power Failure Shutdown

Два скрипта для автоматического отключения сервера при пропадании электричества.
APC Back-UPS ES 400, без USB/сеть, ~60 Вт нагрузка.

## Принцип работы

Детекция пропажи электричества через **умную розетку** в Home Assistant.
Роутер в ИБП — локальная сеть жива, но интернета нет.

Уведомление в Telegram отправляется **после восстановления питания** — через флаг на диске.

```
Пропало Электричество
  │
  ├── Розетка OFF → HA детектит
  ├── Proxmox читает HA API (http://192.168.1.100:8123)
  ├── 3 раза OFF подряд → shutdown sequence
  │   1. CT 107 (FS) — pct shutdown
  │   2. VM 100 (Xpenology) — qm shutdown
  │   3. Остальные VM и LXC
  │   4. Force-stop
  │   5. shutdown -h now
  ├── Флаг: /root/.powerfail_occurred
  │
  └── Питание вернулось → reboot → таймер видит флаг
      → интернет есть → Telegram: ⚡ Питание восстановлено
      → удаляет флаг
```

## Установка

```bash
bash <(curl -sL https://raw.githubusercontent.com/akrhin/powerfail-shutdown/main/install.sh)
```

## Настройка

Параметры в начале `/usr/local/bin/powerfail-proxmox.sh`:

| Переменная | По умолчанию | Описание |
|-----------|-------------|----------|
| `THRESHOLD` | 3 | Провалов детекции до shutdown |
| `XPENOLOGY_VMID` | 100 | ID VM с Xpenology |
| `FSCT_VMID` | 107 | ID CT с файловым сервером |
| `SHUTDOWN_TIMEOUT` | 600 | Ждать остановки VM (сек) |

## Telegram + HA

Создай `/etc/powerfail/powerfail.conf` (не попадёт в git):

```bash
TG_BOT_TOKEN="***"
TG_CHAT_ID="123456789"
TG_PROXY="socks5h://192.168.1.100:1080"

HA_API_URL="http://192.168.1.100:8123/api/states/binary_sensor.athom_wall_outlet_dd4e0a_status"
HA_API_TOKEN="***"
```

Если HA не настроен — работает по пингу интернета (8.8.8.8).
Если Telegram не настроен — не шлёт уведомления.

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
2. VM 100 (Xpenology — NFS)
3. Остальные VM/LXC
4. Force-stop
5. Proxmox host
