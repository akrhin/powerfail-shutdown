.PHONY: all build test vet lint clean release

APP_NAME   := powerfail-agent
BIN_DIR    := ./bin
GO_FLAGS   := -ldflags="-s -w -X main.version=$(VERSION)"

VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

all: build

build:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build $(GO_FLAGS) -o $(BIN_DIR)/$(APP_NAME) ./cmd/agent

build-all:
	@mkdir -p $(BIN_DIR)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build $(GO_FLAGS) -o $(BIN_DIR)/$(APP_NAME)-linux-amd64 ./cmd/agent
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build $(GO_FLAGS) -o $(BIN_DIR)/$(APP_NAME)-linux-arm64 ./cmd/agent

test:
	go test -v -cover ./...

vet:
	go vet ./...

lint:
	golangci-lint run ./...

clean:
	rm -rf $(BIN_DIR)

install:
	cp $(BIN_DIR)/$(APP_NAME) /usr/local/bin/$(APP_NAME)
	chmod +x /usr/local/bin/$(APP_NAME)
	mkdir -p /etc/powerfail

uninstall:
	-systemctl disable --now powerfail-agent.timer 2>/dev/null
	-rm -f /etc/systemd/system/powerfail-agent.service
	-rm -f /etc/systemd/system/powerfail-agent.timer
	systemctl daemon-reload
	rm -f /usr/local/bin/$(APP_NAME)

release: build-all
	@echo "Built:"
	@ls -lh $(BIN_DIR)/*
