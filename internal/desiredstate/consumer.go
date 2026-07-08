// Package desiredstate implements the L4 agent-side desired-state consumer
// (see docs/policy-orchestration-architecture.md §6): the agent periodically
// PULLs its compiled desired state from the central Bossman controller,
// stores it locally (keeping the previous generation for rollback), and ACKs
// it. Reverse of the rest of the agent, which is called INTO; here the agent
// calls OUT to Bossman, authenticating with its own bearer token.
//
// This v1 is deliberately non-destructive: it fetches, verifies the
// generation is newer, persists, and acks — it does NOT yet re-apply the
// monitoring config to change which checks run (that behavioral step is a
// separate block). Payload signature verification is likewise a documented
// TODO: Bossman does not sign desired-state payloads yet, so only the
// generation/transport is validated here.
package desiredstate

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// State is one applied desired-state generation.
type State struct {
	Generation int64           `json:"generation"`
	ConfigHash string          `json:"config_hash"`
	Doc        json.RawMessage `json:"doc"`
	AppliedAt  time.Time       `json:"applied_at"`
}

type persisted struct {
	Current  *State `json:"current"`
	Previous *State `json:"previous"`
}

// Consumer pulls + tracks this agent's desired state.
type Consumer struct {
	baseURL string
	token   string
	path    string // JSON persistence file
	client  *http.Client

	mu       sync.Mutex
	current  *State
	previous *State
}

// NewConsumer builds a consumer for the given Bossman base URL + agent
// token, persisting to path. It loads any previously persisted state so an
// agent restart doesn't forget its applied generation.
func NewConsumer(baseURL, token, path string, client *http.Client) *Consumer {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	c := &Consumer{baseURL: strings.TrimRight(baseURL, "/"), token: token, path: path, client: client}
	c.load()
	return c
}

func (c *Consumer) load() {
	data, err := os.ReadFile(c.path)
	if err != nil {
		return // no persisted state yet (first run) — fine
	}
	var p persisted
	if json.Unmarshal(data, &p) == nil {
		c.current, c.previous = p.Current, p.Previous
	}
}

func (c *Consumer) persist() error {
	// Atomic write: temp file + rename, so a crash mid-write never leaves a
	// half-written state file.
	data, err := json.MarshalIndent(persisted{Current: c.current, Previous: c.previous}, "", "  ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(c.path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

// Status is the read-only view GET /api/v1/state reports.
type Status struct {
	HasState   bool      `json:"has_state"`
	Generation int64     `json:"generation"`
	ConfigHash string    `json:"config_hash"`
	AppliedAt  time.Time `json:"applied_at"`
}

func (c *Consumer) Status() Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current == nil {
		return Status{HasState: false}
	}
	return Status{
		HasState:   true,
		Generation: c.current.Generation,
		ConfigHash: c.current.ConfigHash,
		AppliedAt:  c.current.AppliedAt,
	}
}

// desiredStateResponse mirrors bossman/api/agent_facing.py's DesiredStateResponse.
type desiredStateResponse struct {
	AgentID    string          `json:"agent_id"`
	Generation int64           `json:"generation"`
	ConfigHash string          `json:"config_hash"`
	State      json.RawMessage `json:"state"`
}

// PullOnce fetches the desired state once. It sends the current config_hash so
// Bossman can answer 304 when nothing changed; on a newer generation it rolls
// the current into previous, stores the new one, persists, and acks. Returns
// (changed, err).
func (c *Consumer) PullOnce(ctx context.Context) (bool, error) {
	c.mu.Lock()
	curHash := ""
	curGen := int64(0)
	if c.current != nil {
		curHash = c.current.ConfigHash
		curGen = c.current.Generation
	}
	c.mu.Unlock()

	url := c.baseURL + "/api/agent/v1/desired-state"
	if curHash != "" {
		url += "?current_hash=" + curHash
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)

	resp, err := c.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("pulling desired state: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotModified {
		return false, nil // unchanged — nothing to do
	}
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return false, fmt.Errorf("desired-state pull failed: %s: %s", resp.Status, msg)
	}

	var body desiredStateResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return false, fmt.Errorf("decoding desired state: %w", err)
	}
	// Generation guard: never move backwards (a stale/replayed response
	// can't downgrade the applied generation).
	if body.Generation <= curGen && curGen != 0 {
		return false, nil
	}

	newState := &State{
		Generation: body.Generation,
		ConfigHash: body.ConfigHash,
		Doc:        body.State,
		AppliedAt:  time.Now().UTC(),
	}
	c.mu.Lock()
	c.previous = c.current // keep the prior generation for rollback
	c.current = newState
	if err := c.persist(); err != nil {
		c.mu.Unlock()
		// Nack: we couldn't durably store it, so don't claim success.
		_ = c.ack(ctx, body.Generation, "nack", map[string]any{"error": "persist failed: " + err.Error()})
		return false, fmt.Errorf("persisting desired state: %w", err)
	}
	c.mu.Unlock()

	if err := c.ack(ctx, body.Generation, "ack", nil); err != nil {
		return true, fmt.Errorf("acking generation %d: %w", body.Generation, err)
	}
	return true, nil
}

// Rollback restores the previous generation as current (kept for the
// behavioral-apply block; unused by the non-destructive v1 pull path).
func (c *Consumer) Rollback() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.previous == nil {
		return fmt.Errorf("no previous generation to roll back to")
	}
	c.current, c.previous = c.previous, nil
	return c.persist()
}

func (c *Consumer) ack(ctx context.Context, generation int64, result string, detail map[string]any) error {
	payload := map[string]any{"generation": generation, "result": result}
	if detail != nil {
		payload["detail"] = detail
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/agent/v1/ack", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("ack rejected: %s: %s", resp.Status, msg)
	}
	return nil
}

// Loop pulls on an interval until ctx is cancelled, mirroring the agent's
// other cancellable background loops (internal/fleet/manager.go).
func (c *Consumer) Loop(ctx context.Context, interval time.Duration, onError func(error)) {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if _, err := c.PullOnce(ctx); err != nil && onError != nil {
			onError(err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
