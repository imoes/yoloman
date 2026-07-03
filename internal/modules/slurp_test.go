package modules

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestSlurp_ReadsAndEncodesContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "data.bin")
	content := []byte("hello, agentic-mcp\x00\x01\x02")
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatal(err)
	}

	s := NewSlurp()
	res, err := s.Run(context.Background(), map[string]any{"path": path}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["encoding"] != "base64" {
		t.Errorf("encoding = %v, want base64", data["encoding"])
	}
	decoded, err := base64.StdEncoding.DecodeString(data["content"].(string))
	if err != nil {
		t.Fatalf("decoding content: %v", err)
	}
	if string(decoded) != string(content) {
		t.Errorf("decoded content = %q, want %q", decoded, content)
	}
}

func TestSlurp_NonexistentFile(t *testing.T) {
	s := NewSlurp()
	if _, err := s.Run(context.Background(), map[string]any{"path": "/no/such/file"}, false); err == nil {
		t.Fatal("expected error for nonexistent file")
	}
}

func TestSlurp_MissingPathParam(t *testing.T) {
	s := NewSlurp()
	if _, err := s.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Fatal("expected error for missing path parameter")
	}
}
