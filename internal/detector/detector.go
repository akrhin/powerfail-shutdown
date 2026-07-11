// Package detector checks for power failure using ping and/or Home Assistant.
package detector

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/akrhin/powerfail-shutdown/internal/models"
)

// Result describes the detection outcome for one check cycle.
type Result struct {
	Suspicion    bool   // primary source suspects power failure
	Confirmation bool   // secondary source confirms it
	Reason       string // human-readable description
}

// Detector checks power status based on configured sources.
type Detector struct {
	cfg        *models.Config
	httpClient *http.Client
}

// New creates a Detector from config.
func New(cfg *models.Config) *Detector {
	return &Detector{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout: 5 * time.Second,
		},
	}
}

// Detect runs a single detection cycle.
func (d *Detector) Detect(ctx context.Context) (*Result, error) {
	switch d.cfg.Detection.Mode {
	case "ping":
		return d.detectPing(ctx)
	case "ha":
		return d.detectHA(ctx)
	case "any":
		return d.detectAny(ctx)
	case "all":
		return d.detectAll(ctx)
	default:
		return nil, fmt.Errorf("unknown detection mode: %s", d.cfg.Detection.Mode)
	}
}

// detectPing uses ping only. Main = suspicion, Secondary = confirmation.
func (d *Detector) detectPing(ctx context.Context) (*Result, error) {
	mainOK := pingHost(ctx, d.cfg.Ping.Main)
	reason := fmt.Sprintf("ping main=%s ok=%v", d.cfg.Ping.Main, mainOK)

	if mainOK {
		return &Result{Suspicion: false, Confirmation: false, Reason: reason + " → OK"}, nil
	}

	res := &Result{Suspicion: true, Reason: reason}

	if d.cfg.Ping.Secondary != "" {
		secOK := pingHost(ctx, d.cfg.Ping.Secondary)
		res.Confirmation = !secOK
		res.Reason += fmt.Sprintf(", secondary=%s ok=%v", d.cfg.Ping.Secondary, secOK)
	}

	return res, nil
}

// detectHA uses Home Assistant entities. Priority 1 = suspicion, 2+ = confirmation.
func (d *Detector) detectHA(ctx context.Context) (*Result, error) {
	res := &Result{}

	for _, ent := range d.cfg.HA.Entity {
		state, err := d.getHAState(ctx, ent.EntityID)
		if err != nil {
			res.Reason += fmt.Sprintf("ha.%s=error(%v) ", ent.EntityID, err)
			continue
		}

		isOff := state == "off" || state == "unavailable"
		res.Reason += fmt.Sprintf("ha.%s=%s(priority=%d) ", ent.EntityID, state, ent.Priority)

		if !isOff {
			continue
		}

		switch {
		case ent.Priority == 1:
			res.Suspicion = true
		case ent.Priority >= 2:
			res.Confirmation = true
		}
	}

	if res.Suspicion {
		res.Reason += "→ SUSPICION"
	} else {
		res.Reason += "→ OK"
	}
	return res, nil
}

// detectAny: any source triggers suspicion + confirmation = immediate shutdown.
func (d *Detector) detectAny(ctx context.Context) (*Result, error) {
	res := &Result{}

	pingMain := pingHost(ctx, d.cfg.Ping.Main)
	pingSec := d.cfg.Ping.Secondary == "" // empty = treat as up (skip)
	if d.cfg.Ping.Secondary != "" {
		pingSec = pingHost(ctx, d.cfg.Ping.Secondary)
	}

	haStates := make(map[string]string)
	for _, ent := range d.cfg.HA.Entity {
		s, err := d.getHAState(ctx, ent.EntityID)
		if err == nil {
			haStates[ent.EntityID] = s
		}
	}

	// Collect all "off" indicators
	var offs []string
	if !pingMain {
		offs = append(offs, "ping_main")
	}
	// Only report secondary when it is actually configured
	if d.cfg.Ping.Secondary != "" && !pingSec {
		offs = append(offs, "ping_sec")
	}
	for _, ent := range d.cfg.HA.Entity {
		if haStates[ent.EntityID] == "off" || haStates[ent.EntityID] == "unavailable" {
			offs = append(offs, ent.EntityID)
		}
	}

	res.Reason = fmt.Sprintf("checks: ping_main=%v ping_sec=%v → off=%v", pingMain, pingSec, offs)

	// If ANY source is off → suspicion
	if len(offs) > 0 {
		res.Suspicion = true
		// If 2+ sources → confirmation (immediate shutdown bypasses threshold)
		if len(offs) >= 2 {
			res.Confirmation = true
		}
	}

	return res, nil
}

// detectAll: all sources must agree.
func (d *Detector) detectAll(ctx context.Context) (*Result, error) {
	res := &Result{}

	pingMain := pingHost(ctx, d.cfg.Ping.Main)
	pingSec := d.cfg.Ping.Secondary == "" // empty = treat as up (skip)
	if d.cfg.Ping.Secondary != "" {
		pingSec = pingHost(ctx, d.cfg.Ping.Secondary)
	}

	// Only proceed if ping sensors agree
	allPingDown := !pingMain && !pingSec

	var allHAOff = true
	var anyHAOff = false
	for _, ent := range d.cfg.HA.Entity {
		s, err := d.getHAState(ctx, ent.EntityID)
		if err != nil {
			allHAOff = false
			continue
		}
		if s == "off" || s == "unavailable" {
			anyHAOff = true
		} else {
			allHAOff = false
		}
	}

	res.Reason = fmt.Sprintf("ping_main=%v ping_sec=%v ha_any_off=%v ha_all_off=%v", pingMain, pingSec, anyHAOff, allHAOff)

	switch {
	case allPingDown && allHAOff:
		res.Suspicion = true
		res.Confirmation = true
		res.Reason += " → ALL DOWN (immediate)"
	case allPingDown || allHAOff:
		res.Suspicion = true
		res.Reason += " → SUSPICION"
	default:
		res.Reason += " → OK"
	}

	return res, nil
}

func pingHost(ctx context.Context, host string) bool {
	if host == "" {
		return true // empty = skip
	}
	cmd := exec.CommandContext(ctx, "ping", "-c", "1", "-W", "2", host)
	return cmd.Run() == nil
}

func (d *Detector) getHAState(ctx context.Context, entityID string) (string, error) {
	url := fmt.Sprintf("%s/api/states/%s", strings.TrimRight(d.cfg.HA.URL, "/"), entityID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+d.cfg.HA.Token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := d.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HA returned %d", resp.StatusCode)
	}

	// Minimal parse: just extract "state" field
	var result struct {
		State string `json:"state"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	return result.State, nil
}
