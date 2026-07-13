// Package enroll implements the client side of this agent registering
// itself with the central Fleet Commander ("Bossman"): a one-time bootstrap
// handshake that hands Bossman this agent's name/token/address and returns
// Bossman's public key, so this agent can add Bossman to its own
// tls.trusted_client_keys and let Bossman authenticate itself over TLS
// client certificates from then on (see internal/tlsauth).
//
// Bossman enrollment is open (no secret — the SSH-driven deploy path is the
// authenticated way to add a host; the manual register command is a
// convenience); the optional EnrollSecret is only honored by a Selecta proxy.
// The contract is a single POST /api/v1/enroll endpoint, described by
// Request/Response below.
package enroll

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Request is the enrollment request body this agent sends to Bossman.
type Request struct {
	// Name identifies this agent to Bossman (e.g. its hostname).
	Name string `json:"name"`
	// EnrollSecret is an optional shared bootstrap secret. Bossman enrollment
	// is open and ignores it; a Selecta proxy (internal/server/enroll.go) may
	// still require it, so the generic client keeps sending it when provided.
	EnrollSecret string `json:"enroll_secret,omitempty"`
	// Token is this agent's own REST/MCP bearer token, handed to Bossman
	// so it knows how to authenticate its own calls back to this agent.
	Token string `json:"token"`
	// Address is this agent's own reachable host:port, so Bossman can
	// reach it in satellite/proxy mode. Optional.
	Address string `json:"address,omitempty"`
}

// Response is Bossman's reply to a successful enrollment request.
type Response struct {
	// BossmanPublicKey is Bossman's PEM-encoded PKIX public key — write it
	// to disk and reference it from tls.trusted_client_keys.
	BossmanPublicKey string `json:"bossman_public_key"`
	// AgentID is an identifier Bossman assigned this agent, if any.
	AgentID string `json:"agent_id,omitempty"`
}

// Result is what Register returns on success.
type Result struct {
	AgentID      string
	PublicKeyPEM []byte
}

// Register calls bossmanURL+"/api/v1/enroll" with req and returns Bossman's
// public key on success. It uses the standard library's default TLS
// verification (a normal CA-signed or otherwise pre-trusted certificate on
// Bossman's enrollment endpoint) since no pinned key can exist yet — this
// call is the bootstrap step that establishes one for all future calls.
func Register(ctx context.Context, bossmanURL string, req Request) (Result, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return Result{}, fmt.Errorf("encoding enrollment request: %w", err)
	}

	url := strings.TrimRight(bossmanURL, "/") + "/api/v1/enroll"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return Result{}, fmt.Errorf("building enrollment request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return Result{}, fmt.Errorf("calling %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return Result{}, fmt.Errorf("enrollment rejected: %s: %s", resp.Status, msg)
	}

	var out Response
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return Result{}, fmt.Errorf("decoding enrollment response: %w", err)
	}
	if out.BossmanPublicKey == "" {
		return Result{}, fmt.Errorf("enrollment response contained no bossman_public_key")
	}

	return Result{AgentID: out.AgentID, PublicKeyPEM: []byte(out.BossmanPublicKey)}, nil
}
