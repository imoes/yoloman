package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func openTestStore(t *testing.T) *SQLiteStore {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	s, err := OpenSQLite(path)
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestWritePoints_AndQuery(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	base := time.Unix(1_700_000_000, 0).UTC()

	err := s.WritePoints(ctx, []Point{
		{Metric: "cpu_pct", Timestamp: base, Value: 12.5},
		{Metric: "cpu_pct", Timestamp: base.Add(time.Minute), Value: 15.0},
	})
	if err != nil {
		t.Fatalf("WritePoints: %v", err)
	}

	points, err := s.Query(ctx, "cpu_pct", base.Add(-time.Hour), base.Add(time.Hour), nil, ResolutionRaw)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if len(points) != 2 {
		t.Fatalf("expected 2 points, got %d", len(points))
	}
	if points[0].Value != 12.5 || points[1].Value != 15.0 {
		t.Errorf("unexpected values: %+v", points)
	}
}

func TestQuery_FiltersByTimeRange(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	base := time.Unix(1_700_000_000, 0).UTC()

	if err := s.WritePoints(ctx, []Point{
		{Metric: "m", Timestamp: base, Value: 1},
		{Metric: "m", Timestamp: base.Add(2 * time.Hour), Value: 2},
	}); err != nil {
		t.Fatal(err)
	}

	points, err := s.Query(ctx, "m", base.Add(-time.Minute), base.Add(time.Hour), nil, ResolutionRaw)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if len(points) != 1 || points[0].Value != 1 {
		t.Errorf("expected only the first point in range, got %+v", points)
	}
}

func TestQuery_FiltersByLabels(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	base := time.Unix(1_700_000_000, 0).UTC()

	if err := s.WritePoints(ctx, []Point{
		{Metric: "net_bytes", Timestamp: base, Value: 100, Labels: map[string]string{"iface": "eth0", "dir": "rx"}},
		{Metric: "net_bytes", Timestamp: base, Value: 200, Labels: map[string]string{"iface": "eth1", "dir": "rx"}},
	}); err != nil {
		t.Fatal(err)
	}

	points, err := s.Query(ctx, "net_bytes", base.Add(-time.Minute), base.Add(time.Minute),
		map[string]string{"iface": "eth0"}, ResolutionRaw)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if len(points) != 1 || points[0].Value != 100 {
		t.Errorf("expected only eth0 point, got %+v", points)
	}
}

func TestQuery_DifferentMetricsDoNotMix(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	base := time.Unix(1_700_000_000, 0).UTC()

	if err := s.WritePoints(ctx, []Point{
		{Metric: "a", Timestamp: base, Value: 1},
		{Metric: "b", Timestamp: base, Value: 2},
	}); err != nil {
		t.Fatal(err)
	}
	points, err := s.Query(ctx, "a", base.Add(-time.Minute), base.Add(time.Minute), nil, ResolutionRaw)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if len(points) != 1 || points[0].Metric != "a" {
		t.Errorf("expected only metric 'a', got %+v", points)
	}
}

func TestDownsample_RawToHourlyAveragesAndDeletesSource(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	// Two raw points within the same hour bucket.
	hourStart := time.Unix(1_700_000_000/3600*3600, 0).UTC()

	if err := s.WritePoints(ctx, []Point{
		{Metric: "cpu_pct", Timestamp: hourStart.Add(5 * time.Minute), Value: 10},
		{Metric: "cpu_pct", Timestamp: hourStart.Add(35 * time.Minute), Value: 20},
	}); err != nil {
		t.Fatal(err)
	}

	cutoff := hourStart.Add(2 * time.Hour) // well past both raw points
	stats, err := s.Downsample(ctx, cutoff, time.Unix(0, 0))
	if err != nil {
		t.Fatalf("Downsample: %v", err)
	}
	if stats.RawRowsAggregated != 2 || stats.HourlyRowsCreated != 1 {
		t.Errorf("unexpected stats: %+v", stats)
	}

	raw, err := s.Query(ctx, "cpu_pct", hourStart.Add(-time.Hour), hourStart.Add(time.Hour), nil, ResolutionRaw)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 0 {
		t.Errorf("expected raw rows to be deleted after downsampling, got %+v", raw)
	}

	hourly, err := s.Query(ctx, "cpu_pct", hourStart.Add(-time.Hour), hourStart.Add(time.Hour), nil, ResolutionHourly)
	if err != nil {
		t.Fatal(err)
	}
	if len(hourly) != 1 {
		t.Fatalf("expected 1 hourly point, got %d", len(hourly))
	}
	if hourly[0].Value != 15 { // average of 10 and 20
		t.Errorf("hourly value = %v, want 15 (average)", hourly[0].Value)
	}
	if !hourly[0].Timestamp.Equal(hourStart) {
		t.Errorf("hourly bucket timestamp = %v, want %v", hourly[0].Timestamp, hourStart)
	}
}

func TestDownsample_DoesNotTouchRecentRawPoints(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	now := time.Unix(1_700_000_000, 0).UTC()

	if err := s.WritePoints(ctx, []Point{{Metric: "m", Timestamp: now, Value: 1}}); err != nil {
		t.Fatal(err)
	}

	// Cutoff in the past: the point is newer than the cutoff, so it must survive.
	stats, err := s.Downsample(ctx, now.Add(-time.Hour), time.Unix(0, 0))
	if err != nil {
		t.Fatalf("Downsample: %v", err)
	}
	if stats.RawRowsAggregated != 0 {
		t.Errorf("expected no rows aggregated, got %+v", stats)
	}
	raw, err := s.Query(ctx, "m", now.Add(-time.Minute), now.Add(time.Minute), nil, ResolutionRaw)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 1 {
		t.Errorf("expected the recent raw point to survive, got %+v", raw)
	}
}

func TestDownsample_HourlyToDailyChaining(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	dayStart := time.Unix(1_700_000_000/86400*86400, 0).UTC()

	if err := s.WritePoints(ctx, []Point{
		{Metric: "cpu_pct", Timestamp: dayStart.Add(1 * time.Hour), Value: 10},
		{Metric: "cpu_pct", Timestamp: dayStart.Add(13 * time.Hour), Value: 30},
	}); err != nil {
		t.Fatal(err)
	}

	// First pass: raw -> hourly (cutoff far in the future so both raw points qualify).
	rawCutoff := dayStart.Add(48 * time.Hour)
	if _, err := s.Downsample(ctx, rawCutoff, time.Unix(0, 0)); err != nil {
		t.Fatalf("Downsample (raw->hourly): %v", err)
	}

	// Second pass: hourly -> daily.
	hourlyCutoff := dayStart.Add(48 * time.Hour)
	stats, err := s.Downsample(ctx, time.Unix(0, 0), hourlyCutoff)
	if err != nil {
		t.Fatalf("Downsample (hourly->daily): %v", err)
	}
	if stats.HourlyRowsAggregated != 2 || stats.DailyRowsCreated != 1 {
		t.Errorf("unexpected stats: %+v", stats)
	}

	daily, err := s.Query(ctx, "cpu_pct", dayStart.Add(-time.Hour), dayStart.Add(24*time.Hour), nil, ResolutionDaily)
	if err != nil {
		t.Fatal(err)
	}
	if len(daily) != 1 || daily[0].Value != 20 { // average of 10 and 30
		t.Errorf("unexpected daily point: %+v", daily)
	}
}

func TestDownsample_PreservesLabelsAcrossConsolidation(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	hourStart := time.Unix(1_700_000_000/3600*3600, 0).UTC()

	if err := s.WritePoints(ctx, []Point{
		{Metric: "net_bytes", Timestamp: hourStart.Add(time.Minute), Value: 100, Labels: map[string]string{"iface": "eth0"}},
		{Metric: "net_bytes", Timestamp: hourStart.Add(time.Minute), Value: 500, Labels: map[string]string{"iface": "eth1"}},
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := s.Downsample(ctx, hourStart.Add(2*time.Hour), time.Unix(0, 0)); err != nil {
		t.Fatalf("Downsample: %v", err)
	}

	eth0, err := s.Query(ctx, "net_bytes", hourStart.Add(-time.Hour), hourStart.Add(time.Hour),
		map[string]string{"iface": "eth0"}, ResolutionHourly)
	if err != nil {
		t.Fatal(err)
	}
	if len(eth0) != 1 || eth0[0].Value != 100 {
		t.Errorf("expected eth0 series preserved separately, got %+v", eth0)
	}

	eth1, err := s.Query(ctx, "net_bytes", hourStart.Add(-time.Hour), hourStart.Add(time.Hour),
		map[string]string{"iface": "eth1"}, ResolutionHourly)
	if err != nil {
		t.Fatal(err)
	}
	if len(eth1) != 1 || eth1[0].Value != 500 {
		t.Errorf("expected eth1 series preserved separately, got %+v", eth1)
	}
}

func TestOpenSQLite_CreatesParentDirectory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "dir", "test.db")
	s, err := OpenSQLite(path)
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	defer s.Close()
}
