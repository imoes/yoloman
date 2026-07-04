package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

const schemaSQL = `
CREATE TABLE IF NOT EXISTS metrics (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	metric TEXT NOT NULL,
	ts INTEGER NOT NULL,
	value REAL NOT NULL,
	labels TEXT NOT NULL DEFAULT '{}',
	resolution TEXT NOT NULL DEFAULT 'raw'
);
CREATE INDEX IF NOT EXISTS idx_metrics_lookup ON metrics(metric, resolution, ts);

CREATE TABLE IF NOT EXISTS connection_edges (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	comm TEXT NOT NULL,
	dst_addr TEXT NOT NULL,
	dst_port INTEGER NOT NULL,
	event_count INTEGER NOT NULL DEFAULT 0,
	first_seen INTEGER NOT NULL,
	last_seen INTEGER NOT NULL,
	latency_ns INTEGER,
	UNIQUE(comm, dst_addr, dst_port)
);
CREATE INDEX IF NOT EXISTS idx_connection_edges_last_seen ON connection_edges(last_seen);
`

// SQLiteStore is the v1 Store backend: a single local SQLite file (or
// ":memory:" for tests), no external service required.
type SQLiteStore struct {
	db *sql.DB
}

// OpenSQLite opens (creating if necessary) a SQLite-backed Store at path,
// creating its parent directory and schema as needed.
func OpenSQLite(path string) (*SQLiteStore, error) {
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, fmt.Errorf("creating store directory for %q: %w", path, err)
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("opening sqlite store %q: %w", path, err)
	}
	// SQLite handles one writer at a time; serializing through a single
	// connection avoids SQLITE_BUSY under concurrent access from this
	// process without needing WAL/busy-timeout tuning for v1.
	db.SetMaxOpenConns(1)

	if _, err := db.Exec(schemaSQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("creating schema in %q: %w", path, err)
	}
	return &SQLiteStore{db: db}, nil
}

func (s *SQLiteStore) Close() error { return s.db.Close() }

// canonicalLabels JSON-encodes labels with keys in sorted order (Go's
// encoding/json always sorts map[string]string keys), so that identical
// label sets always produce byte-identical text — required for the
// GROUP BY labels used in Downsample's consolidation queries.
func canonicalLabels(labels map[string]string) (string, error) {
	if labels == nil {
		labels = map[string]string{}
	}
	data, err := json.Marshal(labels)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (s *SQLiteStore) WritePoints(ctx context.Context, points []Point) error {
	if len(points) == 0 {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO metrics (metric, ts, value, labels, resolution) VALUES (?, ?, ?, ?, 'raw')`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, p := range points {
		labelsJSON, err := canonicalLabels(p.Labels)
		if err != nil {
			return fmt.Errorf("encoding labels for metric %q: %w", p.Metric, err)
		}
		if _, err := stmt.ExecContext(ctx, p.Metric, p.Timestamp.Unix(), p.Value, labelsJSON); err != nil {
			return fmt.Errorf("inserting point for metric %q: %w", p.Metric, err)
		}
	}
	return tx.Commit()
}

func (s *SQLiteStore) Query(ctx context.Context, metric string, from, to time.Time, labels map[string]string, resolution Resolution) ([]Point, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT ts, value, labels, resolution FROM metrics
		WHERE metric = ? AND resolution = ? AND ts >= ? AND ts < ?
		ORDER BY ts ASC
	`, metric, string(resolution), from.Unix(), to.Unix())
	if err != nil {
		return nil, fmt.Errorf("querying metric %q: %w", metric, err)
	}
	defer rows.Close()

	var out []Point
	for rows.Next() {
		var ts int64
		var value float64
		var labelsJSON, res string
		if err := rows.Scan(&ts, &value, &labelsJSON, &res); err != nil {
			return nil, err
		}
		var rowLabels map[string]string
		if err := json.Unmarshal([]byte(labelsJSON), &rowLabels); err != nil {
			return nil, fmt.Errorf("decoding labels: %w", err)
		}
		if !labelsMatch(rowLabels, labels) {
			continue
		}
		out = append(out, Point{
			Metric:     metric,
			Timestamp:  time.Unix(ts, 0).UTC(),
			Value:      value,
			Labels:     rowLabels,
			Resolution: Resolution(res),
		})
	}
	return out, rows.Err()
}

func (s *SQLiteStore) ListMetricNames(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT metric FROM metrics ORDER BY metric`)
	if err != nil {
		return nil, fmt.Errorf("listing metric names: %w", err)
	}
	defer rows.Close()

	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		names = append(names, name)
	}
	return names, rows.Err()
}

// labelsMatch reports whether have is a superset of want (every key/value in
// want is present and equal in have).
func labelsMatch(have, want map[string]string) bool {
	for k, v := range want {
		if have[k] != v {
			return false
		}
	}
	return true
}

func (s *SQLiteStore) Downsample(ctx context.Context, rawCutoff, hourlyCutoff time.Time) (DownsampleStats, error) {
	var stats DownsampleStats

	aggregated, created, err := s.consolidate(ctx, ResolutionRaw, ResolutionHourly, 3600, rawCutoff)
	if err != nil {
		return stats, fmt.Errorf("downsampling raw->hourly: %w", err)
	}
	stats.RawRowsAggregated = aggregated
	stats.HourlyRowsCreated = created

	aggregated2, created2, err := s.consolidate(ctx, ResolutionHourly, ResolutionDaily, 86400, hourlyCutoff)
	if err != nil {
		return stats, fmt.Errorf("downsampling hourly->daily: %w", err)
	}
	stats.HourlyRowsAggregated = aggregated2
	stats.DailyRowsCreated = created2

	pruned, err := s.pruneEdges(ctx, rawCutoff)
	if err != nil {
		return stats, fmt.Errorf("pruning connection edges: %w", err)
	}
	stats.EdgesPruned = pruned

	return stats, nil
}

// pruneEdges deletes connection edges last seen before cutoff, riding the
// same retention cadence as metrics (see Downsample) rather than needing a
// separate cron mechanism.
func (s *SQLiteStore) pruneEdges(ctx context.Context, cutoff time.Time) (int, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM connection_edges WHERE last_seen < ?`, cutoff.Unix())
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	return int(n), err
}

func (s *SQLiteStore) UpsertEdge(ctx context.Context, comm, dstAddr string, dstPort uint16, latencyNs *int64) error {
	now := time.Now().Unix()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO connection_edges (comm, dst_addr, dst_port, event_count, first_seen, last_seen, latency_ns)
		VALUES (?, ?, ?, 1, ?, ?, ?)
		ON CONFLICT(comm, dst_addr, dst_port) DO UPDATE SET
			event_count = event_count + 1,
			last_seen = excluded.last_seen,
			latency_ns = COALESCE(excluded.latency_ns, connection_edges.latency_ns)
	`, comm, dstAddr, dstPort, now, now, latencyNs)
	if err != nil {
		return fmt.Errorf("upserting edge %s->%s:%d: %w", comm, dstAddr, dstPort, err)
	}
	return nil
}

func (s *SQLiteStore) ListEdgesSince(ctx context.Context, since time.Time) ([]Edge, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT comm, dst_addr, dst_port, event_count, first_seen, last_seen, latency_ns
		FROM connection_edges
		WHERE last_seen >= ?
		ORDER BY last_seen ASC
	`, since.Unix())
	if err != nil {
		return nil, fmt.Errorf("listing edges: %w", err)
	}
	defer rows.Close()

	var out []Edge
	for rows.Next() {
		var e Edge
		var firstSeen, lastSeen int64
		var latencyNs sql.NullInt64
		if err := rows.Scan(&e.Comm, &e.DstAddr, &e.DstPort, &e.EventCount, &firstSeen, &lastSeen, &latencyNs); err != nil {
			return nil, err
		}
		e.FirstSeen = time.Unix(firstSeen, 0).UTC()
		e.LastSeen = time.Unix(lastSeen, 0).UTC()
		if latencyNs.Valid {
			v := latencyNs.Int64
			e.LatencyNs = &v
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// consolidate averages every (metric, labels) series' `from`-resolution
// points older than cutoff into bucketSeconds-wide `to`-resolution points,
// then deletes the source rows. It returns how many source rows were
// aggregated and how many consolidated rows were created.
func (s *SQLiteStore) consolidate(ctx context.Context, from, to Resolution, bucketSeconds int64, cutoff time.Time) (aggregated, created int, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()

	rows, err := tx.QueryContext(ctx, `
		SELECT metric, labels, (ts / ?) * ? AS bucket, AVG(value), COUNT(*)
		FROM metrics
		WHERE resolution = ? AND ts < ?
		GROUP BY metric, labels, bucket
	`, bucketSeconds, bucketSeconds, string(from), cutoff.Unix())
	if err != nil {
		return 0, 0, fmt.Errorf("aggregating %s rows: %w", from, err)
	}

	type bucketRow struct {
		metric, labels string
		bucket         int64
		avg            float64
		count          int
	}
	var buckets []bucketRow
	for rows.Next() {
		var b bucketRow
		if err := rows.Scan(&b.metric, &b.labels, &b.bucket, &b.avg, &b.count); err != nil {
			rows.Close()
			return 0, 0, err
		}
		buckets = append(buckets, b)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, 0, err
	}
	rows.Close()

	if len(buckets) > 0 {
		insertStmt, err := tx.PrepareContext(ctx, `INSERT INTO metrics (metric, ts, value, labels, resolution) VALUES (?, ?, ?, ?, ?)`)
		if err != nil {
			return 0, 0, err
		}
		defer insertStmt.Close()

		for _, b := range buckets {
			if _, err := insertStmt.ExecContext(ctx, b.metric, b.bucket, b.avg, b.labels, string(to)); err != nil {
				return 0, 0, fmt.Errorf("inserting %s bucket: %w", to, err)
			}
			aggregated += b.count
			created++
		}
	}

	if _, err := tx.ExecContext(ctx, `DELETE FROM metrics WHERE resolution = ? AND ts < ?`, string(from), cutoff.Unix()); err != nil {
		return 0, 0, fmt.Errorf("deleting consolidated %s rows: %w", from, err)
	}

	return aggregated, created, tx.Commit()
}

var _ Store = (*SQLiteStore)(nil)
