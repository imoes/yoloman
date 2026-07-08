package collect

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// writeStat writes a minimal /proc/stat with the given aggregate cpu jiffies.
func writeStat(t *testing.T, dir string, user, nice, system, idle, iowait uint64) {
	t.Helper()
	line := fmt.Sprintf("cpu  %d %d %d %d %d 0 0 0 0 0\ncpu0 1 1 1 1 1 0 0 0 0 0\n",
		user, nice, system, idle, iowait)
	if err := os.WriteFile(filepath.Join(dir, "stat"), []byte(line), 0o644); err != nil {
		t.Fatalf("write stat: %v", err)
	}
}

func TestCPUMeter_FirstSamplePrimesReturnsNotOK(t *testing.T) {
	dir := t.TempDir()
	writeStat(t, dir, 100, 0, 50, 800, 50) // total=1000, idle=850
	m := &CPUMeter{}
	if _, ok := m.Sample(dir); ok {
		t.Fatal("first Sample must return ok=false (no prior reading to rate against)")
	}
}

func TestCPUMeter_ComputesBusyPercentOverInterval(t *testing.T) {
	dir := t.TempDir()
	// t0: total=1000, idle(idle+iowait)=850.
	writeStat(t, dir, 100, 0, 50, 800, 50)
	m := &CPUMeter{}
	m.Sample(dir) // prime

	// t1: user +25 (busy), idle +50, iowait +25 → total=1100 (+100),
	// idle=925 (+75). busy delta = 100-75 = 25 → 25%.
	writeStat(t, dir, 125, 0, 50, 850, 75)
	pct, ok := m.Sample(dir)
	if !ok {
		t.Fatal("second Sample must return ok=true")
	}
	if pct < 24.9 || pct > 25.1 {
		t.Fatalf("busy%% = %v, want ~25", pct)
	}
}

func TestCPUMeter_ZeroIntervalNotOK(t *testing.T) {
	dir := t.TempDir()
	writeStat(t, dir, 100, 0, 50, 800, 50)
	m := &CPUMeter{}
	m.Sample(dir)
	// Identical stat → zero delta → no rate.
	if _, ok := m.Sample(dir); ok {
		t.Fatal("a zero-length interval must return ok=false, not divide by zero")
	}
}

func TestCPUMeter_MissingStatNotOK(t *testing.T) {
	m := &CPUMeter{}
	if _, ok := m.Sample(t.TempDir()); ok { // no stat file
		t.Fatal("a missing /proc/stat must return ok=false, not panic")
	}
}
