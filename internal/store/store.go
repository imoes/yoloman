// Package store persists time-series metrics and labeled events (eBPF
// connections, exec events, and similar) to a local database, with a
// retention/downsampling job that bounds its growth — the flexible-schema
// alternative to RRD chosen for agentic-mcp (see docs/plan.md).
package store

import (
	"context"
	"time"
)

// Resolution identifies how consolidated a Point is.
type Resolution string

const (
	ResolutionRaw    Resolution = "raw"
	ResolutionHourly Resolution = "hourly"
	ResolutionDaily  Resolution = "daily"
)

// Point is one metric sample: a named, timestamped, optionally labeled
// value. Labels distinguish series within a metric (e.g. metric="net_bytes"
// with labels {"iface":"eth0","direction":"rx"}) — this is what a fixed-
// schema RRD file cannot represent.
type Point struct {
	Metric     string
	Timestamp  time.Time
	Value      float64
	Labels     map[string]string
	Resolution Resolution
}

// DownsampleStats reports how many rows a Downsample pass consolidated.
type DownsampleStats struct {
	RawRowsAggregated    int
	HourlyRowsCreated    int
	HourlyRowsAggregated int
	DailyRowsCreated     int
	EdgesPruned          int
}

// Edge is one persisted (process, destination) connection relationship —
// the durable counterpart of ebpf.TopTalker's in-memory aggregation,
// surviving restarts and reachable via a cursor-based bulk dump (see
// docs/plan.md's Bossman "v3" Block A) the same way metrics already are.
// Unlike metrics, an edge has several non-numeric dimensions (source
// process, destination, port, first/last-seen) that don't fit the generic
// Point{metric,value,labels} shape, so it gets its own table/methods
// instead of being shoehorned into WritePoints.
type Edge struct {
	Comm       string
	DstAddr    string
	DstPort    uint16
	EventCount int64
	FirstSeen  time.Time
	LastSeen   time.Time
	// LatencyNs is the most recently observed latency for this
	// (comm, destination) pair, or nil if none has been observed yet
	// (e.g. TCP connection edges carry no latency; disk I/O-derived
	// edges, if ever added, would).
	LatencyNs *int64
}

// Store is the storage backend for metrics/events. v1 ships a single SQLite
// implementation (see sqlite.go); the interface exists so a future driver
// (e.g. for the Fleet Commander) can be swapped in without touching callers.
type Store interface {
	// WritePoints appends points, always at ResolutionRaw regardless of
	// what the caller set — only Downsample produces hourly/daily rows.
	WritePoints(ctx context.Context, points []Point) error

	// Query returns points for metric within [from, to), optionally
	// restricted to series matching every key/value in labels (a series
	// matches if its labels are a superset of the filter), at the given
	// resolution.
	Query(ctx context.Context, metric string, from, to time.Time, labels map[string]string, resolution Resolution) ([]Point, error)

	// ListMetricNames returns every distinct metric name present in the
	// store, for bulk-export use (satellite/proxy pull modes, see
	// docs/plan.md) where a caller wants "everything" without knowing
	// metric names in advance.
	ListMetricNames(ctx context.Context) ([]string, error)

	// Downsample aggregates (by averaging) raw points older than
	// rawCutoff into hourly points, deleting the source raw rows, then
	// aggregates hourly points older than hourlyCutoff into daily points,
	// deleting the source hourly rows. It is safe to call repeatedly
	// (e.g. from a periodic ticker); each call only processes rows past
	// the given cutoffs. It also prunes connection edges last seen
	// before rawCutoff (see EdgesPruned), riding the same retention
	// cadence as metrics rather than needing a separate cron mechanism.
	Downsample(ctx context.Context, rawCutoff, hourlyCutoff time.Time) (DownsampleStats, error)

	// UpsertEdge records one observed (comm, destination) connection: on
	// first sight, inserts a new row with event_count=1; on a repeat
	// sight of the same (comm, dst_addr, dst_port), increments
	// event_count, advances last_seen, and overwrites latencyNs with the
	// latest observation (nil leaves any existing latency untouched,
	// rather than clearing it, since not every caller can supply one).
	UpsertEdge(ctx context.Context, comm, dstAddr string, dstPort uint16, latencyNs *int64) error

	// ListEdgesSince returns every edge whose LastSeen is >= since — the
	// cursor a bulk-dump caller (a proxy, or a future Bossman poller)
	// uses to fetch only what changed since its last successful pull, the
	// same incremental-pull shape ListMetricNames/Query already give for
	// metrics.
	ListEdgesSince(ctx context.Context, since time.Time) ([]Edge, error)

	Close() error
}
