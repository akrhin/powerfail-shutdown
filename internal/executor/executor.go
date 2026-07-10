// Package executor handles the shutdown sequence for Proxmox VMs and containers.
package executor

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/akrhin/powerfail-shutdown/internal/models"
)

// Executor runs the configured shutdown sequence.
type Executor struct {
	cfg *models.ShutdownConfig
}

// New creates an Executor from config.
func New(cfg *models.ShutdownConfig) *Executor {
	return &Executor{cfg: cfg}
}

// Run executes the shutdown sequence step by step.
func (e *Executor) Run(ctx context.Context) error {
	for i, step := range e.cfg.Sequence {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		timeout := time.Duration(e.cfg.TimeoutSecs) * time.Second
		if step.Timeout != nil && *step.Timeout > 0 {
			timeout = time.Duration(*step.Timeout) * time.Second
		}

		if err := e.executeStep(ctx, step, timeout, i); err != nil {
			return fmt.Errorf("step %d (%s): %w", i, step.Type, err)
		}
	}
	return nil
}

func (e *Executor) executeStep(ctx context.Context, step models.Step, timeout time.Duration, idx int) error {
	switch step.Type {
	case "vm":
		return stopVM(ctx, *step.VMID, timeout)
	case "ct":
		return stopCT(ctx, *step.VMID, timeout)
	case "all_vm":
		return stopAllVM(ctx, timeout)
	case "all_ct":
		return stopAllCT(ctx, timeout)
	case "wait":
		select {
		case <-time.After(timeout):
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	default:
		return fmt.Errorf("unknown step type: %s", step.Type)
	}
}

func stopVM(ctx context.Context, vmid int, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// Try graceful shutdown first
	cmd := exec.CommandContext(ctx, "qm", "shutdown", fmt.Sprintf("%d", vmid), "--timeout", fmt.Sprintf("%d", int(timeout.Seconds())))
	if err := cmd.Run(); err == nil {
		// Wait for it to actually stop
		return waitForVMStop(ctx, vmid, timeout)
	}

	// Force stop if graceful fails
	return exec.CommandContext(ctx, "qm", "stop", fmt.Sprintf("%d", vmid)).Run()
}

func stopCT(ctx context.Context, ctid int, _ time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	// Try graceful shutdown first
	cmd := exec.CommandContext(ctx, "pct", "shutdown", fmt.Sprintf("%d", ctid), "--timeout", "30")
	if err := cmd.Run(); err == nil {
		return nil
	}

	// Force stop
	return exec.CommandContext(ctx, "pct", "stop", fmt.Sprintf("%d", ctid)).Run()
}

func stopAllVM(ctx context.Context, timeout time.Duration) error {
	// List all running VMs (except those already stopped in earlier steps)
	out, err := exec.CommandContext(ctx, "qm", "list").Output()
	if err != nil {
		return fmt.Errorf("list VMs: %w", err)
	}

	vms := parseQMRunning(out)
	for _, vmid := range vms {
		if err := stopVM(ctx, vmid, timeout); err != nil {
			return fmt.Errorf("stop VM %d: %w", vmid, err)
		}
	}
	return nil
}

func stopAllCT(ctx context.Context, timeout time.Duration) error {
	out, err := exec.CommandContext(ctx, "pct", "list").Output()
	if err != nil {
		return fmt.Errorf("list CTs: %w", err)
	}

	cts := parsePCTRunning(out)
	for _, ctid := range cts {
		if err := stopCT(ctx, ctid, timeout); err != nil {
			return fmt.Errorf("stop CT %d: %w", ctid, err)
		}
	}
	return nil
}

func parseQMRunning(out []byte) []int {
	var result []int
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		if fields[1] == "NAME" {
			continue // header
		}
		if fields[2] == "running" {
			var id int
			if _, err := fmt.Sscanf(fields[0], "%d", &id); err == nil {
				result = append(result, id)
			}
		}
	}
	return result
}

func parsePCTRunning(out []byte) []int {
	var result []int
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if fields[1] == "STATE" || fields[1] == "state" {
			continue // header
		}
		if fields[1] == "running" {
			var id int
			if _, err := fmt.Sscanf(fields[0], "%d", &id); err == nil {
				result = append(result, id)
			}
		}
	}
	return result
}

func waitForVMStop(ctx context.Context, vmid int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		status, err := getVMStatus(ctx, vmid)
		if err != nil {
			return err
		}
		if status == "stopped" {
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("VM %d did not stop within timeout", vmid)
}

func getVMStatus(ctx context.Context, vmid int) (string, error) {
	out, err := exec.CommandContext(ctx, "qm", "status", fmt.Sprintf("%d", vmid)).Output()
	if err != nil {
		return "", err
	}
	// output format: "status: running\n" or "status: stopped\n"
	line := strings.TrimSpace(string(out))
	const prefix = "status: "
	if strings.HasPrefix(line, prefix) {
		return line[len(prefix):], nil
	}
	return "", fmt.Errorf("unexpected qm status output: %q", line)
}
