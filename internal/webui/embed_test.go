package webui

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func httpGet(t *testing.T, url string) (*http.Response, error) {
	t.Helper()
	return http.Get(url)
}

func readAll(t *testing.T, resp *http.Response) string {
	t.Helper()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestHandler_ServesIndexAtPrefix(t *testing.T) {
	h, err := Handler("/ui")
	if err != nil {
		t.Fatalf("Handler: %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()

	resp, err := httpGet(t, srv.URL+"/ui/")
	if err != nil {
		t.Fatalf("GET /ui/: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	body := readAll(t, resp)
	if !strings.Contains(body, "agentic-mcp") {
		t.Errorf("expected index.html content, got: %.200s", body)
	}
	if !strings.Contains(body, "doPamLogin") {
		t.Errorf("expected login script to be present")
	}
}

func TestHandler_UnknownAssetReturns404(t *testing.T) {
	h, err := Handler("/ui")
	if err != nil {
		t.Fatalf("Handler: %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()

	resp, err := httpGet(t, srv.URL+"/ui/does-not-exist.js")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Errorf("status = %d, want 404", resp.StatusCode)
	}
}
