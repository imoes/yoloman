package desiredstate

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
)

// fakeBossman stands up a minimal Bossman: it serves a configurable
// desired-state generation and records acks. It answers 304 when the
// caller's current_hash matches the served hash.
type fakeBossman struct {
	mu       sync.Mutex
	gen      int64
	hash     string
	stateDoc string
	acks     []map[string]any
	wantTok  string
}

func (f *fakeBossman) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/agent/v1/desired-state", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+f.wantTok {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.URL.Query().Get("current_hash") == f.hash {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"agent_id":    "agent-1",
			"generation":  f.gen,
			"config_hash": f.hash,
			"state":       json.RawMessage(f.stateDoc),
		})
	})
	mux.HandleFunc("POST /api/agent/v1/ack", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+f.wantTok {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.acks = append(f.acks, body)
		f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "recorded"})
	})
	return mux
}

func newConsumer(t *testing.T, url string) *Consumer {
	t.Helper()
	return NewConsumer(url, "agent-token", filepath.Join(t.TempDir(), "desired-state.json"), nil)
}

func TestPullOnce_StoresAndAcks(t *testing.T) {
	fb := &fakeBossman{gen: 3, hash: "h3", stateDoc: `{"monitoring":{"checks":["docker_daemon"]}}`, wantTok: "agent-token"}
	srv := httptest.NewServer(fb.handler())
	defer srv.Close()
	c := newConsumer(t, srv.URL)

	changed, err := c.PullOnce(context.Background())
	if err != nil {
		t.Fatalf("PullOnce: %v", err)
	}
	if !changed {
		t.Fatal("expected changed=true on first pull")
	}
	st := c.Status()
	if !st.HasState || st.Generation != 3 || st.ConfigHash != "h3" {
		t.Fatalf("status = %+v, want gen 3 / h3", st)
	}
	if len(fb.acks) != 1 || fb.acks[0]["result"] != "ack" {
		t.Fatalf("acks = %+v, want one ack", fb.acks)
	}
}

func TestPullOnce_NotModifiedIsNoop(t *testing.T) {
	fb := &fakeBossman{gen: 3, hash: "h3", stateDoc: `{}`, wantTok: "agent-token"}
	srv := httptest.NewServer(fb.handler())
	defer srv.Close()
	c := newConsumer(t, srv.URL)

	if _, err := c.PullOnce(context.Background()); err != nil {
		t.Fatalf("first pull: %v", err)
	}
	// Second pull sends current_hash=h3 → 304 → no new ack.
	changed, err := c.PullOnce(context.Background())
	if err != nil {
		t.Fatalf("second pull: %v", err)
	}
	if changed {
		t.Fatal("expected changed=false on unchanged pull")
	}
	if len(fb.acks) != 1 {
		t.Fatalf("expected exactly 1 ack across two pulls, got %d", len(fb.acks))
	}
}

func TestPullOnce_NewerGenerationRollsPrevious(t *testing.T) {
	fb := &fakeBossman{gen: 1, hash: "h1", stateDoc: `{"v":1}`, wantTok: "agent-token"}
	srv := httptest.NewServer(fb.handler())
	defer srv.Close()
	c := newConsumer(t, srv.URL)

	if _, err := c.PullOnce(context.Background()); err != nil {
		t.Fatalf("pull gen1: %v", err)
	}
	// Bossman advances to generation 2.
	fb.mu.Lock()
	fb.gen, fb.hash, fb.stateDoc = 2, "h2", `{"v":2}`
	fb.mu.Unlock()

	changed, err := c.PullOnce(context.Background())
	if err != nil {
		t.Fatalf("pull gen2: %v", err)
	}
	if !changed || c.Status().Generation != 2 {
		t.Fatalf("expected current=gen2, got %+v", c.Status())
	}
	// Rollback restores generation 1.
	if err := c.Rollback(); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	if c.Status().Generation != 1 {
		t.Fatalf("after rollback want gen1, got %d", c.Status().Generation)
	}
}

func TestPersistenceSurvivesRestart(t *testing.T) {
	fb := &fakeBossman{gen: 5, hash: "h5", stateDoc: `{}`, wantTok: "agent-token"}
	srv := httptest.NewServer(fb.handler())
	defer srv.Close()
	path := filepath.Join(t.TempDir(), "ds.json")

	c1 := NewConsumer(srv.URL, "agent-token", path, nil)
	if _, err := c1.PullOnce(context.Background()); err != nil {
		t.Fatalf("pull: %v", err)
	}
	// A fresh consumer over the same file remembers the applied generation.
	c2 := NewConsumer(srv.URL, "agent-token", path, nil)
	if c2.Status().Generation != 5 {
		t.Fatalf("restarted consumer forgot state: %+v", c2.Status())
	}
}

func TestPullOnce_BadTokenErrors(t *testing.T) {
	fb := &fakeBossman{gen: 1, hash: "h1", stateDoc: `{}`, wantTok: "the-real-token"}
	srv := httptest.NewServer(fb.handler())
	defer srv.Close()
	c := NewConsumer(srv.URL, "wrong-token", filepath.Join(t.TempDir(), "ds.json"), nil)

	if _, err := c.PullOnce(context.Background()); err == nil {
		t.Fatal("expected error on 401, got nil")
	}
}
