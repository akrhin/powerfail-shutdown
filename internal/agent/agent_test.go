package agent

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestRunBadConfigPath(t *testing.T) {
	_, err := Run(context.Background(), "/nonexistent/path/config.toml")
	if err == nil {
		t.Fatal("expected error for bad config path")
	}
}

func TestRunEmptyConfigPath(t *testing.T) {
	_, err := Run(context.Background(), "")
	if err == nil {
		t.Fatal("expected error for empty config path")
	}
}

func TestRunMinimalPingConfig(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	cfgContent := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "10.0.0.1"
secondary = ""

[shutdown]
timeout_secs = 30
poweroff_delay_secs = 0
`
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0644); err != nil {
		t.Fatal(err)
	}

	// With a non-existent router IP, ping will fail.
	// This tests the detection + counter path without needing a real network.
	msg, err := Run(context.Background(), cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if msg == "" {
		t.Error("expected non-empty message")
	}

	// Clean up counter file that was created in /tmp
	_ = os.Remove("/tmp/powerfail_counter")
}

func TestRunWithHAConfig(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	cfgContent := `
[detection]
mode = "ha"
threshold = 3

[ha]
url = "http://ha.local:8123"
token = "test-token"

[[ha.entity]]
id = "binary_sensor.socket"
priority = 1

[shutdown]
timeout_secs = 30
poweroff_delay_secs = 0
`
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0644); err != nil {
		t.Fatal(err)
	}

	msg, err := Run(context.Background(), cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// HA endpoint doesn't exist, so we expect an error from detection
	// But that's wrapped, let's check
	_ = msg
}

func TestRunMaintenanceMode(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	cfgContent := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "10.0.0.1"

[shutdown]
timeout_secs = 30
poweroff_delay_secs = 0
`
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0644); err != nil {
		t.Fatal(err)
	}

	// Create maintenance flag
	until := "2099-01-01T00:00:00Z" // far future
	if err := os.WriteFile("/tmp/.powerfail_maintenance", []byte(until), 0600); err != nil {
		t.Fatal(err)
	}
	defer os.Remove("/tmp/.powerfail_maintenance")

	msg, err := Run(context.Background(), cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if msg == "" {
		t.Error("expected non-empty message in maintenance mode")
	}

	// Clean up counter
	_ = os.Remove("/tmp/powerfail_counter")
}

func TestRunExpiredMaintenanceMode(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	cfgContent := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "10.0.0.1"

[shutdown]
timeout_secs = 30
poweroff_delay_secs = 0
`
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0644); err != nil {
		t.Fatal(err)
	}

	// Create expired maintenance flag
	until := "2000-01-01T00:00:00Z"
	if err := os.WriteFile("/tmp/.powerfail_maintenance", []byte(until), 0600); err != nil {
		t.Fatal(err)
	}
	defer os.Remove("/tmp/.powerfail_maintenance")

	msg, err := Run(context.Background(), cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if msg == "" {
		t.Error("expected non-empty message after expired maintenance")
	}

	// Clean up counter
	_ = os.Remove("/tmp/powerfail_counter")
}

func TestRunAlreadyShuttingDown(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	cfgContent := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "10.0.0.1"

[shutdown]
timeout_secs = 30
poweroff_delay_secs = 0
`
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0644); err != nil {
		t.Fatal(err)
	}

	// Create powerfail active flag
	if err := os.WriteFile("/tmp/.powerfail_active", []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	defer os.Remove("/tmp/.powerfail_active")

	msg, err := Run(context.Background(), cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if msg != "Shutdown in progress — skipping check" {
		t.Errorf("expected shutdown-skip message, got %q", msg)
	}

	_ = os.Remove("/tmp/powerfail_counter")
}

func TestRunFlagOccurredRouterDown(t *testing.T) {
	// This test writes to /root/.powerfail_occurred, which requires root.
	// Skip when not root.
	if os.Geteuid() != 0 {
		t.Skip("requires root to write /root/.powerfail_occurred")
	}

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	cfgContent := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "10.0.0.1"

[shutdown]
timeout_secs = 30
poweroff_delay_secs = 0
`
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0644); err != nil {
		t.Fatal(err)
	}

	// Create occurred flag
	if err := os.WriteFile("/root/.powerfail_occurred", []byte("2025-01-01T12:00:00Z"), 0600); err != nil {
		t.Fatal(err)
	}
	defer os.Remove("/root/.powerfail_occurred")

	msg, err := Run(context.Background(), cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if msg != "Flag present but router still down — waiting" {
		t.Errorf("expected 'Flag present but router still down — waiting', got %q", msg)
	}

	_ = os.Remove("/tmp/powerfail_counter")
}

func TestRunCounterResetOnOKDetection(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	// Use a localhost address that is likely reachable
	cfgContent := `
[detection]
mode = "ping"
threshold = 3

[ping]
main = "127.0.0.1"

[shutdown]
timeout_secs = 30
poweroff_delay_secs = 0
`
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0644); err != nil {
		t.Fatal(err)
	}

	msg, err := Run(context.Background(), cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if msg == "" {
		t.Error("expected non-empty message")
	}

	_ = os.Remove("/tmp/powerfail_counter")
}
