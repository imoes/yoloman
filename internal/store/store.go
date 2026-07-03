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

	// Downsample aggregates (by averaging) raw points older than
	// rawCutoff into hourly points, deleting the source raw rows, then
	// aggregates hourly points older than hourlyCutoff into daily points,
	// deleting the source hourly rows. It is safe to call repeatedly
	// (e.g. from a periodic ticker); each call only processes rows past
	// the given cutoffs.
	Downsample(ctx context.Context, rawCutoff, hourlyCutoff time.Time) (DownsampleStats, error)

	Close() error
}
