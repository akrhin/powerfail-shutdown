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
- `goreleaser` — рели�� на теги

## Security

- `.env` в `.gitignore`
- G204 (exec.Command) — by design, Proxmox CLI
- G301/G302/G306 (file permissions) — by design, flag/systemd files
- G101 (hardcoded credentials) — only in examples
