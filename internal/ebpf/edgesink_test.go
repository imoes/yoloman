package ebpf

import (
	"context"
	"testing"
)

// fakeEdgeSink is a minimal EdgeSink recording every call, for testing the
// collector's wiring without a real store.Store.
type fakeEdgeSink struct {
	calls []fakeEdgeSinkCall
}

type fakeEdgeSinkCall struct {
	comm      string
	dstAddr   string
	dstPort   uint16
	latencyNs *int64
}

func (f *fakeEdgeSink) UpsertEdge(ctx context.Context, comm, dstAddr string, dstPort uint16, latencyNs *int64) error {
	f.calls = append(f.calls, fakeEdgeSinkCall{comm: comm, dstAddr: dstAddr, dstPort: dstPort, latencyNs: latencyNs})
	return nil
}

func TestHandleRecord_EstablishedConnUpsertsEdge(t *testing.T) {
	sink := &fakeEdgeSink{}
	c := &Collector{maxEvents: 100}
	c.SetEdgeSink(sink)

	ev := collectorEvent{
		Type: eventTypeTCPConn, Daddr: rawIPv4("1.1.1.1"), Dport: 443, Newstate: 1, // ESTABLISHED
	}
	setComm(&ev.Comm, "curl")
	c.handleRecord(context.Background(), encodeEvent(t, ev))

	if len(sink.calls) != 1 {
		t.Fatalf("expected 1 UpsertEdge call, got %d", len(sink.calls))
	}
	got := sink.calls[0]
	if got.comm != "curl" || got.dstAddr != "1.1.1.1" || got.dstPort != 443 {
		t.Errorf("unexpected upserted edge: %+v", got)
	}
}

func TestHandleRecord_NonEstablishedDoesNotUpsertEdge(t *testing.T) {
	sink := &fakeEdgeSink{}
	c := &Collector{maxEvents: 100}
	c.SetEdgeSink(sink)

	ev := collectorEvent{
		Type: eventTypeTCPConn, Daddr: rawIPv4("1.1.1.1"), Dport: 443, Newstate: 6, // TIME_WAIT
	}
	setComm(&ev.Comm, "curl")
	c.handleRecord(context.Background(), encodeEvent(t, ev))

	if len(sink.calls) != 0 {
		t.Errorf("expected no UpsertEdge call for a non-ESTABLISHED transition, got %d", len(sink.calls))
	}
}

func TestHandleRecord_NilEdgeSinkIsSafe(t *testing.T) {
	c := &Collector{maxEvents: 100} // no SetEdgeSink call — nil sink, the default
	ev := collectorEvent{Type: eventTypeTCPConn, Newstate: 1}
	setComm(&ev.Comm, "curl")

	// Must not panic.
	c.handleRecord(context.Background(), encodeEvent(t, ev))

	if len(c.RecentConns(0)) != 1 {
		t.Error("expected the in-memory event to still be recorded without an edge sink")
	}
}

func TestHandleRecord_ExecAndDiskIODoNotUpsertEdges(t *testing.T) {
	sink := &fakeEdgeSink{}
	c := &Collector{maxEvents: 100}
	c.SetEdgeSink(sink)

	execEv := collectorEvent{Type: eventTypeExec}
	c.handleRecord(context.Background(), encodeEvent(t, execEv))

	diskEv := collectorEvent{Type: eventTypeDiskIO}
	c.handleRecord(context.Background(), encodeEvent(t, diskEv))

	if len(sink.calls) != 0 {
		t.Errorf("expected exec/disk-io events to never call UpsertEdge, got %d calls", len(sink.calls))
	}
}
