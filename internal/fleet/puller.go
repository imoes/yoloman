// Package fleet implements proxy-mode satellite polling (see docs/plan.md's
// "Three operating modes"): this agent, acting as a proxy, calls each
// configured satellite's REST metrics_dump endpoint over TLS and relays the
// returned points into the proxy's own store, labeled by satellite name.
//
// Authentication mirrors SSH's client-key model, but via TLS client
// certificates (see internal/tlsauth): the proxy holds its own private key
// and presents the matching client certificate during the TLS handshake;
// each satellite verifies that certificate's public key against its own
// pinned tls.trusted_client_keys list, distributed out of band ahead of
// time. This is the same identity a future Fleet Commander would use to
// authenticate directly against any node agent's REST/MCP API. The
// satellite's bearer Token authenticates the REST call underneath, in
// addition to (not instead of) the client certificate.
package fleet

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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

// Puller pulls one satellite's metrics over TLS, authenticating with
// ClientCert, and writes them into a local store labeled with the
// satellite's name.
type Puller struct {
	Satellite  config.Satellite
	ClientCert tls.Certificate
	Store      store.Store
}

// LoadClientCert loads this proxy's own TLS client identity — the
// certificate and private key it presents to every satellite it polls
// (config.Proxy.ClientCertFile/ClientKeyFile).
func LoadClientCert(certFile, keyFile string) (tls.Certificate, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("loading proxy client certificate: %w", err)
	}
	return cert, nil
}

// PullOnce calls the satellite's bulk metrics_dump REST endpoint (GET
// /api/v1/metrics) over TLS for the given time range, presenting
// p.ClientCert as this proxy's identity, and writes the returned points
// into the local store with an added "satellite" label.
func (p *Puller) PullOnce(ctx context.Context, from, to time.Time) (int, error) {
	httpClient := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				Certificates: []tls.Certificate{p.ClientCert},
				// There is no CA here: this proxy does not verify the
				// satellite's identity — see docs/plan.md's "Three
				// operating modes" for the confirmed trade-off. Trust runs
				// in the other direction: the satellite verifies this
				// proxy's client certificate against its own pinned
				// tls.trusted_client_keys.
				InsecureSkipVerify: true, //nolint:gosec // satellite identity intentionally not verified, see comment above
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
