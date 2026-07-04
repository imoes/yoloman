package modules

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestURI_RealServerGET(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Test", "yes")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("hello from server"))
	}))
	defer srv.Close()

	u := NewURI()
	res, err := u.Run(context.Background(), map[string]any{
		"url": srv.URL, "return_content": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["status"] != 200 {
		t.Errorf("status = %v, want 200", data["status"])
	}
	if data["content"] != "hello from server" {
		t.Errorf("content = %v", data["content"])
	}
	headers := data["headers"].(map[string]string)
	if headers["X-Test"] != "yes" {
		t.Errorf("expected X-Test header, got %v", headers)
	}
}

func TestURI_RealServerPOSTWithBody(t *testing.T) {
	var gotMethod, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	u := NewURI()
	res, err := u.Run(context.Background(), map[string]any{
		"url": srv.URL, "method": "POST", "body": "payload", "status_code": []int{201},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if gotMethod != "POST" || gotBody != "payload" {
		t.Errorf("server saw method=%q body=%q", gotMethod, gotBody)
	}
	if res.Data.(map[string]any)["status"] != 201 {
		t.Error("expected status 201 in result")
	}
}

func TestURI_UnexpectedStatusCodeErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	u := NewURI()
	_, err := u.Run(context.Background(), map[string]any{"url": srv.URL}, false)
	if err == nil {
		t.Fatal("expected error for an unexpected status code")
	}
}

func TestURI_CustomAcceptedStatusCodes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	u := NewURI()
	_, err := u.Run(context.Background(), map[string]any{"url": srv.URL, "status_code": []int{404}}, false)
	if err != nil {
		t.Fatalf("expected 404 to be accepted, got error: %v", err)
	}
}

func TestURI_CustomHeadersSent(t *testing.T) {
	var gotHeader string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHeader = r.Header.Get("X-Custom")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	u := NewURI()
	_, err := u.Run(context.Background(), map[string]any{
		"url": srv.URL, "headers": map[string]any{"X-Custom": "myvalue"},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if gotHeader != "myvalue" {
		t.Errorf("server saw X-Custom = %q, want myvalue", gotHeader)
	}
}

func TestURI_ReturnContentDefaultsFalse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("body content"))
	}))
	defer srv.Close()

	u := NewURI()
	res, err := u.Run(context.Background(), map[string]any{"url": srv.URL}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, ok := res.Data.(map[string]any)["content"]; ok {
		t.Error("expected no content field when return_content is not set")
	}
}

func TestURI_RequestFailurePropagatesError(t *testing.T) {
	u := &URI{HTTPDo: func(req *http.Request) (int, http.Header, []byte, error) {
		return 0, nil, nil, context.DeadlineExceeded
	}}
	_, err := u.Run(context.Background(), map[string]any{"url": "https://example.com"}, false)
	if err == nil {
		t.Fatal("expected error when the HTTP request fails")
	}
}

func TestURI_DryRunDoesNotMakeRequest(t *testing.T) {
	called := false
	u := &URI{HTTPDo: func(req *http.Request) (int, http.Header, []byte, error) {
		called = true
		return 200, nil, nil, nil
	}}
	res, err := u.Run(context.Background(), map[string]any{"url": "https://example.com"}, true)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("uri never reports changed=true, even under dry_run")
	}
	if called {
		t.Error("expected dry_run to not make the request")
	}
}
