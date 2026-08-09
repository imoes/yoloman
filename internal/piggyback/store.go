package piggyback

import (
	"sync"

	"github.com/mutkluge/agentic-mcp/internal/config"
)

// CollectorsFromConfig builds the collector set a config declares (Docker,
// each Proxmox/vSphere endpoint, libvirt). A source whose runtime isn't
// present degrades to "nothing to report" at collect time, so enabling one on
// a host without it is a harmless no-op.
func CollectorsFromConfig(cfg config.Config) []Collector {
	var out []Collector
	if cfg.Piggyback.Docker {
		out = append(out, NewDockerCollector(cfg.Piggyback.DockerSocket))
	}
	for _, e := range cfg.Piggyback.Proxmox {
		out = append(out, NewProxmoxCollector(e.Host, e.User, e.Password, e.Insecure))
	}
	for _, e := range cfg.Piggyback.VSphere {
		out = append(out, NewVSphereCollector(e.Host, e.User, e.Password, e.Insecure))
	}
	if cfg.Piggyback.Libvirt {
		out = append(out, NewLibvirtCollector(cfg.Piggyback.LibvirtURI))
	}
	return out
}

// Store holds the live piggyback collector set behind a lock so it can be
// rebuilt at runtime (F-9: adding/removing a Proxmox/vSphere endpoint) without
// restarting the agent — the REST handlers read a snapshot per request.
type Store struct {
	mu         sync.RWMutex
	collectors []Collector
}

// NewStore seeds the store from a config's declared collectors.
func NewStore(cfg config.Config) *Store {
	return &Store{collectors: CollectorsFromConfig(cfg)}
}

// List returns a snapshot of the current collectors (safe to range over while
// another goroutine reloads).
func (s *Store) List() []Collector {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Collector, len(s.collectors))
	copy(out, s.collectors)
	return out
}

// Reload swaps in the collector set for a new config (after config.yaml changed).
func (s *Store) Reload(cfg config.Config) {
	next := CollectorsFromConfig(cfg)
	s.mu.Lock()
	s.collectors = next
	s.mu.Unlock()
}
