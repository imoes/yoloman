package server

import (
	"context"
	"fmt"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/store"
)

// MetricsQueryInput is the input schema for the metrics_query tool.
type MetricsQueryInput struct {
	Metric     string            `json:"metric"`
	From       string            `json:"from,omitempty"`
	To         string            `json:"to,omitempty"`
	Labels     map[string]string `json:"labels,omitempty"`
	Resolution string            `json:"resolution,omitempty"`
}

// MetricsQueryOutput is the output schema for the metrics_query tool.
type MetricsQueryOutput struct {
	Points []MetricPoint `json:"points"`
}

// MetricPoint is one JSON-friendly point in a metrics_query response.
type MetricPoint struct {
	Timestamp string            `json:"timestamp"`
	Value     float64           `json:"value"`
	Labels    map[string]string `json:"labels,omitempty"`
}

// RegisterMetrics adds the metrics_query tool, letting a caller retrieve
// stored performance data without learning a query language. Always
// registered (read-only) regardless of the write gate.
func RegisterMetrics(s *mcp.Server, st store.Store) {
	mcp.AddTool(s, &mcp.Tool{
		Name: "metrics_query",
		Description: "" +
			"Retrieve previously collected performance/metric data points for a named metric " +
			"over a time range — e.g. CPU load, memory usage, or network counters recorded by " +
			"this agent. Time bounds accept RFC3339 timestamps (\"2026-07-03T12:00:00Z\") or a " +
			"simple relative duration ending in the current time (\"1h\", \"30m\", \"24h\"); " +
			"`from` defaults to 1h ago and `to` defaults to now if omitted. `labels` filters to " +
			"series whose labels are a superset of the given key/values (e.g. " +
			"{\"iface\": \"eth0\"} for a specific network interface). `resolution` selects which " +
			"consolidation tier to read: \"raw\" (full detail, recent data only — see the " +
			"retention job), \"hourly\", or \"daily\" (coarser, further back in time); defaults " +
			"to \"raw\".",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"metric": map[string]any{"type": "string", "description": `Metric name, e.g. "cpu_pct" or "net_bytes".`},
				"from":   map[string]any{"type": "string", "description": `Range start: RFC3339 timestamp or relative duration like "1h". Default: 1h ago.`},
				"to":     map[string]any{"type": "string", "description": `Range end: RFC3339 timestamp or relative duration like "1h" (meaning "1h ago" as the end bound). Default: now.`},
				"labels": map[string]any{
					"type":                 "object",
					"additionalProperties": map[string]any{"type": "string"},
					"description":          "Only return series whose labels match every given key/value.",
				},
				"resolution": map[string]any{"type": "string", "enum": []string{"raw", "hourly", "daily"}, "description": `Consolidation tier to read. Default "raw".`},
			},
			"required": []string{"metric"},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in MetricsQueryInput) (*mcp.CallToolResult, MetricsQueryOutput, error) {
		now := time.Now()
		from, err := parseTimeBound(in.From, now, -time.Hour)
		if err != nil {
			return nil, MetricsQueryOutput{}, fmt.Errorf("from: %w", err)
		}
		to, err := parseTimeBound(in.To, now, 0)
		if err != nil {
			return nil, MetricsQueryOutput{}, fmt.Errorf("to: %w", err)
		}
		resolution := store.ResolutionRaw
		if in.Resolution != "" {
			resolution = store.Resolution(in.Resolution)
		}

		points, err := st.Query(ctx, in.Metric, from, to, in.Labels, resolution)
		if err != nil {
			return nil, MetricsQueryOutput{}, err
		}

		out := make([]MetricPoint, len(points))
		for i, p := range points {
			out[i] = MetricPoint{
				Timestamp: p.Timestamp.Format(time.RFC3339),
				Value:     p.Value,
				Labels:    p.Labels,
			}
		}
		return nil, MetricsQueryOutput{Points: out}, nil
	})
}

// parseTimeBound parses s as either an RFC3339 timestamp or a Go duration
// (interpreted as "that far before now"); an empty s yields now+defaultOffset.
func parseTimeBound(s string, now time.Time, defaultOffset time.Duration) (time.Time, error) {
	if s == "" {
		return now.Add(defaultOffset), nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, nil
	}
	if d, err := time.ParseDuration(s); err == nil {
		return now.Add(-d), nil
	}
	return time.Time{}, fmt.Errorf("value %q is neither an RFC3339 timestamp nor a duration like \"1h\"", s)
}
