// Command agent runs the powerfail shutdown monitor.
//
// Usage:
//
//	powerfail-agent run                    — one check cycle (systemd timer)
//	powerfail-agent run --config /etc/powerfail/powerfail.conf
//	powerfail-agent test-network           — test ping/HA connectivity
//	powerfail-agent test-telegram          — send a test message
//	powerfail-agent dry-run                — simulate shutdown sequence
//	powerfail-agent install                — install systemd unit + timer
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/akrhin/powerfail-shutdown/internal/agent"
	"github.com/akrhin/powerfail-shutdown/internal/config"
	"github.com/akrhin/powerfail-shutdown/internal/detector"
	"github.com/akrhin/powerfail-shutdown/internal/notifier"
)

var defaultConfig = "/etc/powerfail/powerfail.conf"

func main() {
	cfgFlag := flag.String("config", defaultConfig, "path to config file")
	flag.Parse()

	args := flag.Args()
	if len(args) == 0 {
		args = []string{"run"}
	}

	ctx := context.Background()

	switch args[0] {
	case "run":
		msg, err := agent.Run(ctx, *cfgFlag)
		if err != nil {
			log.Fatalf("ERROR: %v", err)
		}
		log.Println(msg)

	case "test-network":
		testNetwork(*cfgFlag)

	case "test-telegram":
		testTelegram(*cfgFlag)

	case "dry-run":
		dryRun(*cfgFlag)

	case "install":
		install()

	case "maintenance":
		maintenanceCmd(args)

	default:
		fmt.Fprintf(os.Stderr, "Usage: powerfail-agent [--config path] <command>\n")
		fmt.Fprintf(os.Stderr, "Commands:\n")
		fmt.Fprintf(os.Stderr, "  run              One check cycle (for systemd timer)\n")
		fmt.Fprintf(os.Stderr, "  test-network     Test ping/HA configuration\n")
		fmt.Fprintf(os.Stderr, "  test-telegram    Send a test Telegram message\n")
		fmt.Fprintf(os.Stderr, "  dry-run          Simulate without shutting down\n")
		fmt.Fprintf(os.Stderr, "  maintenance [N]  Enable/disable/status maintenance mode (N = minutes, 0 = off)\n")
		fmt.Fprintf(os.Stderr, "  install          Install systemd timer + service\n")
		os.Exit(1)
	}
}

func testNetwork(path string) {
	cfg, err := config.LoadFile(path)
	if err != nil {
		log.Fatalf("Config error: %v", err)
	}

	det := detector.New(cfg)
	ctx := context.Background()

	fmt.Println("=== Powerfail Network Test ===")
	fmt.Println()

	result, err := det.Detect(ctx)
	if err != nil {
		fmt.Printf("❌ Detection error: %v\n", err)
	}

	fmt.Printf("  Suspicion:    %v\n", result.Suspicion)
	fmt.Printf("  Confirmation: %v\n", result.Confirmation)
	fmt.Printf("  Reason:       %s\n", result.Reason)
	fmt.Println()

	// Show VM/CT status via CLI
	if out, err := exec.Command("qm", "list").Output(); err == nil {
		vms := string(out)
		if vms != "" {
			fmt.Println("VMs:")
			for _, line := range strings.Split(vms, "\n") {
				fields := strings.Fields(line)
				if len(fields) >= 3 && (fields[0] == "VMID" || fields[2] == "running") {
					fmt.Printf("  %s\n", line)
				}
			}
		}
	}
	if out, err := exec.Command("pct", "list").Output(); err == nil {
		cts := string(out)
		if cts != "" {
			fmt.Println("CTs:")
			for _, line := range strings.Split(cts, "\n") {
				fields := strings.Fields(line)
				if len(fields) >= 2 && (fields[0] == "CTID" || fields[1] == "running") {
					fmt.Printf("  %s\n", line)
				}
			}
		}
	}

	if _, err := os.Stat("/root/.powerfail_occurred"); err == nil {
		data, _ := os.ReadFile("/root/.powerfail_occurred")
		fmt.Printf("\n⚠️  Powerfail flag: %s\n", strings.TrimSpace(string(data)))
	}

	fmt.Println()
	fmt.Println("Test complete.")
}

func testTelegram(path string) {
	cfg, err := config.LoadFile(path)
	if err != nil {
		log.Fatalf("Config error: %v", err)
	}

	notif := notifier.New(cfg.Telegram)
	if notif == nil {
		log.Fatal("❌ Telegram not configured. Check telegram.bot_token and telegram.chat_id")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	ts := time.Now().Format("2006-01-02 15:04:05")
	if err := notif.SendPlain(ctx, fmt.Sprintf("[%s] ✅ Test — powerfail-agent is working.", ts)); err != nil {
		log.Fatalf("❌ Send failed: %v", err)
	}
	fmt.Println("✅ Test message sent!")
}

func dryRun(path string) {
	log.Println("⚠️  DRY RUN — no actual shutdown will occur")
	msg, err := agent.Run(context.Background(), path)
	if err != nil {
		log.Printf("⚠️  Dry run error (may be expected): %v", err)
	}
	log.Println(msg)
	log.Println("⚠️  DRY RUN COMPLETE — no changes applied")
}

func maintenanceCmd(args []string) {
	const maintenanceFile = "/tmp/.powerfail_maintenance"

	if len(args) > 1 && args[1] == "0" {
		_ = os.Remove(maintenanceFile)
		fmt.Println("✅ Maintenance mode disabled.")
		return
	}

	if len(args) > 1 {
		minutes, err := strconv.Atoi(args[1])
		if err != nil || minutes < 1 || minutes > 120 {
			log.Fatalf("Invalid duration %q — use 1–120 minutes", args[1])
		}

		until := time.Now().Add(time.Duration(minutes) * time.Minute)
		if err := os.WriteFile(maintenanceFile, []byte(until.Format(time.RFC3339)), 0644); err != nil {
			log.Fatalf("Write maintenance flag: %v", err)
		}
		fmt.Printf("✅ Maintenance mode enabled for %d min — active until %s\n", minutes, until.Format("15:04"))
		return
	}

	// Show status
	data, err := os.ReadFile(maintenanceFile)
	if err != nil {
		fmt.Println("ℹ️  Maintenance mode is OFF.")
		return
	}
	until, parseErr := time.Parse(time.RFC3339, strings.TrimSpace(string(data)))
	if parseErr != nil || time.Now().After(until) {
		fmt.Println("ℹ️  Maintenance mode expired. Run `powerfail-agent maintenance 0` to clean up.")
		return
	}
	fmt.Printf("ℹ️  Maintenance mode ON — active until %s (%s remaining)\n",
		until.Format("15:04"), time.Until(until).Round(time.Second))
}

func install() {
	fmt.Println("Installing systemd units...")
	if os.Geteuid() != 0 {
		log.Fatal("install must be run as root")
	}
	// Create config directory
	if err := os.MkdirAll("/etc/powerfail", 0755); err != nil {
		log.Fatalf("create config dir: %v", err)
	}

	// Systemd service unit
	service := `[Unit]
Description=Powerfail Agent

[Service]
Type=oneshot
ExecStart=/usr/local/bin/powerfail-agent run --config /etc/powerfail/powerfail.conf
`
	if err := os.WriteFile("/etc/systemd/system/powerfail-agent.service", []byte(service), 0644); err != nil {
		log.Fatalf("write service: %v", err)
	}

	// Systemd timer — every 30s
	timer := `[Unit]
Description=Powerfail Agent (check every 30s)
Requires=powerfail-agent.service

[Timer]
OnCalendar=*-*-* *:*:0/30
Persistent=false
AccuracySec=1

[Install]
WantedBy=timers.target
`
	if err := os.WriteFile("/etc/systemd/system/powerfail-agent.timer", []byte(timer), 0644); err != nil {
		log.Fatalf("write timer: %v", err)
	}

	mustExec("systemctl", "daemon-reload")
	mustExec("systemctl", "enable", "powerfail-agent.timer")
	mustExec("systemctl", "start", "powerfail-agent.timer")

	fmt.Println("✅ Systemd timer installed and started.")
	fmt.Println("   Edit config: /etc/powerfail/powerfail.conf")
}

func mustExec(name string, args ...string) {
	cmd := exec.Command(name, args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Printf("⚠️  %s %v: %s\n", name, args, string(out))
	}
}
