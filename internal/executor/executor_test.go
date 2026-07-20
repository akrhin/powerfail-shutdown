package executor

import (
	"context"
	"testing"
	"time"

	"github.com/akrhin/powerfail-shutdown/internal/models"
)

func TestNew(t *testing.T) {
	e := New(&models.ShutdownConfig{TimeoutSecs: 30})
	if e == nil {
		t.Fatal("expected non-nil Executor")
	}
}

func TestRunEmptySequence(t *testing.T) {
	e := New(&models.ShutdownConfig{
		TimeoutSecs: 30,
		Sequence:    []models.Step{},
	})
	err := e.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
}

func TestRunWaitStep(t *testing.T) {
	e := New(&models.ShutdownConfig{
		TimeoutSecs: 30,
		Sequence: []models.Step{
			{Type: "wait", Timeout: intPtr(1)},
		},
	})
	start := time.Now()
	err := e.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(start)
	if elapsed < 900*time.Millisecond {
		t.Errorf("wait step finished too fast: %v", elapsed)
	}
}

func TestRunContextCancellation(t *testing.T) {
	e := New(&models.ShutdownConfig{
		TimeoutSecs: 30,
		Sequence: []models.Step{
			{Type: "wait", Timeout: intPtr(10)},
		},
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	err := e.Run(ctx)
	if err == nil {
		t.Fatal("expected error from cancelled context")
	}
}

func TestRunUnknownStep(t *testing.T) {
	e := New(&models.ShutdownConfig{
		TimeoutSecs: 30,
		Sequence: []models.Step{
			{Type: "invalid"},
		},
	})
	err := e.Run(context.Background())
	if err == nil {
		t.Fatal("expected error for unknown step type")
	}
}

func TestParseQMRunning(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected []int
	}{
		{
			name:     "empty",
			input:    "",
			expected: nil,
		},
		{
			name:     "header only",
			input:    "VMID NAME STATUS MEMORY BOOTDISK\n",
			expected: nil,
		},
		{
			name:     "one running VM",
			input:    "100 test-vm running 2048 10.0\n",
			expected: []int{100},
		},
		{
			name:     "one stopped VM filtered out",
			input:    "101 test-vm stopped 2048 10.0\n",
			expected: nil,
		},
		{
			name:     "multiple running VMs",
			input:    "VMID NAME STATUS MEMORY BOOTDISK\n100 web running 2048 10.0\n101 db running 4096 20.0\n102 old stopped 1024 5.0\n",
			expected: []int{100, 101},
		},
		{
			name:     "short line skipped",
			input:    "100\n",
			expected: nil,
		},
		{
			name:     "non-numeric VMID skipped",
			input:    "abc vm running 1024 10.0\n",
			expected: nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			result := parseQMRunning([]byte(tc.input))
			if len(result) != len(tc.expected) {
				t.Fatalf("expected %v, got %v", tc.expected, result)
			}
			for i, v := range result {
				if v != tc.expected[i] {
					t.Errorf("index %d: expected %d, got %d", i, tc.expected[i], v)
				}
			}
		})
	}
}

func TestParsePCTRunning(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected []int
	}{
		{
			name:     "empty",
			input:    "",
			expected: nil,
		},
		{
			name:     "header only",
			input:    "CTID STATE\n",
			expected: nil,
		},
		{
			name:     "header lowercase",
			input:    "CTID state\n",
			expected: nil,
		},
		{
			name:     "one running CT",
			input:    "100 running\n",
			expected: []int{100},
		},
		{
			name:     "one stopped CT filtered out",
			input:    "101 stopped\n",
			expected: nil,
		},
		{
			name:     "multiple running CTs",
			input:    "CTID STATE\n100 running\n101 running\n102 stopped\n",
			expected: []int{100, 101},
		},
		{
			name:     "short line skipped",
			input:    "100\n",
			expected: nil,
		},
		{
			name:     "non-numeric CTID skipped",
			input:    "abc running\n",
			expected: nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			result := parsePCTRunning([]byte(tc.input))
			if len(result) != len(tc.expected) {
				t.Fatalf("expected %v, got %v", tc.expected, result)
			}
			for i, v := range result {
				if v != tc.expected[i] {
					t.Errorf("index %d: expected %d, got %d", i, tc.expected[i], v)
				}
			}
		})
	}
}

func intPtr(i int) *int { return &i }
