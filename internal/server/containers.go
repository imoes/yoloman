package server

import (
	"fmt"
	"net/http"

	"github.com/mutkluge/agentic-mcp/internal/collect"
)

// handleListContainers lists every running container by name — the source Bossman's discovery reads to
// OFFER containers for monitoring. It deliberately ignores collect.monitored_containers: discovery must
// see containers that are not yet monitored, since offering them is the whole point.
//
// A pure read (no state change), so it is not write-gated — same class as the inventory/overview
// endpoints. Returns an empty list, not an error, on a host without Docker, so discovery on a
// non-container host simply proposes nothing.
func handleListContainers(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	d := collect.NewDockerCollector(cfg.DockerSocket, "", nil)
	names, err := d.ListNames()
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Errorf("listing containers: %w", err))
		return
	}
	if names == nil {
		names = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"containers": names})
}
