package server

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
)

// debMagic is the leading magic of a Debian .deb (an ar archive); rpmMagic is
// the RPM lead (0xED 0xAB 0xEE 0xDB). The self-update accepts either so a
// RHEL/Fedora/SUSE host upgrades from the .rpm and a Debian/Ubuntu host from
// the .deb — Bossman pushes whichever matches the host's OS family.
var debMagic = []byte("!<arch>\n")
var rpmMagic = []byte{0xED, 0xAB, 0xEE, 0xDB}

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
	// Stage OUTSIDE /tmp: the service runs with PrivateTmp=true, so a .deb
	// written to /tmp lives in this process's private namespace and is
	// invisible to the transient systemd-run unit (host namespace) that runs
	// dpkg below — which failed with "cannot access archive". /var/lib is not
	// namespaced, so both sides see the same file.
	stagingDir := cfg.UpdateStagingDir
	if stagingDir == "" {
		stagingDir = "/var/lib/agentic-mcp"
	}
	if err := os.MkdirAll(stagingDir, 0o700); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("staging dir: %w", err))
		return
	}
	tmp, err := os.CreateTemp(stagingDir, "agentic-mcp-update-*.deb")
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
	// Pick the installer from the package's magic bytes; reject anything else.
	kind := packageKind(tmp.Name())
	var installCmd string
	switch kind {
	case "deb":
		installCmd = fmt.Sprintf("dpkg -i %q", tmp.Name())
	case "rpm":
		// -U upgrades (installs if absent); --force lets a same/older version
		// replace the running one (e.g. a rebuild of the current version).
		// Works across dnf/yum/zypper distros since it's plain rpm.
		installCmd = fmt.Sprintf("rpm -U --force %q", tmp.Name())
	default:
		os.Remove(tmp.Name())
		writeError(w, http.StatusBadRequest, fmt.Errorf("uploaded file is not a .deb or .rpm package"))
		return
	}

	// Run the install in a TRANSIENT systemd unit (not our cgroup): the
	// package's postinst restarts agentic-mcp.service, which would otherwise
	// kill the install child mid-run (default KillMode=control-group). A
	// systemd-run unit survives our restart. Fire-and-forget; the short sleep
	// lets this HTTP response flush before the restart lands.
	// After install, EXPLICITLY (re)enable + start the service. The postinst
	// already restarts it, but that has raced to a stopped+disabled service on
	// some hosts (the restart lands while this transient unit — spawned by the
	// old, now-killed daemon — is still mid-install). Running enable --now here,
	// in the surviving transient unit, guarantees the new binary comes up
	// instead of stranding. reset-failed clears any prior failed state first.
	script := fmt.Sprintf(
		"sleep 1; %s >> /var/log/agentic-mcp/self-update.log 2>&1; "+
			"systemctl reset-failed agentic-mcp.service 2>/dev/null; "+
			"systemctl enable --now agentic-mcp.service >> /var/log/agentic-mcp/self-update.log 2>&1; "+
			"rm -f %q",
		installCmd, tmp.Name())
	cmd := exec.Command("systemd-run", "--collect", "--unit=agentic-mcp-selfupdate", "/bin/sh", "-c", script)
	if err := cmd.Start(); err != nil {
		os.Remove(tmp.Name())
		writeError(w, http.StatusInternalServerError, fmt.Errorf("scheduling install: %w", err))
		return
	}

	tool := "dpkg"
	if kind == "rpm" {
		tool = "rpm"
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "accepted",
		"bytes":  n,
		"detail": fmt.Sprintf("installing via %s; the service will restart onto the new version", tool),
	})
}

// packageKind sniffs the leading magic bytes: "deb", "rpm", or "" (unknown).
func packageKind(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	buf := make([]byte, len(debMagic))
	if _, err := io.ReadFull(f, buf); err != nil {
		return ""
	}
	if string(buf) == string(debMagic) {
		return "deb"
	}
	if len(buf) >= len(rpmMagic) && string(buf[:len(rpmMagic)]) == string(rpmMagic) {
		return "rpm"
	}
	return ""
}
