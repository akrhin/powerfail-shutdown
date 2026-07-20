# Powerfail Shutdown — Architecture

## Overview

Системный агент для Proxmox, который детектит пропадание питания и корректно выключает виртуальные машины и контейнеры до того, как ИБП сядет.

## Components

```
┌─────────────┐     ┌────────────┐     ┌──────────┐
│  Detector   │────▶│   Agent    │────▶│ Executor │
│ (ping / HA) │     │ (counter)  │     │ (qm/pct) │
└─────────────┘     └────────────┘     └──────────┘
       │                   │
       ▼                   ▼
┌─────────────┐     ┌────────────┐
│  pingHost   │     │  Notifier  │
│ (exec.Command)│   │ (Telegram) │
└─────────────┘     └────────────┘
```

### Detector (`internal/detector/`)
- **Режимы:** `ping`, `ha`, `any`, `all`
- `pingHost` — `exec.Command("ping", "-c", "1", "-W", "2", host)`
- `getHAState` — HTTP-запрос к Home Assistant API
- **Найденный баг (починен):** `pingSec = false` при пустом `Secondary` считалось отказом → ложное срабатывание

### Agent (`internal/agent/`)
- Один цикл проверки: детект → счётчик → порог → уведомление → shutdown → уведомление
- Flag-файлы: `/root/.powerfail_occurred`, `/tmp/powerfail_counter`, `/tmp/.powerfail_active`

### Executor (`internal/executor/`)
- Последовательность шагов из конфига: `vm`, `ct`, `all_vm`, `all_ct`, `wait`
- Graceful shutdown → force stop при неудаче
- Работает через `qm` и `pct` CLI

### Notifier (`internal/notifier/`)
- Telegram через Bot API
- Прокси из TOML-конфига (SOCKS5)
- **Найденный баг (починен):** `proxyFromConfig` игнорировал параметр, всегда использовал `ProxyFromEnvironment`

### Config (`internal/config/`)
- TOML-формат
- Валидация всех полей + значения по умолчанию
- **Найденный баг (починен):** мёртвая ветка `if !md.IsDefined(...)` — staticcheck SA9003

## CLI Commands

| Команда | Назначение |
|---------|-----------|
| `run` | Один цикл проверки (для systemd timer) |
| `test-network` | Проверка ping/HA |
| `test-telegram` | Отправка тестового сообщения |
| `dry-run` | Имитация без shutdown |
| `maintenance` | Показать статус maintenance mode |
| `maintenance N` | Включить на N минут (1–120) |
| `maintenance 0` | Отключить сейчас |
| `install` | Установка systemd unit + timer |

## CI/CD Pipeline

```
lint → vulncheck → secrets-scan → test
       \          |             /
        →→→→→→→ build →→→→→→→→→→ release (только теги v*)
```

- **Go 1.26**, сборка на amd64 + arm64
- `golangci-lint` v2.12.2 (gosec, errcheck, staticcheck, govet)
- `govulncheck` — сканирование уязвимостей
- `gitleaks` — проверка утечки секретов
- `softprops/action-gh-release` — релиз на теги

## Security

- `.env` в `.gitignore`
- G204 (exec.Command) — by design, Proxmox CLI
- G301/G302/G306 (file permissions) — by design, flag/systemd files
- G101 (hardcoded credentials) — only in examples

## Как это работает как сервис

Установленный агент живёт как **systemd timer + oneshot service**:

```
каждые 30с: powerfail-agent.timer → powerfail-agent.service → powerfail-agent run
```

### Что происходит на каждый тик

```
Detector (ping / HA)
   │
   ├── Питание есть ──→ counter = 0 ──→ выход (тихо)
   │
   └── Питания нет ──→ counter++
        │
        ├── counter < threshold ──→ сохранить counter ──→ выход
        │
        └── counter ≥ threshold ──→ Shutdown sequence
              ├── Telegram: "Пропало питание"
              ├── Executor: шаги из конфига (vm → ct → wait → all_vm → all_ct)
              │   └── graceful shutdown, force stop если не ответил
              └── Флаг /root/.powerfail_occurred
              │
              └── Sleep(poweroff_delay_secs) → systemctl poweroff
```

### При восстановлении питания

Если `/root/.powerfail_occurred` существует:
1. Telegram: «Питание вернулось, отключение было в HH:MM»
2. Удалить все флаги

— Выйти до следующего тика.

### Maintenance mode

**Назначение:** временное отключение детекции при плановых работах (ребут роутера, замена ИБП, обслуживание).

**Команда:** `powerfail-agent maintenance N` (N = 1–120 минут)

**Как работает:**
1. Создаёт `/tmp/.powerfail_maintenance` с RFC3339-таймстампом окончания
2. **В каждом тике** — если файл существует и не просрочен:
   - счётчик сбрасывается в 0
   - Run() сразу возвращает `MAINTENANCE — skipping check`
3. **По истечении** — файл удаляется, следующий тик работает как обычно
4. **При `maintenance 0`** — файл удаляется немедленно
5. **При ребуте хоста** — флаг в `/tmp/` теряется, maintenance не восстанавливается
