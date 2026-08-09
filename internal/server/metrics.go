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

// MetricsDumpInput is the input schema for the metrics_dump tool.
type MetricsDumpInput struct {
	From       string `json:"from,omitempty"`
	To         string `json:"to,omitempty"`
	Resolution string `json:"resolution,omitempty"`
}

// MetricsDumpOutput is the output schema for the metrics_dump tool: every
// known metric name mapped to its points in the requested range.
type MetricsDumpOutput struct {
	Metrics map[string][]MetricPoint `json:"metrics"`
}

// RegisterMetricsDump adds the metrics_dump tool: every metric this agent
// has recorded, in one call, without needing to know metric names in
// advance. This is what makes efficient bulk polling possible — the
// building block for "satellite" mode (a central Fleet Commander pulling
// this agent's full metric set on an interval) and "proxy" mode (an agent
// that itself pulls this same endpoint from a list of satellites and
// re-serves the aggregate) — see docs/plan.md's three operating modes.
// Always registered (read-only) regardless of the write gate.
func RegisterMetricsDump(s *mcp.Server, st store.Store) {
	mcp.AddTool(s, &mcp.Tool{
		Name: "metrics_dump",
		Description: "" +
			"Retrieve every metric this agent has recorded over a time range, in one call — " +
			"unlike metrics_query, no metric name is needed. This is the efficient bulk-export " +
			"path: a central system polling many agents (a 'Fleet Commander' in satellite mode, " +
			"or another agent acting as a proxy aggregating several satellites) calls this once " +
			"per interval instead of querying every known metric name individually. Same time-" +
			"bound and resolution semantics as metrics_query.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"from":       map[string]any{"type": "string", "description": `Range start: RFC3339 timestamp or relative duration like "1h". Default: 1h ago.`},
				"to":         map[string]any{"type": "string", "description": `Range end: RFC3339 timestamp or relative duration like "1h". Default: now.`},
				"resolution": map[string]any{"type": "string", "enum": []string{"raw", "hourly", "daily"}, "description": `Consolidation tier to read. Default "raw".`},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in MetricsDumpInput) (*mcp.CallToolResult, MetricsDumpOutput, error) {
		now := time.Now()
		from, err := parseTimeBound(in.From, now, -time.Hour)
		if err != nil {
			return nil, MetricsDumpOutput{}, fmt.Errorf("from: %w", err)
		}
		to, err := parseTimeBound(in.To, now, 0)
		if err != nil {
			return nil, MetricsDumpOutput{}, fmt.Errorf("to: %w", err)
		}
		resolution := store.ResolutionRaw
		if in.Resolution != "" {
			resolution = store.Resolution(in.Resolution)
		}

		metrics, err := dumpAllMetrics(ctx, st, from, to, resolution)
		if err != nil {
			return nil, MetricsDumpOutput{}, err
		}
		return nil, MetricsDumpOutput{Metrics: metrics}, nil
	})
}

// dumpAllMetrics queries every known metric name for [from, to) at
// resolution, shared by the metrics_dump MCP tool and its REST equivalent.
func dumpAllMetrics(ctx context.Context, st store.Store, from, to time.Time, resolution store.Resolution) (map[string][]MetricPoint, error) {
	names, err := st.ListMetricNames(ctx)
	if err != nil {
		return nil, fmt.Errorf("listing metric names: %w", err)
	}

	out := make(map[string][]MetricPoint, len(names))
	for _, name := range names {
		points, err := st.Query(ctx, name, from, to, nil, resolution)
		if err != nil {
			return nil, fmt.Errorf("querying %q: %w", name, err)
		}
		converted := make([]MetricPoint, len(points))
		for i, p := range points {
			converted[i] = MetricPoint{
				Timestamp: p.Timestamp.Format(time.RFC3339),
				Value:     p.Value,
				Labels:    p.Labels,
			}
		}
		out[name] = converted
	}
	return out, nil
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
