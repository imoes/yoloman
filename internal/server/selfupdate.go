package server

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
)

// debMagic is the leading magic of a Debian .deb (an ar archive).
var debMagic = []byte("!<arch>\n")

// handleSelfUpdate receives a new agent .deb pushed by Bossman over the
// existing mTLS channel and installs it (dpkg -i), which — via the package's
// postinst — replaces the binary and restarts the service onto the new
// version.
//
// DELIBERATE write-gate carve-out (Block N-deploy): unlike every other
// mutating endpoint this is NOT gated on cfg.Write. Upgrading the agent is a
// controlled, self-scoped management action — a read-only (write=false) agent
// must still be upgradable, or it could never receive a fix. It's gated
// instead by `allow_self_update` (default true, so an operator can forbid it)
// and, like all routes, already sits behind mTLS + bearer auth (only Bossman's
// pinned client identity can reach it). This is "the rule that allows updating
// the package even when write=false".
func handleSelfUpdate(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if !cfg.AllowSelfUpdate {
		writeError(w, http.StatusForbidden, fmt.Errorf("self-update is disabled on this agent (allow_self_update: false)"))
		return
	}
	max := cfg.MaxUploadSize
	if max <= 0 {
		max = 512 << 20
	}
	tmp, err := os.CreateTemp("", "agentic-mcp-update-*.deb")
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("staging update: %w", err))
		return
	}
	n, err := io.Copy(tmp, io.LimitReader(r.Body, max))
	tmp.Close()
	if err != nil {
		os.Remove(tmp.Name())
		writeError(w, http.StatusBadRequest, fmt.Errorf("receiving update: %w", err))
		return
	}
	// Reject anything that isn't a .deb before handing it to dpkg.
	if !hasDebMagic(tmp.Name()) {
		os.Remove(tmp.Name())
		writeError(w, http.StatusBadRequest, fmt.Errorf("uploaded file is not a .deb package"))
		return
	}

	// Run the install in a TRANSIENT systemd unit (not our cgroup): the
	// package's postinst restarts agentic-mcp.service, which would otherwise
	// kill the dpkg child mid-install (default KillMode=control-group). A
	// systemd-run unit survives our restart. Fire-and-forget; the short sleep
	// lets this HTTP response flush before the restart lands.
	script := fmt.Sprintf("sleep 1; dpkg -i %q >> /var/log/agentic-mcp/self-update.log 2>&1; rm -f %q", tmp.Name(), tmp.Name())
	cmd := exec.Command("systemd-run", "--collect", "--unit=agentic-mcp-selfupdate", "/bin/sh", "-c", script)
	if err := cmd.Start(); err != nil {
		os.Remove(tmp.Name())
		writeError(w, http.StatusInternalServerError, fmt.Errorf("scheduling install: %w", err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status": "accepted",
		"bytes":  n,
		"detail": "installing via dpkg; the service will restart onto the new version",
	})
}

func hasDebMagic(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	buf := make([]byte, len(debMagic))
	if _, err := io.ReadFull(f, buf); err != nil {
		return false
	}
	return string(buf) == string(debMagic)
}
