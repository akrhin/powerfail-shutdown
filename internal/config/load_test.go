package config

import (
	"strings"
	"testing"
)

func TestDefaultConfig(t *testing.T) {
	cfg := DefaultConfig()
	if cfg.Detection.Mode != "ping" {
		t.Errorf("expected ping, got %s", cfg.Detection.Mode)
	}
	if cfg.Detection.Threshold != 3 {
		t.Errorf("expected 3, got %d", cfg.Detection.Threshold)
	}
	if cfg.Ping.Main != "192.168.1.1" {
		t.Errorf("expected 192.168.1.1, got %s", cfg.Ping.Main)
	}
}

func TestLoadMinimal(t *testing.T) {
	tomlData := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "192.168.1.1"
secondary = ""
`
	cfg, err := Load(strings.NewReader(tomlData))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Detection.Mode != "ping" {
		t.Errorf("expected ping, got %s", cfg.Detection.Mode)
	}
}

func TestLoadHA(t *testing.T) {
	tomlData := `
[detection]
mode = "ha"
threshold = 3

[ha]
url = "http://ha:8123"
token = "test123"

[[ha.entity]]
id = "binary_sensor.socket"
priority = 1

[[ha.entity]]
id = "binary_sensor.ups"
priority = 2
`
	cfg, err := Load(strings.NewReader(tomlData))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.HA.Entity) != 2 {
		t.Errorf("expected 2 HA entities, got %d", len(cfg.HA.Entity))
	}
}

func TestLoadInvalidMode(t *testing.T) {
	tomlData := `
[detection]
mode = "invalid"
`
	_, err := Load(strings.NewReader(tomlData))
	if err == nil {
		t.Fatal("expected error for invalid mode")
	}
}

func TestLoadHARequired(t *testing.T) {
	tomlData := `
[detection]
mode = "ha"
threshold = 3

[ha]
url = ""
token = ""
`
	_, err := Load(strings.NewReader(tomlData))
	if err == nil {
		t.Fatal("expected error for missing HA config")
	}
}

func TestLoadShutdownSequence(t *testing.T) {
	tomlData := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "192.168.1.1"

[[shutdown.step]]
type = "vm"
vmid = 100
timeout = 300

[[shutdown.step]]
type = "ct"
vmid = 107

[[shutdown.step]]
type = "wait"
timeout = 10

[[shutdown.step]]
type = "all_vm"

[[shutdown.step]]
type = "all_ct"
`
	cfg, err := Load(strings.NewReader(tomlData))
	if err != nil {
		t.Fatal(err)
	}

	if len(cfg.Shutdown.Sequence) != 5 {
		t.Fatalf("expected 5 steps, got %d", len(cfg.Shutdown.Sequence))
	}

	s := cfg.Shutdown.Sequence
	if s[0].Type != "vm" || s[0].VMID == nil || *s[0].VMID != 100 {
		t.Errorf("step 0 unexpected: %+v", s[0])
	}
	if s[3].Type != "all_vm" {
		t.Errorf("step 3 unexpected: %+v", s[3])
	}
}

func TestLoadDefaultShutdownSequence(t *testing.T) {
	tomlData := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "192.168.1.1"
`
	cfg, err := Load(strings.NewReader(tomlData))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Shutdown.Sequence) != 2 {
		t.Fatalf("expected default 2 steps, got %d", len(cfg.Shutdown.Sequence))
	}
	if cfg.Shutdown.Sequence[0].Type != "all_vm" {
		t.Errorf("expected all_vm, got %s", cfg.Shutdown.Sequence[0].Type)
	}
	if cfg.Shutdown.Sequence[1].Type != "all_ct" {
		t.Errorf("expected all_ct, got %s", cfg.Shutdown.Sequence[1].Type)
	}
}

func TestInvalidThreshold(t *testing.T) {
	tomlData := `
[detection]
threshold = 0
`
	_, err := Load(strings.NewReader(tomlData))
	if err == nil {
		t.Fatal("expected error for threshold=0")
	}
}

func TestLoadAnyMode(t *testing.T) {
	tomlData := `
[detection]
mode = "any"
threshold = 3

[ping]
main = "192.168.1.100"
secondary = "192.168.1.1"

[ha]
url = "http://ha:8123"
token = "tok"

[[ha.entity]]
id = "binary_sensor.socket"
priority = 1
`
	cfg, err := Load(strings.NewReader(tomlData))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Detection.Mode != "any" {
		t.Errorf("expected any, got %s", cfg.Detection.Mode)
	}
}
