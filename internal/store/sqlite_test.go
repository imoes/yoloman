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

func TestListMetricNames(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	now := time.Now()

	if err := s.WritePoints(ctx, []Point{
		{Metric: "cpu_pct", Timestamp: now, Value: 1},
		{Metric: "mem_pct", Timestamp: now, Value: 2},
		{Metric: "cpu_pct", Timestamp: now.Add(time.Second), Value: 3},
	}); err != nil {
		t.Fatal(err)
	}

	names, err := s.ListMetricNames(ctx)
	if err != nil {
		t.Fatalf("ListMetricNames: %v", err)
	}
	if len(names) != 2 || names[0] != "cpu_pct" || names[1] != "mem_pct" {
		t.Errorf("names = %v, want [cpu_pct mem_pct]", names)
	}
}

func TestListMetricNames_Empty(t *testing.T) {
	s := openTestStore(t)
	names, err := s.ListMetricNames(context.Background())
	if err != nil {
		t.Fatalf("ListMetricNames: %v", err)
	}
	if len(names) != 0 {
		t.Errorf("expected no names in an empty store, got %v", names)
	}
}

func TestUpsertEdge_FirstSightCreatesRowWithCountOne(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatalf("UpsertEdge: %v", err)
	}

	edges, err := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if err != nil {
		t.Fatalf("ListEdgesSince: %v", err)
	}
	if len(edges) != 1 {
		t.Fatalf("expected 1 edge, got %d", len(edges))
	}
	e := edges[0]
	if e.Comm != "curl" || e.DstAddr != "1.1.1.1" || e.DstPort != 443 {
		t.Errorf("unexpected edge identity: %+v", e)
	}
	if e.EventCount != 1 {
		t.Errorf("EventCount = %d, want 1", e.EventCount)
	}
	if e.LatencyNs != nil {
		t.Errorf("LatencyNs = %v, want nil", e.LatencyNs)
	}
}

func TestUpsertEdge_RepeatSightIncrementsCountAndAdvancesLastSeen(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}
	firstEdges, err := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	firstSeen := firstEdges[0].FirstSeen

	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}

	edges, err := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(edges) != 1 {
		t.Fatalf("expected the same (comm,dst,port) to stay a single row, got %d", len(edges))
	}
	if edges[0].EventCount != 3 {
		t.Errorf("EventCount = %d, want 3 after 3 upserts", edges[0].EventCount)
	}
	if !edges[0].FirstSeen.Equal(firstSeen) {
		t.Errorf("FirstSeen changed across repeat upserts: %v -> %v", firstSeen, edges[0].FirstSeen)
	}
}

func TestUpsertEdge_DistinctDestinationsAreSeparateRows(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertEdge(ctx, "curl", "2.2.2.2", 443, nil); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertEdge(ctx, "nginx", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}

	edges, err := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(edges) != 3 {
		t.Fatalf("expected 3 distinct edges, got %d", len(edges))
	}
}

func TestUpsertEdge_LatencyUpdatesOnNonNilObservationOnly(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	firstLatency := int64(5_000_000)
	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, &firstLatency); err != nil {
		t.Fatal(err)
	}
	// A subsequent upsert with no latency observation must not clear the
	// existing value.
	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}
	edges, err := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if edges[0].LatencyNs == nil || *edges[0].LatencyNs != firstLatency {
		t.Errorf("LatencyNs = %v, want %d preserved across a nil-latency upsert", edges[0].LatencyNs, firstLatency)
	}

	secondLatency := int64(9_000_000)
	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, &secondLatency); err != nil {
		t.Fatal(err)
	}
	edges, err = s.ListEdgesSince(ctx, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if edges[0].LatencyNs == nil || *edges[0].LatencyNs != secondLatency {
		t.Errorf("LatencyNs = %v, want updated to %d", edges[0].LatencyNs, secondLatency)
	}
}

func TestListEdgesSince_FiltersOutOlderEdges(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}

	future := time.Now().Add(time.Hour)
	edges, err := s.ListEdgesSince(ctx, future)
	if err != nil {
		t.Fatal(err)
	}
	if len(edges) != 0 {
		t.Errorf("expected no edges last seen after a future cursor, got %d", len(edges))
	}
}

func TestDownsample_PrunesOldEdges(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}

	// The edge's last_seen is "now"; a cutoff in the future should prune it.
	stats, err := s.Downsample(ctx, time.Now().Add(time.Hour), time.Now().Add(time.Hour))
	if err != nil {
		t.Fatalf("Downsample: %v", err)
	}
	if stats.EdgesPruned != 1 {
		t.Errorf("EdgesPruned = %d, want 1", stats.EdgesPruned)
	}

	edges, err := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(edges) != 0 {
		t.Errorf("expected the pruned edge to be gone, got %d remaining", len(edges))
	}
}

func TestDownsample_DoesNotPruneRecentEdges(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	if err := s.UpsertEdge(ctx, "curl", "1.1.1.1", 443, nil); err != nil {
		t.Fatal(err)
	}

	stats, err := s.Downsample(ctx, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatalf("Downsample: %v", err)
	}
	if stats.EdgesPruned != 0 {
		t.Errorf("EdgesPruned = %d, want 0 for a recently-seen edge", stats.EdgesPruned)
	}
}

// THE CLIENT-PORT FOLD. Measured on the server side of this fleet before the same rule landed there:
// 73 235 rows / 84 MB, 96.7% of them one connection to a peer's random high port. The agent's store has the
// same shape and ships every row on each poll, so it folds too — on the retention cadence, not in the hot
// path.

func TestFoldClientPorts_ManyHighPortsAtOneAddressBecomeOneEdge(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	for i := 0; i < clientPortQuorum; i++ {
		if err := s.UpsertEdge(ctx, "kubelet", "127.0.0.1", uint16(40000+i), nil); err != nil {
			t.Fatal(err)
		}
	}

	// A cutoff in the past, so nothing is pruned and the fold is what changes the table.
	stats, err := s.Downsample(ctx, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatalf("Downsample: %v", err)
	}
	if stats.EdgesFolded != clientPortQuorum {
		t.Errorf("EdgesFolded = %d, want %d", stats.EdgesFolded, clientPortQuorum)
	}

	edges, err := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(edges) != 1 {
		t.Fatalf("want one folded edge, got %d", len(edges))
	}
	if edges[0].DstPort != 0 {
		t.Errorf("DstPort = %d, want the sentinel 0 (no socket listens on 0)", edges[0].DstPort)
	}
	if edges[0].EventCount != clientPortQuorum {
		t.Errorf("EventCount = %d, want %d — the traffic is what must survive the fold",
			edges[0].EventCount, clientPortQuorum)
	}
}

func TestFoldClientPorts_AFewHighPortsAreLeftAlone(t *testing.T) {
	// mysqlx on 33060 and a gRPC service on 50051 are real services above the floor. Below the quorum
	// nothing proves a port belongs to a client, so nothing may be folded.
	s := openTestStore(t)
	ctx := context.Background()

	for _, p := range []uint16{33060, 50051} {
		if err := s.UpsertEdge(ctx, "app", "10.0.0.5", p, nil); err != nil {
			t.Fatal(err)
		}
	}
	stats, err := s.Downsample(ctx, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if stats.EdgesFolded != 0 {
		t.Errorf("EdgesFolded = %d, want 0 — two high ports prove nothing", stats.EdgesFolded)
	}
}

func TestFoldClientPorts_ServicePortsAreNeverFolded(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	for i := 0; i < clientPortQuorum*2; i++ {
		if err := s.UpsertEdge(ctx, "haproxy", "10.0.0.9", uint16(8000+i), nil); err != nil {
			t.Fatal(err)
		}
	}
	stats, err := s.Downsample(ctx, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if stats.EdgesFolded != 0 {
		t.Errorf("EdgesFolded = %d, want 0 — every port is below the ephemeral floor", stats.EdgesFolded)
	}
	edges, _ := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if len(edges) != clientPortQuorum*2 {
		t.Errorf("got %d edges, want all %d kept", len(edges), clientPortQuorum*2)
	}
}

func TestFoldClientPorts_AServiceEdgeAtTheSameAddressSurvives(t *testing.T) {
	// kubelet talks to 127.0.0.1:6443 AND churns through client ports. The fold must not swallow the one
	// statement an operator actually reads.
	s := openTestStore(t)
	ctx := context.Background()

	if err := s.UpsertEdge(ctx, "kubelet", "127.0.0.1", 6443, nil); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		if err := s.UpsertEdge(ctx, "kubelet", "127.0.0.1", uint16(40000+i), nil); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Downsample(ctx, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	edges, _ := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if len(edges) != 2 {
		t.Fatalf("want the service edge plus one fold, got %d", len(edges))
	}
	ports := map[uint16]int64{}
	for _, e := range edges {
		ports[e.DstPort] = e.EventCount
	}
	if ports[6443] != 1 {
		t.Errorf("the service edge lost its count: %v", ports)
	}
	if ports[0] != 20 {
		t.Errorf("the fold's count = %d, want 20", ports[0])
	}
}

func TestFoldClientPorts_FoldingTwiceAccumulatesRatherThanDuplicates(t *testing.T) {
	// The pass runs every retention tick, and new client ports keep arriving between passes. The second
	// fold has to merge into the existing sentinel row, not fail on it or replace its history.
	s := openTestStore(t)
	ctx := context.Background()
	past := time.Now().Add(-time.Hour)

	for i := 0; i < clientPortQuorum; i++ {
		if err := s.UpsertEdge(ctx, "kubelet", "127.0.0.1", uint16(40000+i), nil); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Downsample(ctx, past, past); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < clientPortQuorum; i++ {
		if err := s.UpsertEdge(ctx, "kubelet", "127.0.0.1", uint16(50000+i), nil); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Downsample(ctx, past, past); err != nil {
		t.Fatal(err)
	}

	edges, _ := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if len(edges) != 1 {
		t.Fatalf("want one folded edge after two passes, got %d", len(edges))
	}
	if edges[0].EventCount != clientPortQuorum*2 {
		t.Errorf("EventCount = %d, want %d — both passes' traffic",
			edges[0].EventCount, clientPortQuorum*2)
	}
}

func TestFoldClientPorts_EachProcessAndAddressFoldsSeparately(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	for i := 0; i < clientPortQuorum; i++ {
		for _, c := range []struct{ comm, addr string }{
			{"kubelet", "127.0.0.1"}, {"kube-apiserver", "127.0.0.1"}, {"kubelet", "10.0.0.5"},
		} {
			if err := s.UpsertEdge(ctx, c.comm, c.addr, uint16(40000+i), nil); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, err := s.Downsample(ctx, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	edges, _ := s.ListEdgesSince(ctx, time.Unix(0, 0))
	if len(edges) != 3 {
		t.Fatalf("want one fold per (comm, addr), got %d", len(edges))
	}
	for _, e := range edges {
		if e.DstPort != 0 || e.EventCount != clientPortQuorum {
			t.Errorf("unexpected fold %+v", e)
		}
	}
}
