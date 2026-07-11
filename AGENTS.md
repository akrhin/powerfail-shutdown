# Powerfail Shutdown — Agent Instructions

## Что это

Системный агент для корректного выключения Proxmox VM/CT при пропадании питания. Ставится как systemd timer (проверка каждые 30с).

## Ключевые факты

- **Язык:** Go 1.26
- **Конфиг:** TOML (BurntSushi/toml)
- **Архитектура:** `ARCHITECTURE.md`
- **CI:** `.github/workflows/ci.yml`
- **Линтер:** `golangci-lint` v2.12.2
- **Go-аргументы:** `-ldflags="-s -w -X main.version=$(VERSION)"`

## Сборка

```bash
make build              # linux/amd64
make build-all          # amd64 + arm64
make test               # go test -v -cover
```

## CI Pipeline

| Шаг | Инструмент | Ожидание |
|-----|-----------|----------|
| Lint | golangci-lint v2.12.2 | exit 0 |
| Vuln Check | govulncheck | advisory, exit != 0 при реальных CVE |
| Secrets | gitleaks | 0 leaks |
| Test | go test -v -cover -race | exit 0 |
| Build | make build-all | exit 0 |
| Release | goreleaser (только теги v*) | — |

## Конфигурация golangci-lint (v2)

```yaml
version: "2"
linters:
  default: none
  enable: [errcheck, govet, ineffassign, staticcheck, unused, gosec, misspell]
  settings:
    gosec:
      excludes: [G204, G304, G301, G302, G306, G101]
formatters:
  enable: [gofmt]
```

## Известные pitfalls

1. **`golangci-lint` v1 → v2:** `gosimple` влит в `staticcheck`, `gofmt` отделён в `formatters`, `linters-settings` → `linters.settings`, требуется `version: "2"` + `linters.default: none`
2. **Go 1.24+ and golangci-lint:** v1.64.8 собран с Go 1.24 и НЕ может линтить код на 1.25+. Используйте v2.x линтера
3. **govulncheck всегда находит CVE в stdlib:** это нормально, делает `|| true` в CI если блокирует пайплайн
4. **Go 1.26.4 → GO-2026-5856:** crypt/tls ECH privacy leak. Фиксится в 1.26.5. Пинать версию в `setup-go`
5. **errcheck на `defer Close()`:** подавлять через `defer func() { _ = ...Close() }()`
6. **errcheck на `os.Remove`:** подавлять через `_ = os.Remove(...)`

## Как это работает как сервис

### Жизненный цикл

Агент ставится как **systemd timer**, запускающий `Type=oneshot` service каждые 30 секунд:

```
$ systemctl list-timers --all | grep powerfail
└─ powerfail-agent.timer ────────────────────��─────────────────┐
   каждые 30с (OnCalendar=*-*-* *:*:0/30)                       │
   │                                                             │
   ▼ запускает                                                   │
powerfail-agent.service                                          │
  Type=oneshot                                                   │
  ExecStart=/usr/local/bin/powerfail-agent run                   │
                        ─── и выходит ───────────────────────────┘
```

### Каждый тик (30 секунд) происходит:

```
1. Detector — проверяет, есть ли питание
   ├── PING: пинг ESP32-розетки (она перед ИБП, без 220 не пингуется)
   └── HA: запрос к Home Assistant (сущности с приоритетами)

2. Если питания нет:
   ├── counter++ (/tmp/powerfail_counter)
   ├── Порог не достигнут → просто сохранить counter, выйти
   └── Порог достигнут → перейти к shutdown

3. Shutdown sequence:
   ├── Telegram: "Пропало питание, выключаюсь..."
   ├── Executor: шаги из конфига (vm → ct → wait → all_vm → all_ct)
   │   ├── graceful shutdown (qm shutdown, pct shutdown)
   │   └── если не выключился → force stop (qm stop, pct stop)
   ├── Создать флаг: /root/.powerfail_occurred (чтобы не повторять)
   └── Создать флаг: /tmp/.powerfail_active (процесс shutdown идёт)

4. Если питание ВЕРНУЛОСЬ + есть флаг /root/.powerfail_occurred:
   ├── Telegram: "Питание вернулось, отключение было в HH:MM"
   ├── Удалить /root/.powerfail_occurred
   ├── Удалить /tmp/powerfail_counter
   └── Удалить /tmp/.powerfail_active

5. Если питание есть + нет флага: тихо выйти (ничего не делать)
```

### Флаг-файлы

| Файл | Назначение |
|------|-----------|
| `/tmp/powerfail_counter` | Счётчик последовательных неудачных проверок. Сбрасывается при любой успешной проверке. |
| `/tmp/.powerfail_active` | Процесс shutdown уже начат — блокирует повторный shutdown до окончания или reboot. |
| `/root/.powerfail_occurred` | Флаг «отключение уже было» — чтобы после восстановления отправить уведомление и сбросить счётчик. |

### Логи

```bash
journalctl -u powerfail-agent.service -f    # последний запуск
journalctl -u powerfail-agent.timer         # таймер
```

### Статус

```bash
systemctl status powerfail-agent.timer      # включён ли таймер
cat /tmp/powerfail_counter                  # сколько раз подряд нет пинга
cat /tmp/.powerfail_active                  # идёт ли shutdown
cat /root/.powerfail_occurred               # было ли отключение
```

1. Сначала читай `ARCHITECTURE.md` — там описание компонентов
2. Тестируй: `go vet ./... && go test ./... -count=1`
3. Линт: `golangci-lint run`
4. Пуш только когда CI зелёный
5. Релиз: `git tag v1.x.x && git push --tags`
