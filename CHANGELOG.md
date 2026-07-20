# Changelog

## v1.6.0 (2026-07-20)

### Bugfixes
- **P0** — `internal/agent/agent.go`: shutdown sequence не вызывал `systemctl poweroff` — агент писал сообщение и выходил без отключения хоста. Добавлен реальный вызов.
- **P0** — `internal/executor/executor.go`: `stopCT()` игнорировал переданный `timeout`, использовал хардкод 30 секунд. Теперь использует timeout из конфига.
- **P0** — `internal/detector/detector.go`: `detectAll()` использовал `pingHost()` вместо `d.pingFn()` — подмена для тестов не работала.
- **P0** — `internal/detector/detector.go`: `allHAOff = true` при пустом списке HA-сущностей — ложное срабатывание в режиме `all`. Исправлено: `allHAOff = len(cfg.HA.Entity) > 0`.
- **P1** — `internal/notifier/notifier.go`: невалидный proxy URL молча игнорировался. Добавлен `log.Printf` с предупреждением.

### Testing
- **Новые тесты**: detector (22 тестов, 4 режима), executor (12 тестов, 2 парсера), notifier (httptest.Server), agent (интеграционные с tempfs)
- **Total**: 9 → 73 тестов в 7 пакетах
- **Coverage**: все 4 режима детекции (ping, ha, any, all), parseQMRunning/PCTRunning, контекстная отмена, ошибки конфига

### Documentation
- **ARCHITECTURE.md**: добавлен poweroff delay + systemctl poweroff в диаграмму
- **AGENTS.md**: Go 1.26.4 → 1.26.5 (CI уже на 1.26.5)

## v1.5.0 (2026-07-19)

### Security
- **Git history scrub** — удалены реальные IP, HA token, chat_id из 50 коммитов (git-filter-repo)
- **LICENSE**: MIT с AI disclaimer

### Code Quality
- **Makefile**: `make verify` + `make verify-commands`, test с `-race`
- **Total tests**: 9 во всех 7 пакетах

### Documentation
- **README**: добавлены секции «Безопасность» и «Лицензия и отказ от ответственности»

## v1.4.0 (2026-07-18)

### Security
- **powerfail.toml.example**: real HA token `eyJhbG...` → `YOUR_HA_TOKEN`
- **powerfail.toml.example**: real IPs (`192.168.1.100`, `.75`, `.139`, chat_id) → placeholders (`192.168.1.100`, `123456789`)
- **internal/agent/agent.go**: all WriteFile perms `0644` → `0600` (G306)
- **cmd/agent/main.go**: maintenance WriteFile `0644` → `0600` (G306)
- **cmd/agent/main.go**: `os.MkdirAll` `/etc/powerfail` `0755` → `0750` (G301)
- **internal/config/load.go**: `filepath.Clean` on LoadFile path (G304 mitigation)
- **AGENTS.md**: `goreleaser` → `softprops/action-gh-release` (actual CI tool)

### Documentation
- **README**: added maintenance mode section + commands table fix
- **README**: replaced real IP in proxy example
- **ARCHITECTURE.md**: synced CI section to match actual workflow

### Infrastructure
- **deploy/install.sh**: fallback URL `main/bin/` (404) → latest release
- **deploy/**: removed stale `powerfail-xpenology.sh`
- **GitHub repo description**: updated (was `Proxmox + Xpenology`, now clean)

## v1.1.0 (2026-07-14)

- **Maintenance mode**: `powerfail-agent maintenance N` command
- **Lifecycle docs**: how it works as a systemd timer service
- **Release**: standalone binaries via CI (no goreleaser)

## v1.0.0 (2026-07-11)

- Initial release
- Go 1.26, golangci-lint v2
- TOML config (BurntSushi/toml)
- Modes: ping, HA, any, all
- Shutdown sequence: vm/ct/wait/all_vm/all_ct
- Telegram notifications with SOCKS5 proxy
- systemd timer installation
