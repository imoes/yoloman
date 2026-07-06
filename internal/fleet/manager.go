package fleet

import (
	"context"
	"crypto/tls"
	"log/slog"
	"sync"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

// Manager is the single source of truth for which satellites this proxy is
// actively polling, reconciling two inputs: the statically configured list
// (config.yaml's proxy.satellites, loaded once at startup) and the dynamic
// SatelliteRegistry (grown/shrunk at runtime by the enrollment endpoint and
// DELETE /api/v1/proxy/satellites). Adding or removing a satellite from the
// registry takes effect immediately — starting or stopping that
// satellite's poll goroutine — rather than only on the next restart, which
// a one-shot "read the list once at startup" loop (this project's pre-
// dynamic-enrollment design) could not do.
type Manager struct {
	registry *SatelliteRegistry
	puller   pullerFactory
	// overviewPuller is nil in tests (see newManager) and in production
	// whenever this proxy has no snapshot cache to fill — startPolling
	// then simply skips the overview pull, leaving only the existing
	// metrics-history relay running.
	overviewPuller overviewPullerFactory
	// snapshotCache mirrors the same cache overviewPuller (if any)
	// writes into — kept on Manager too so Remove can evict a departing
	// satellite's stale snapshot immediately, not just stop polling it.
	snapshotCache *SnapshotCache

	mu      sync.Mutex
	cancels map[string]context.CancelFunc
}

// overviewPullerFactory builds a satellite's GET /api/v1/hosts/overview
// poll function — kept separate from pullerFactory/pollFunc (the existing
// metrics-history relay) so neither's tests need to change: a nil
// overviewPuller means "don't also poll for snapshots", the default for
// every existing caller/test.
type overviewPullerFactory func(sat config.Satellite) func(ctx context.Context) error

// pullerFactory exists solely so tests can substitute a fake poll function
// instead of a real *Puller (which needs a genuine TLS client cert and a
// reachable satellite) — see manager_test.go.
type pullerFactory func(sat config.Satellite) pollFunc

// pollFunc runs one poll cycle for a satellite, returning the number of
// points pulled.
type pollFunc func(ctx context.Context, from, to time.Time) (int, error)

// NewManager returns a Manager that polls satellites using pullerFor to
// build each satellite's poll function (production callers pass
// newRealPullerFactory(clientCert, st); tests pass a fake).
func newManager(registry *SatelliteRegistry, pullerFor pullerFactory) *Manager {
	return &Manager{
		registry: registry,
		puller:   pullerFor,
		cancels:  make(map[string]context.CancelFunc),
	}
}

// NewManager returns a Manager backed by real satellite polling over TLS
// (see Puller), storing pulled points in st and (if snapshotCache is
// non-nil) each satellite's latest GET /api/v1/hosts/overview snapshot in
// snapshotCache — see docs/plan.md's monitoring-cockpit ergänzung. Pass
// nil for snapshotCache to disable overview polling entirely (e.g. a
// build that only needs the existing metrics-history relay).
func NewManager(registry *SatelliteRegistry, clientCert tls.Certificate, st store.Store, snapshotCache *SnapshotCache) *Manager {
	m := newManager(registry, func(sat config.Satellite) pollFunc {
		p := &Puller{Satellite: sat, ClientCert: clientCert, Store: st}
		return p.PullOnce
	})
	if snapshotCache != nil {
		m.snapshotCache = snapshotCache
		m.overviewPuller = func(sat config.Satellite) func(ctx context.Context) error {
			p := &Puller{Satellite: sat, ClientCert: clientCert, Store: st}
			return func(ctx context.Context) error {
				snap, err := p.PullOverviewOnce(ctx)
				if err != nil {
					return err
				}
				snapshotCache.Set(sat.Name, snap)
				return nil
			}
		}
	}
	return m
}

// Start loads every satellite from both the static list and the dynamic
// registry and begins polling each (deduplicated by name — a dynamically
// re-enrolled satellite with the same name as a statically configured one
// wins, since the registry is consulted second and Add's semantics are
// "start or restart polling under this name").
func (m *Manager) Start(ctx context.Context, staticSatellites []config.Satellite) error {
	for _, sat := range staticSatellites {
		m.startPolling(sat)
	}
	dynamic, err := m.registry.List(ctx)
	if err != nil {
		return err
	}
	for _, sat := range dynamic {
		m.startPolling(sat)
	}
	return nil
}

// Enroll adds sat to the durable registry and starts polling it
// immediately — called by the enrollment REST endpoint.
func (m *Manager) Enroll(ctx context.Context, sat config.Satellite) error {
	if err := m.registry.Add(ctx, sat); err != nil {
		return err
	}
	m.startPolling(sat)
	return nil
}

// Remove deletes name from the durable registry and stops polling it
// immediately — called by DELETE /api/v1/proxy/satellites/{name}.
func (m *Manager) Remove(ctx context.Context, name string) error {
	if err := m.registry.Remove(ctx, name); err != nil {
		return err
	}
	m.stopPolling(name)
	if m.snapshotCache != nil {
		m.snapshotCache.Remove(name)
	}
	return nil
}

// List returns every dynamically registered satellite (the static list is
// not included — it isn't mutable via this API, only via config.yaml).
func (m *Manager) List(ctx context.Context) ([]config.Satellite, error) {
	return m.registry.List(ctx)
}

// Close stops every running poll goroutine.
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for name, cancel := range m.cancels {
		cancel()
		delete(m.cancels, name)
	}
}

func (m *Manager) startPolling(sat config.Satellite) {
	m.mu.Lock()
	if existing, ok := m.cancels[sat.Name]; ok {
		existing() // re-enrolling under the same name restarts the poller with fresh settings
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.cancels[sat.Name] = cancel
	m.mu.Unlock()

	interval := sat.PollInterval.Duration()
	if interval <= 0 {
		interval = time.Minute
	}
	poll := m.puller(sat)
	var pollOverview func(ctx context.Context) error
	if m.overviewPuller != nil {
		pollOverview = m.overviewPuller(sat)
	}

	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		last := time.Now().Add(-interval)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				now := time.Now()
				n, err := poll(ctx, last, now)
				if err != nil {
					slog.Error("satellite poll failed", "satellite", sat.Name, "error", err)
				} else {
					last = now
					if n > 0 {
						slog.Info("satellite poll completed", "satellite", sat.Name, "points", n)
					}
				}
				if pollOverview != nil {
					if err := pollOverview(ctx); err != nil {
						slog.Error("satellite overview poll failed", "satellite", sat.Name, "error", err)
					}
				}
			}
		}
	}()
}

func (m *Manager) stopPolling(name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if cancel, ok := m.cancels[name]; ok {
		cancel()
		delete(m.cancels, name)
	}
}
