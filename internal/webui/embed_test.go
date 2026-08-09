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
	// The embedded frontend is the built Angular standalone-agent app.
	if !strings.Contains(body, "<app-root") {
		t.Errorf("expected the Angular app root element in index.html")
	}
	// This test is named for the PREFIX, and the base href is the only part of index.html that
	// actually depends on it — get it wrong and every asset the SPA requests 404s.
	//
	// It replaces an assertion on the page <title> ("YOLO-MANager"), which tested nothing about the
	// prefix and broke the moment the app was renamed to BossmanUi. A title is presentation and will
	// change again; the base href is the contract.
	if !strings.Contains(body, `<base href="/ui/">`) {
		t.Errorf("expected the base href to carry the mount prefix, got: %.200s", body)
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
