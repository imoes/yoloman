package server

import (
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

// --- REST: PUT /api/v1/upload ---

func newUploadRESTServer(t *testing.T, write bool, maxUploadSize int64) (*httptest.Server, string) {
	t.Helper()
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })

	uploadsDir := filepath.Join(t.TempDir(), "uploads")
	handler := NewRESTHandler(RESTConfig{
		ProcRoot:      "/proc",
		ModReg:        modules.NewRegistry(),
		Policy:        pipeline.EmptyPolicy(),
		Store:         st,
		Write:         write,
		UploadsDir:    uploadsDir,
		MaxUploadSize: maxUploadSize,
	})
	return httptest.NewServer(handler), uploadsDir
}

func TestHandleUpload_Success(t *testing.T) {
	srv, uploadsDir := newUploadRESTServer(t, true, 1024)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/upload?name=hello.txt", strings.NewReader("hello staged world"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}

	got, err := os.ReadFile(filepath.Join(uploadsDir, "hello.txt"))
	if err != nil {
		t.Fatalf("reading staged file: %v", err)
	}
	if string(got) != "hello staged world" {
		t.Errorf("staged content = %q", got)
	}
}

func TestHandleUpload_WriteGateBlocksWhenDisabled(t *testing.T) {
	srv, _ := newUploadRESTServer(t, false, 1024)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/upload?name=hello.txt", strings.NewReader("x"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("status = %d, want 403 when write=false", resp.StatusCode)
	}
}

func TestHandleUpload_RejectsPathTraversal(t *testing.T) {
	srv, uploadsDir := newUploadRESTServer(t, true, 1024)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/upload?name=../escape.txt", strings.NewReader("x"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatal("expected path-traversal filename to be rejected")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(uploadsDir), "escape.txt")); err == nil {
		t.Fatal("file must not have escaped the staging directory")
	}
}

func TestHandleUpload_EnforcesSizeLimit(t *testing.T) {
	srv, uploadsDir := newUploadRESTServer(t, true, 10)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/upload?name=toobig.bin", strings.NewReader(strings.Repeat("x", 11)))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatal("expected oversized upload to be rejected")
	}
	if _, err := os.Stat(filepath.Join(uploadsDir, "toobig.bin")); err == nil {
		t.Fatal("expected no leftover file for a rejected oversized upload")
	}
}

func TestHandleUpload_ContentLengthFastRejection(t *testing.T) {
	srv, _ := newUploadRESTServer(t, true, 5)
	defer srv.Close()

	// Content-Length (11) already exceeds max_upload_size (5): should be
	// rejected before any bytes are streamed.
	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/upload?name=x.bin", strings.NewReader("hello world"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Errorf("status = %d, want 413", resp.StatusCode)
	}
}

func TestHandleUpload_OverwriteIsIdempotent(t *testing.T) {
	srv, uploadsDir := newUploadRESTServer(t, true, 1024)
	defer srv.Close()

	for _, content := range []string{"version 1", "version 2 is longer"} {
		req, _ := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/upload?name=f.txt", strings.NewReader(content))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d for content %q", resp.StatusCode, content)
		}
	}
	got, err := os.ReadFile(filepath.Join(uploadsDir, "f.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "version 2 is longer" {
		t.Errorf("expected second upload to win, got %q", got)
	}
}

func TestHandleUpload_ACLBlocksWhenDisabled(t *testing.T) {
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	acl, err := authz.OpenACL(filepath.Join(t.TempDir(), "acl.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { acl.Close() })
	if err := acl.SetToolEnabled(context.Background(), "upload_file", false); err != nil {
		t.Fatal(err)
	}

	uploadsDir := filepath.Join(t.TempDir(), "uploads")
	handler := NewRESTHandler(RESTConfig{
		ProcRoot:      "/proc",
		ModReg:        modules.NewRegistry(),
		Policy:        pipeline.EmptyPolicy(),
		Store:         st,
		Write:         true,
		ACL:           acl,
		UploadsDir:    uploadsDir,
		MaxUploadSize: 1024,
	})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/upload?name=f.txt", strings.NewReader("x"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("status = %d, want 403 for a disabled tool", resp.StatusCode)
	}
}

// --- MCP: upload_file tool ---

func connectUploadServer(t *testing.T, uploadsDir string, write bool) *mcp.ClientSession {
	t.Helper()
	s := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	RegisterUploadFile(s, uploadsDir, write, nil, nil)

	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ctx := context.Background()
	go func() { _ = s.Run(ctx, serverTransport) }()

	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func TestUploadFileTool_NotRegisteredWhenWriteFalse(t *testing.T) {
	cs := connectUploadServer(t, t.TempDir(), false)
	names := toolNames(t, cs)
	if names["upload_file"] {
		t.Error("expected upload_file to not be registered when write=false")
	}
}

func TestUploadFileTool_Success(t *testing.T) {
	uploadsDir := t.TempDir()
	cs := connectUploadServer(t, uploadsDir, true)

	content := "small config snippet"
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "upload_file",
		Arguments: map[string]any{
			"name":           "snippet.conf",
			"content_base64": base64.StdEncoding.EncodeToString([]byte(content)),
		},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}
	out := res.StructuredContent.(map[string]any)
	if out["bytes_written"].(float64) != float64(len(content)) {
		t.Errorf("bytes_written = %v, want %d", out["bytes_written"], len(content))
	}

	got, err := os.ReadFile(filepath.Join(uploadsDir, "snippet.conf"))
	if err != nil {
		t.Fatalf("reading staged file: %v", err)
	}
	if string(got) != content {
		t.Errorf("staged content = %q, want %q", got, content)
	}
}

func TestUploadFileTool_RejectsInvalidBase64(t *testing.T) {
	cs := connectUploadServer(t, t.TempDir(), true)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "upload_file",
		Arguments: map[string]any{
			"name":           "x.txt",
			"content_base64": "not-valid-base64!!!",
		},
	})
	if err != nil {
		t.Fatalf("CallTool transport error: %v", err)
	}
	if !res.IsError {
		t.Fatal("expected tool error for invalid base64 content")
	}
}

func TestUploadFileTool_RejectsOversizedContent(t *testing.T) {
	cs := connectUploadServer(t, t.TempDir(), true)
	tooBig := base64.StdEncoding.EncodeToString(make([]byte, maxMCPUploadBytes+1))
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "upload_file",
		Arguments: map[string]any{
			"name":           "x.bin",
			"content_base64": tooBig,
		},
	})
	if err != nil {
		t.Fatalf("CallTool transport error: %v", err)
	}
	if !res.IsError {
		t.Fatal("expected tool error for content exceeding the 64KiB MCP upload cap")
	}
}

func TestUploadFileTool_RejectsPathTraversal(t *testing.T) {
	uploadsDir := t.TempDir()
	cs := connectUploadServer(t, uploadsDir, true)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "upload_file",
		Arguments: map[string]any{
			"name":           "../escape.txt",
			"content_base64": base64.StdEncoding.EncodeToString([]byte("x")),
		},
	})
	if err != nil {
		t.Fatalf("CallTool transport error: %v", err)
	}
	if !res.IsError {
		t.Fatal("expected tool error for path-traversal filename")
	}
	if _, statErr := os.Stat(filepath.Join(filepath.Dir(uploadsDir), "escape.txt")); statErr == nil {
		t.Fatal("file must not have escaped the staging directory")
	}
}
