package detector

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/akrhin/powerfail-shutdown/internal/models"
)

// pingOK returns a PingFn that always succeeds.
func pingOK(_ context.Context, _ string) bool { return true }

// pingFail returns a PingFn that always fails.
func pingFail(_ context.Context, _ string) bool { return false }

func TestNew(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ping", Threshold: 3},
		Ping:      models.PingConfig{Main: "192.168.1.1"},
	}
	d := New(cfg)
	if d == nil {
		t.Fatal("expected non-nil Detector")
	}
}

func TestNewWithPingFn(t *testing.T) {
	cfg := &models.Config{Detection: models.DetectionConfig{Mode: "ping"}}
	d := NewWithPingFn(cfg, pingOK)
	if d == nil {
		t.Fatal("expected non-nil Detector")
	}
	if d.pingFn == nil {
		t.Error("expected pingFn to be set")
	}
}

func TestDetectPingMainOK(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ping"},
		Ping:      models.PingConfig{Main: "192.168.1.1"},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Suspicion {
		t.Error("expected no suspicion when main ping succeeds")
	}
	if res.Confirmation {
		t.Error("expected no confirmation when main ping succeeds")
	}
}

func TestDetectPingMainFailNoSecondary(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ping"},
		Ping:      models.PingConfig{Main: "192.168.1.1", Secondary: ""},
	}
	d := NewWithPingFn(cfg, pingFail)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when main ping fails")
	}
	if res.Confirmation {
		t.Error("expected no confirmation without secondary")
	}
}

func TestDetectPingBothFail(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ping"},
		Ping:      models.PingConfig{Main: "192.168.1.1", Secondary: "8.8.8.8"},
	}
	d := NewWithPingFn(cfg, pingFail)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when main ping fails")
	}
	if !res.Confirmation {
		t.Error("expected confirmation when both pings fail")
	}
}

func TestDetectPingMainFailSecondaryOK(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ping"},
		Ping:      models.PingConfig{Main: "192.168.1.1", Secondary: "8.8.8.8"},
	}
	// Main fails, secondary succeeds
	d := NewWithPingFn(cfg, func(_ context.Context, host string) bool {
		return host == "8.8.8.8"
	})
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when main fails")
	}
	if res.Confirmation {
		t.Error("expected no confirmation when secondary succeeds")
	}
}

func TestDetectHAAllOn(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"state": "on"}`))
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ha"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
				{EntityID: "binary_sensor.ups", Priority: 2},
			},
		},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Suspicion {
		t.Error("expected no suspicion when all HA entities are on")
	}
}

func TestDetectHAPrimaryOff(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"state": "off"}`))
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ha"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
				{EntityID: "binary_sensor.ups", Priority: 2},
			},
		},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when primary HA entity is off")
	}
	if !res.Confirmation {
		t.Error("expected confirmation when both entities report off (priority 2+ secondary)")
	}
}

func TestDetectHAPrimaryOffSecondaryOn(t *testing.T) {
	callCount := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		if callCount == 1 {
			w.Write([]byte(`{"state": "off"}`)) // priority 1 = suspicion
		} else {
			w.Write([]byte(`{"state": "on"}`)) // priority 2 = still on
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ha"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
				{EntityID: "binary_sensor.ups", Priority: 2},
			},
		},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when primary entity is off")
	}
	if res.Confirmation {
		t.Error("expected no confirmation when secondary entity is still on")
	}
}

func TestDetectHAPriority1And2Off(t *testing.T) {
	callCount := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		w.Write([]byte(`{"state": "off"}`))
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ha"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
				{EntityID: "binary_sensor.ups", Priority: 3},
			},
		},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when primary is off")
	}
	if !res.Confirmation {
		t.Error("expected confirmation when priority 2+ entity is off")
	}
}

func TestDetectHAUnavailable(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"state": "unavailable"}`))
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ha"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
			},
		},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when HA entity is unavailable")
	}
}

func TestDetectHAEntityFetchError(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ha"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
			},
		},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Suspicion {
		t.Error("expected no suspicion when HA entity fetch fails (error logged, not set)")
	}
}

func TestDetectAnyPingBothOK(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "any"},
		Ping:      models.PingConfig{Main: "192.168.1.1"},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Suspicion {
		t.Error("expected no suspicion when ping is OK in any mode")
	}
}

func TestDetectAnyPingMainDown(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "any"},
		Ping:      models.PingConfig{Main: "192.168.1.1"},
	}
	// Main fails => 1 source off => suspicion but no confirmation
	d := NewWithPingFn(cfg, pingFail)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when ping main is down in any mode")
	}
	if res.Confirmation {
		t.Error("expected no confirmation with only 1 source off")
	}
}

func TestDetectAnyTwoSourcesOff(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"state": "off"}`))
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "any"},
		Ping:      models.PingConfig{Main: "192.168.1.1"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
			},
		},
	}
	// Main fails + HA entity off = 2 sources → suspicion + confirmation
	d := NewWithPingFn(cfg, pingFail)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when multiple sources are off")
	}
	if !res.Confirmation {
		t.Error("expected confirmation when 2+ sources are off in any mode")
	}
}

func TestDetectAllAllOK(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"state": "on"}`))
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "all"},
		Ping:      models.PingConfig{Main: "192.168.1.1"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
			},
		},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Suspicion {
		t.Error("expected no suspicion when all sources OK")
	}
}

func TestDetectAllPingDownOnly(t *testing.T) {
	// In "all" mode, ping failing with HA on means not ALL sources agree → suspicion only
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"state": "on"}`))
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "all"},
		Ping:      models.PingConfig{Main: "192.168.1.1", Secondary: "8.8.8.8"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
			},
		},
	}
	// Both pings fail, but HA says "on" → allPingDown=true, allHAOff=false → suspicion only
	d := NewWithPingFn(cfg, pingFail)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when ping fails in all mode")
	}
	if res.Confirmation {
		t.Error("expected no confirmation when HA disagrees in all mode")
	}
}

func TestDetectAllAllDown(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"state": "off"}`))
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "all"},
		Ping:      models.PingConfig{Main: "192.168.1.1", Secondary: "8.8.8.8"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
			},
		},
	}
	// Both pings fail + HA off → allPingDown=true, allHAOff=true → suspicion + confirmation
	d := NewWithPingFn(cfg, pingFail)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when all sources are down")
	}
	if !res.Confirmation {
		t.Error("expected confirmation when all sources confirm down (ping main + HA off)")
	}
}

func TestDetectAllWithEmptySecondaryAndNoHA(t *testing.T) {
	// Empty secondary means main is the only ping target.
	// If main fails, allPingDown=true (the one ping source is down).
	// No HA configured → allHAOff=false (no entities to check).
	// So: allPingDown || allHAOff → suspicion.
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "all"},
		Ping:      models.PingConfig{Main: "192.168.1.1", Secondary: ""},
	}
	d := NewWithPingFn(cfg, pingFail)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Suspicion {
		t.Error("expected suspicion when main ping is down (only ping source)")
	}
	if res.Confirmation {
		t.Error("expected no confirmation without HA agreeing")
	}
}

func TestDetectUnknownMode(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "nonexistent"},
	}
	d := NewWithPingFn(cfg, pingOK)
	_, err := d.Detect(context.Background())
	if err == nil {
		t.Fatal("expected error for unknown detection mode")
	}
}

func TestDetectPingReasonMessage(t *testing.T) {
	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "ping"},
		Ping:      models.PingConfig{Main: "10.0.0.1"},
	}
	d := NewWithPingFn(cfg, pingOK)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Reason == "" {
		t.Error("expected non-empty reason")
	}
}

func TestDetectAllHAEntityError(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer ts.Close()

	cfg := &models.Config{
		Detection: models.DetectionConfig{Mode: "all"},
		Ping:      models.PingConfig{Main: "192.168.1.1"},
		HA: models.HAConfig{
			URL:   ts.URL,
			Token: "test-token",
			Entity: []models.HAEntity{
				{EntityID: "binary_sensor.socket", Priority: 1},
			},
		},
	}
	d := NewWithPingFn(cfg, pingFail)
	res, err := d.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// Ping fails, HA errors (not all HA off) → suspicion but not all agree = suspicion only
	if !res.Suspicion && res.Confirmation {
		t.Error("expected only suspicion when all ping fails but HA call errors")
	}
}
