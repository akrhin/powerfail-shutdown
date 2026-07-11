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

## Как работать

1. Сначала читай `ARCHITECTURE.md` — там описание компонентов
2. Тестируй: `go vet ./... && go test ./... -count=1`
3. Линт: `golangci-lint run`
4. Пуш только когда CI зелёный
5. Релиз: `git tag v1.x.x && git push --tags`
