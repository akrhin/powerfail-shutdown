// Package config handles loading, validation, and merging of TOML configuration.
package config

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
	"github.com/akrhin/powerfail-shutdown/internal/models"
)

// DefaultConfig returns a configuration with sensible defaults.
func DefaultConfig() *models.Config {
	return &models.Config{
		Detection: models.DetectionConfig{
			Mode:      "ping",
			Threshold: 3,
		},
		Ping: models.PingConfig{
			Main:      "192.168.1.1",
			Secondary: "",
		},
		HA: models.HAConfig{
			URL:    "",
			Token:  "",
			Entity: nil,
		},
		Shutdown: models.ShutdownConfig{
			TimeoutSecs:       600,
			PoweroffDelaySecs: 30,
			Sequence:          nil,
		},
		Telegram: nil,
	}
}

// LoadFile reads a TOML file and decodes it into a Config.
func LoadFile(path string) (*models.Config, error) {
	path = filepath.Clean(path)
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open config: %w", err)
	}
	defer func() { _ = f.Close() }()
	return Load(f)
}

// Load reads TOML from r and decodes it, merging with defaults.
func Load(r io.Reader) (*models.Config, error) {
	cfg := DefaultConfig()
	md, err := toml.NewDecoder(r).Decode(cfg)
	if err != nil {
		return nil, fmt.Errorf("decode config: %w", err)
	}
	if err := validate(cfg, md); err != nil {
		return nil, fmt.Errorf("validate config: %w", err)
	}
	return cfg, nil
}

func validate(cfg *models.Config, md toml.MetaData) error {
	if cfg.Detection.Threshold < 1 {
		return fmt.Errorf("detection.threshold must be >= 1, got %d", cfg.Detection.Threshold)
	}

	switch cfg.Detection.Mode {
	case "ping", "ha", "any", "all":
		// valid
	default:
		return fmt.Errorf("detection.mode must be one of: ping, ha, any, all; got %q", cfg.Detection.Mode)
	}

	// Validate ping targets if mode uses ping
	if cfg.Detection.Mode == "ping" || cfg.Detection.Mode == "any" || cfg.Detection.Mode == "all" {
		if cfg.Ping.Main == "" {
			return fmt.Errorf("ping.main is required in mode %q", cfg.Detection.Mode)
		}
	}

	// Validate HA config if mode uses ha
	if cfg.Detection.Mode == "ha" || cfg.Detection.Mode == "any" || cfg.Detection.Mode == "all" {
		if cfg.HA.URL == "" {
			return fmt.Errorf("ha.url is required in mode %q", cfg.Detection.Mode)
		}
		if cfg.HA.Token == "" {
			return fmt.Errorf("ha.token is required in mode %q", cfg.Detection.Mode)
		}
		if len(cfg.HA.Entity) == 0 {
			return fmt.Errorf("at least one ha.entity is required in mode %q", cfg.Detection.Mode)
		}
		// Check priority values
		hasPrimary := false
		for i, e := range cfg.HA.Entity {
			if e.EntityID == "" {
				return fmt.Errorf("ha.entity[%d].id is empty", i)
			}
			if e.Priority == 1 {
				hasPrimary = true
			}
		}
		if !hasPrimary {
			return fmt.Errorf("at least one ha.entity must have priority = 1 (primary)")
		}
	}

	// Validate shutdown sequence
	if len(cfg.Shutdown.Sequence) == 0 {
		// Default: shutdown all VMs, then all CTs
		cfg.Shutdown.Sequence = []models.Step{
			{Type: "all_vm"},
			{Type: "all_ct"},
		}
	}
	for i, s := range cfg.Shutdown.Sequence {
		switch s.Type {
		case "vm", "ct":
			if s.VMID == nil {
				return fmt.Errorf("shutdown.step[%d]: vmid is required for type %q", i, s.Type)
			}
		case "wait":
			if s.Timeout == nil || *s.Timeout <= 0 {
				return fmt.Errorf("shutdown.step[%d]: timeout is required for type %q", i, s.Type)
			}
		case "all_vm", "all_ct":
			// no extra params needed
		default:
			return fmt.Errorf("shutdown.step[%d]: unknown type %q (valid: vm, ct, wait, all_vm, all_ct)", i, s.Type)
		}
	}

	return nil
}
