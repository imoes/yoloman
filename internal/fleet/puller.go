// Package fleet implements proxy-mode satellite polling (see docs/plan.md's
// "Three operating modes"): this agent, acting as a proxy, calls each
// configured satellite's REST metrics_dump endpoint over TLS and relays the
// returned points into the proxy's own store, labeled by satellite name.
//
// Trust model: satellite authentication mirrors how SSH authenticates a
// host, but via TLS certificates instead of the SSH protocol. There is no
// certificate authority — the proxy pins the satellite's exact public key
// (distributed out of band, analogous to an SSH known_hosts entry) and
// verifies the certificate the satellite presents during the TLS handshake
// against that pin. The satellite proves possession of the matching
// private key as part of the handshake itself; a bearer token authenticates
// the REST call underneath, same as any other REST client.
package fleet

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

// metricsDumpResponse mirrors server.MetricsDumpOutput's JSON shape. It is
// redeclared here (rather than importing internal/server) to avoid a
// dependency from fleet on the HTTP/MCP server package.
type metricsDumpResponse struct {
	Metrics map[string][]metricPoint `json:"metrics"`
}

type metricPoint struct {
	Timestamp string            `json:"timestamp"`
	Value     float64           `json:"value"`
	Labels    map[string]string `json:"labels,omitempty"`
}

// Puller pulls one satellite's metrics over a pinned-TLS REST call and
// writes them into a local store, labeled with the satellite's name.
type Puller struct {
	Satellite config.Satellite
	Store     store.Store
}

// PullOnce calls the satellite's bulk metrics_dump REST endpoint (GET
// /api/v1/metrics) over TLS for the given time range, verifying the
// satellite's certificate against its pinned public key, and writes the
// returned points into the local store with an added "satellite" label.
func (p *Puller) PullOnce(ctx context.Context, from, to time.Time) (int, error) {
	pinnedDER, err := loadPinnedPublicKeyDER(p.Satellite.PublicKeyPath)
	if err != nil {
		return 0, fmt.Errorf("satellite %q: %w", p.Satellite.Name, err)
	}

	httpClient := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				// There is no CA here — trust is established purely by
				// pinning the satellite's exact public key below, so the
				// default chain-of-trust verification is intentionally
				// bypassed in favor of that manual check.
				InsecureSkipVerify:    true, //nolint:gosec // verified manually via VerifyPeerCertificate
				VerifyPeerCertificate: verifyPinnedPublicKey(pinnedDER),
			},
		},
		Timeout: 30 * time.Second,
	}

	url := fmt.Sprintf("https://%s/api/v1/metrics?from=%s&to=%s",
		p.Satellite.Address, from.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, fmt.Errorf("satellite %q: building request: %w", p.Satellite.Name, err)
	}
	if p.Satellite.Token != "" {
		req.Header.Set("Authorization", "Bearer "+p.Satellite.Token)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("satellite %q: request failed: %w", p.Satellite.Name, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return 0, fmt.Errorf("satellite %q: unexpected status %d: %s", p.Satellite.Name, resp.StatusCode, body)
	}

	var dump metricsDumpResponse
	if err := json.NewDecoder(resp.Body).Decode(&dump); err != nil {
		return 0, fmt.Errorf("satellite %q: decoding response: %w", p.Satellite.Name, err)
	}

	var points []store.Point
	for metric, pts := range dump.Metrics {
		for _, mp := range pts {
			ts, err := time.Parse(time.RFC3339, mp.Timestamp)
			if err != nil {
				continue
			}
			labels := make(map[string]string, len(mp.Labels)+1)
			for k, v := range mp.Labels {
				labels[k] = v
			}
			labels["satellite"] = p.Satellite.Name
			points = append(points, store.Point{
				Metric:    metric,
				Timestamp: ts,
				Value:     mp.Value,
				Labels:    labels,
			})
		}
	}

	if len(points) == 0 {
		return 0, nil
	}
	if err := p.Store.WritePoints(ctx, points); err != nil {
		return 0, fmt.Errorf("satellite %q: writing points: %w", p.Satellite.Name, err)
	}
	return len(points), nil
}

// loadPinnedPublicKeyDER reads and parses a PEM-encoded PKIX public key file
// (e.g. produced by `openssl x509 -pubkey -noout` against the satellite's
// certificate), returning its canonical DER SubjectPublicKeyInfo encoding.
func loadPinnedPublicKeyDER(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading public_key_path %q: %w", path, err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("public_key_path %q: not a PEM file", path)
	}
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("public_key_path %q: parsing PKIX public key: %w", path, err)
	}
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		return nil, fmt.Errorf("public_key_path %q: re-marshaling public key: %w", path, err)
	}
	return der, nil
}

// verifyPinnedPublicKey builds a tls.Config.VerifyPeerCertificate callback
// that accepts the connection only if the leaf certificate's public key is
// byte-identical (via its DER SubjectPublicKeyInfo encoding) to pinnedDER —
// the SSH-host-key-style trust model this package uses instead of a CA.
func verifyPinnedPublicKey(pinnedDER []byte) func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		if len(rawCerts) == 0 {
			return fmt.Errorf("no certificate presented")
		}
		cert, err := x509.ParseCertificate(rawCerts[0])
		if err != nil {
			return fmt.Errorf("parsing presented certificate: %w", err)
		}
		presentedDER, err := x509.MarshalPKIXPublicKey(cert.PublicKey)
		if err != nil {
			return fmt.Errorf("marshaling presented public key: %w", err)
		}
		if !bytes.Equal(presentedDER, pinnedDER) {
			return fmt.Errorf("presented certificate's public key does not match the pinned key")
		}
		return nil
	}
}
