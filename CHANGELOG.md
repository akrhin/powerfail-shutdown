# Changelog

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
