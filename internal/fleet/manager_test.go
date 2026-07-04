package fleet

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/config"
)

// fakePuller records how many times each satellite was polled, standing in
// for a real *Puller (which needs a genuine TLS client cert and a
// reachable satellite over the network).
type fakePuller struct {
	mu    sync.Mutex
	polls map[string]int64
}

func newFakePuller() *fakePuller {
	return &fakePuller{polls: make(map[string]int64)}
}

func (f *fakePuller) factory(sat config.Satellite) pollFunc {
	return func(ctx context.Context, from, to time.Time) (int, error) {
		f.mu.Lock()
		f.polls[sat.Name]++
		f.mu.Unlock()
		return 0, nil
	}
}

func (f *fakePuller) count(name string) int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.polls[name]
}

func fastSatellite(name string) config.Satellite {
	return config.Satellite{
		Name: name, Address: name + ".example.com:8010",
		PollInterval: config.Duration(10 * time.Millisecond),
	}
}

func TestManager_StartPollsStaticSatellites(t *testing.T) {
	registry, err := OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer registry.Close()

	fp := newFakePuller()
	m := newManager(registry, fp.factory)
	defer m.Close()

	if err := m.Start(context.Background(), []config.Satellite{fastSatellite("static1")}); err != nil {
		t.Fatalf("Start: %v", err)
	}

	waitForCount(t, fp, "static1", 1)
}

func TestManager_StartPollsDynamicallyRegisteredSatellites(t *testing.T) {
	registry, err := OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer registry.Close()
	if err := registry.Add(context.Background(), fastSatellite("dyn1")); err != nil {
		t.Fatal(err)
	}

	fp := newFakePuller()
	m := newManager(registry, fp.factory)
	defer m.Close()

	if err := m.Start(context.Background(), nil); err != nil {
		t.Fatalf("Start: %v", err)
	}

	waitForCount(t, fp, "dyn1", 1)
}

func TestManager_EnrollStartsPollingImmediately(t *testing.T) {
	registry, err := OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer registry.Close()

	fp := newFakePuller()
	m := newManager(registry, fp.factory)
	defer m.Close()

	if err := m.Start(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if err := m.Enroll(context.Background(), fastSatellite("newsat")); err != nil {
		t.Fatalf("Enroll: %v", err)
	}

	waitForCount(t, fp, "newsat", 1)

	sats, err := m.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(sats) != 1 || sats[0].Name != "newsat" {
		t.Errorf("expected the enrolled satellite in the dynamic list, got %+v", sats)
	}
}

func TestManager_RemoveStopsPollingImmediately(t *testing.T) {
	registry, err := OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer registry.Close()

	fp := newFakePuller()
	m := newManager(registry, fp.factory)
	defer m.Close()

	if err := m.Enroll(context.Background(), fastSatellite("gone-soon")); err != nil {
		t.Fatal(err)
	}
	waitForCount(t, fp, "gone-soon", 1)

	if err := m.Remove(context.Background(), "gone-soon"); err != nil {
		t.Fatalf("Remove: %v", err)
	}
	countAtRemoval := fp.count("gone-soon")
	time.Sleep(50 * time.Millisecond) // several poll intervals' worth of "would have polled again"
	if got := fp.count("gone-soon"); got > countAtRemoval+1 {
		t.Errorf("expected polling to stop after Remove, but count kept climbing: %d -> %d", countAtRemoval, got)
	}

	sats, err := m.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(sats) != 0 {
		t.Errorf("expected no satellites after removal, got %+v", sats)
	}
}

func TestManager_RemoveUnknownSatelliteIsNotAnError(t *testing.T) {
	registry, err := OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer registry.Close()

	m := newManager(registry, newFakePuller().factory)
	defer m.Close()

	if err := m.Remove(context.Background(), "never-existed"); err != nil {
		t.Errorf("expected removing an unknown satellite to be a no-op, got: %v", err)
	}
}

func TestManager_ReEnrollingSameNameRestartsPolling(t *testing.T) {
	registry, err := OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer registry.Close()

	fp := newFakePuller()
	m := newManager(registry, fp.factory)
	defer m.Close()

	if err := m.Enroll(context.Background(), fastSatellite("resat")); err != nil {
		t.Fatal(err)
	}
	waitForCount(t, fp, "resat", 1)

	// Re-enroll under the same name — must not panic/leak/duplicate pollers.
	if err := m.Enroll(context.Background(), fastSatellite("resat")); err != nil {
		t.Fatalf("re-Enroll: %v", err)
	}
	waitForCount(t, fp, "resat", 2)

	sats, err := m.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(sats) != 1 {
		t.Errorf("expected re-enrolling the same name to still be a single entry, got %d", len(sats))
	}
}

func TestManager_CloseStopsAllPolling(t *testing.T) {
	registry, err := OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer registry.Close()

	fp := newFakePuller()
	m := newManager(registry, fp.factory)

	if err := m.Start(context.Background(), []config.Satellite{fastSatellite("s1"), fastSatellite("s2")}); err != nil {
		t.Fatal(err)
	}
	waitForCount(t, fp, "s1", 1)
	waitForCount(t, fp, "s2", 1)

	m.Close()
	c1, c2 := fp.count("s1"), fp.count("s2")
	time.Sleep(50 * time.Millisecond)
	if fp.count("s1") > c1+1 || fp.count("s2") > c2+1 {
		t.Error("expected Close to stop all pollers")
	}
}

// waitForCount polls fp's count for name until it reaches at least want,
// failing the test if it doesn't within a short deadline — avoids a flaky
// fixed sleep for what's fundamentally a "did the goroutine run yet" check.
func waitForCount(t *testing.T, fp *fakePuller, name string, want int64) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if fp.count(name) >= want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %q to be polled >= %d times (got %d)", name, want, fp.count(name))
}
