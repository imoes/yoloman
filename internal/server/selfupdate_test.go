package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The self-update endpoint is the deliberate write-gate carve-out: it must
// accept an upload even when Write is false (a read-only agent still has to be
// upgradable), reject non-.deb bodies, and honour allow_self_update=false.

func TestSelfUpdate_RejectsNonDeb(t *testing.T) {
	// Write:false on purpose — proves the endpoint is NOT write-gated (a
	// write-gated handler would 403 here regardless of the body).
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfUpdate: true, Write: false, UpdateStagingDir: t.TempDir()}))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/api/v1/agent/self-update", "application/octet-stream",
		bytes.NewReader([]byte("this is not a deb")))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	// 400 (bad body), NOT 403 — the write gate did not block a read-only agent.
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 (not-a-deb, and crucially not 403)", resp.StatusCode)
	}
}

func TestSelfUpdate_ForbiddenWhenDisabled(t *testing.T) {
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{AllowSelfUpdate: false, Write: true}))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/api/v1/agent/self-update", "application/octet-stream",
		bytes.NewReader(append([]byte("!<arch>\n"), []byte("payload")...)))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403 when allow_self_update is false", resp.StatusCode)
	}
}
