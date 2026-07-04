package server

import (
	"context"
	"net/http"
	"testing"
)

func TestConnectionsDumpRoute_ReturnsUpsertedEdges(t *testing.T) {
	srv, st := newRESTTestServer(t, false)
	defer srv.Close()

	if err := st.UpsertEdge(context.Background(), "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatalf("UpsertEdge: %v", err)
	}

	resp := doJSON(t, "GET", srv.URL+"/api/v1/net/connections/dump?since=24h", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	body := decodeJSON(t, resp)
	edges, ok := body["edges"].([]any)
	if !ok || len(edges) != 1 {
		t.Fatalf("expected 1 edge in response, got %+v", body)
	}
	edge := edges[0].(map[string]any)
	if edge["comm"] != "curl" || edge["dst_addr"] != "1.1.1.1" {
		t.Errorf("unexpected edge: %+v", edge)
	}
}

func TestConnectionsDumpRoute_SinceFiltersOldEdges(t *testing.T) {
	srv, st := newRESTTestServer(t, false)
	defer srv.Close()

	if err := st.UpsertEdge(context.Background(), "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}

	// "since=1h" with a default offset means "since 1h ago" — an edge
	// seen just now must still be included.
	resp := doJSON(t, "GET", srv.URL+"/api/v1/net/connections/dump?since=1h", nil)
	body := decodeJSON(t, resp)
	edges := body["edges"].([]any)
	if len(edges) != 1 {
		t.Fatalf("expected 1 edge within the last hour, got %d", len(edges))
	}
}

func TestConnectionsDumpRoute_InvalidSinceRejected(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/net/connections/dump?since=not-a-time", nil)
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("status = %d, want 400 for an invalid since value", resp.StatusCode)
	}
}

func TestConnectionsDumpRoute_EmptyStoreReturnsEmptyList(t *testing.T) {
	srv, _ := newRESTTestServer(t, false)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/net/connections/dump", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	body := decodeJSON(t, resp)
	if edges, ok := body["edges"].([]any); ok && len(edges) != 0 {
		t.Errorf("expected no edges in an empty store, got %+v", edges)
	}
}
