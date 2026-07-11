// Agent runs as a systemd service, periodically checking power status.
package agent

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"time"

	"github.com/akrhin/powerfail-shutdown/internal/config"
	"github.com/akrhin/powerfail-shutdown/internal/detector"
	"github.com/akrhin/powerfail-shutdown/internal/executor"
	"github.com/akrhin/powerfail-shutdown/internal/notifier"
)

const (
	flagOccurred  = "/root/.powerfail_occurred"
	counterFile   = "/tmp/powerfail_counter"
	powerfailFile = "/tmp/.powerfail_active"
)

// Run executes one full check cycle.
// Returns a message to log or empty if nothing happened.
func Run(ctx context.Context, cfgPath string) (string, error) {
	cfg, err := config.LoadFile(cfgPath)
	if err != nil {
		return "", fmt.Errorf("load config: %w", err)
	}

	notif := notifier.New(cfg.Telegram)
	det := detector.New(cfg)
	exec := executor.New(&cfg.Shutdown)

	// Phase 0: Post-recovery notification
	if _, err := os.Stat(flagOccurred); err == nil {
		data, err := os.ReadFile(flagOccurred)
		if err != nil {
			return "", fmt.Errorf("read occurrence flag: %w", err)
		}
		occurredAt := string(data)
		if pingRouter(ctx, cfg.Ping.Main) {
			if notif != nil {
				if err := notif.SendMarkdown(ctx, fmt.Sprintf("⚡ *Power restored* — outage was at %s", occurredAt)); err != nil {
					log.Printf("WARN: send notification: %v", err)
				}
			}
			_ = os.Remove(flagOccurred) // best-effort
			return fmt.Sprintf("Power restored, notification sent (occurred: %s)", occurredAt), nil
		}
		return "Flag present but router still down — waiting", nil
	}

	// Phase 1: Already in shutdown sequence
	if _, err := os.Stat(powerfailFile); err == nil {
		return "Shutdown in progress — skipping check", nil
	}

	// Phase 2: Detection
	result, err := det.Detect(ctx)
	if err != nil {
		return "", fmt.Errorf("detect: %w", err)
	}

	// If everything OK — reset counter and exit
	if !result.Suspicion {
		if err := os.WriteFile(counterFile, []byte("0"), 0644); err != nil {
			log.Printf("WARN: write counter: %v", err)
		}
		return "OK — " + result.Reason, nil
	}

	// Increment counter
	counter := 0
	if data, err := os.ReadFile(counterFile); err == nil {
		if _, err := fmt.Sscanf(string(data), "%d", &counter); err != nil {
			counter = 0
		}
	}
	counter++
	if err := os.WriteFile(counterFile, []byte(fmt.Sprintf("%d", counter)), 0644); err != nil {
		log.Printf("WARN: write counter: %v", err)
	}

	msg := fmt.Sprintf("⚠️ Suspicion %d/%d — %s", counter, cfg.Detection.Threshold, result.Reason)

	// If threshold reached OR confirmation signal triggered
	if counter >= cfg.Detection.Threshold || result.Confirmation {
		if err := os.WriteFile(flagOccurred, []byte(time.Now().Format(time.RFC3339)), 0644); err != nil {
			return "", fmt.Errorf("write flag: %w", err)
		}
		if err := os.WriteFile(powerfailFile, []byte("1"), 0644); err != nil {
			return "", fmt.Errorf("write powerfail flag: %w", err)
		}

		// Notify BEFORE shutdown (router on UPS — internet still up)
		if notif != nil {
			ts := time.Now().Format("2006-01-02 15:04:05")
			ntxt := fmt.Sprintf("⚠️ *Power failure* (%s) — initiating shutdown sequence.", ts)
			if err := notif.SendMarkdown(ctx, ntxt); err != nil {
				log.Printf("WARN: send shutdown alert: %v", err)
			}
		}

		// Execute shutdown sequence
		shutdownCtx, cancel := context.WithTimeout(ctx, time.Duration(cfg.Shutdown.TimeoutSecs+30)*time.Second)
		defer cancel()

		if err := exec.Run(shutdownCtx); err != nil {
			return "", fmt.Errorf("shutdown sequence: %w", err)
		}

		// Notify just before poweroff
		if notif != nil {
			if err := notif.SendPlain(ctx, "🛑 Power failure — host shutting down."); err != nil {
				log.Printf("WARN: send final alert: %v", err)
			}
		}

		return "SHUTDOWN SEQUENCE COMPLETE", nil
	}

	return msg, nil
}

func pingRouter(ctx context.Context, host string) bool {
	if host == "" {
		return false
	}
	return exec.CommandContext(ctx, "ping", "-c", "1", "-W", "2", host).Run() == nil
}
