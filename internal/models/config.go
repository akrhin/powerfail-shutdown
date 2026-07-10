// Package models defines the configuration structure for powerfail-shutdown.
package models

// Config is the root configuration structure.
type Config struct {
	Detection DetectionConfig `toml:"detection"`
	Ping      PingConfig      `toml:"ping"`
	HA        HAConfig        `toml:"ha"`
	Shutdown  ShutdownConfig  `toml:"shutdown"`
	Telegram  *TelegramConfig `toml:"telegram"`
}

// DetectionConfig controls how power failure is detected.
type DetectionConfig struct {
	Mode      string `toml:"mode"      comment:"ping | ha | any | all"`
	Threshold int    `toml:"threshold" comment:"consecutive failures before shutdown"`
}

// PingConfig defines ping targets.
type PingConfig struct {
	Main      string `toml:"main"      comment:"primary target (suspicion)"`
	Secondary string `toml:"secondary" comment:"secondary target (confirmation)"`
}

// HAConfig defines Home Assistant connection and entities.
type HAConfig struct {
	URL    string      `toml:"url"    comment:"HA API base URL"`
	Token  string      `toml:"token"  comment:"HA long-lived access token"`
	Entity []HAEntity  `toml:"entity" comment:"entities to monitor, first is primary"`
}

// HAEntity represents a single HA entity to monitor.
type HAEntity struct {
	EntityID string `toml:"id"       comment:"entity_id, e.g. binary_sensor.socket"`
	Priority int    `toml:"priority" comment:"1=primary (suspicion), 2+=secondary (confirmation)"`
}

// ShutdownConfig controls the shutdown sequence.
type ShutdownConfig struct {
	TimeoutSecs     int    `toml:"timeout_secs"        comment:"max wait for VM shutdown (seconds)"`
	PoweroffDelaySecs int  `toml:"poweroff_delay_secs"  comment:"delay before poweroff (seconds)"`
	Sequence        []Step `toml:"step"                 comment:"ordered shutdown steps"`
}

// Step is a single shutdown step.
type Step struct {
	Type    string `toml:"type"    comment:"vm | ct | wait | all_vm | all_ct"`
	VMID    *int   `toml:"vmid"    comment:"VM or CT ID (required for vm/ct)"`
	Timeout *int   `toml:"timeout" comment:"per-step timeout override (seconds)"`
}

// TelegramConfig for notifications.
type TelegramConfig struct {
	BotToken string `toml:"bot_token" comment:"Telegram bot token"`
	ChatID   int64  `toml:"chat_id"   comment:"Telegram chat ID"`
	Proxy    string `toml:"proxy"     comment:"SOCKS5 proxy (optional)"`
}
