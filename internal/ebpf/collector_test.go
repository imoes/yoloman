package ebpf

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"testing"
)

// encodeEvent round-trips a collectorEvent through binary.LittleEndian,
// exactly mirroring how a real ring buffer record's raw bytes would be laid
// out — this lets handleRecord be tested without loading real eBPF programs
// (which needs root/CAP_BPF, unavailable in this sandbox).
func encodeEvent(t *testing.T, ev collectorEvent) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, ev); err != nil {
		t.Fatalf("encoding test event: %v", err)
	}
	return buf.Bytes()
}

func rawIPv4(ip string) uint32 {
	addr := net.ParseIP(ip).To4()
	return binary.LittleEndian.Uint32(addr)
}

func setComm(dst *[16]uint8, name string) {
	copy(dst[:], name)
}

func setFilename(dst *[128]uint8, name string) {
	copy(dst[:], name)
}

func TestHandleRecord_TCPConnEvent(t *testing.T) {
	c := &Collector{maxEvents: 100}
	ev := collectorEvent{
		Type:     eventTypeTCPConn,
		Pid:      1234,
		Saddr:    rawIPv4("192.0.2.48"),
		Daddr:    rawIPv4("142.250.1.1"),
		Sport:    54321,
		Dport:    443,
		Oldstate: 2, // SYN_SENT
		Newstate: 1, // ESTABLISHED
	}
	setComm(&ev.Comm, "curl")

	c.handleRecord(context.Background(), encodeEvent(t, ev))

	conns := c.RecentConns(0)
	if len(conns) != 1 {
		t.Fatalf("expected 1 conn event, got %d", len(conns))
	}
	got := conns[0]
	if got.PID != 1234 || got.Comm != "curl" {
		t.Errorf("unexpected pid/comm: %+v", got)
	}
	if got.SrcAddr != "192.0.2.48" {
		t.Errorf("SrcAddr = %v, want 192.0.2.48", got.SrcAddr)
	}
	if got.DstAddr != "142.250.1.1" {
		t.Errorf("DstAddr = %v, want 142.250.1.1", got.DstAddr)
	}
	if got.SrcPort != 54321 || got.DstPort != 443 {
		t.Errorf("unexpected ports: src=%d dst=%d", got.SrcPort, got.DstPort)
	}
	if got.OldState != "SYN_SENT" || got.NewState != "ESTABLISHED" {
		t.Errorf("unexpected states: old=%q new=%q", got.OldState, got.NewState)
	}
}

func TestHandleRecord_ExecEvent(t *testing.T) {
	c := &Collector{maxEvents: 100}
	ev := collectorEvent{
		Type: eventTypeExec,
		Pid:  5678,
	}
	setComm(&ev.Comm, "sh")
	setFilename(&ev.Filename, "/usr/bin/sh")

	c.handleRecord(context.Background(), encodeEvent(t, ev))

	execs := c.RecentExecs(0)
	if len(execs) != 1 {
		t.Fatalf("expected 1 exec event, got %d", len(execs))
	}
	got := execs[0]
	if got.PID != 5678 || got.Comm != "sh" || got.Filename != "/usr/bin/sh" {
		t.Errorf("unexpected exec event: %+v", got)
	}
}

func TestHandleRecord_DiskIOEvent(t *testing.T) {
	c := &Collector{maxEvents: 100}
	ev := collectorEvent{
		Type:          eventTypeDiskIO,
		DiskDev:       0x800010, // major 8, minor 16 (e.g. /dev/sdb)
		DiskSector:    123456,
		DiskNrSector:  8,
		DiskLatencyNs: 2_500_000, // 2.5ms
		DiskError:     0,
	}
	setComm(&ev.Comm, "postgres")
	copy(ev.DiskRwbs[:], "W")

	c.handleRecord(context.Background(), encodeEvent(t, ev))

	disks := c.RecentDiskIO(0)
	if len(disks) != 1 {
		t.Fatalf("expected 1 disk IO event, got %d", len(disks))
	}
	got := disks[0]
	if got.Comm != "postgres" {
		t.Errorf("Comm = %q, want postgres", got.Comm)
	}
	if got.Dev != 0x800010 {
		t.Errorf("Dev = %#x, want 0x800010", got.Dev)
	}
	if got.Sector != 123456 || got.NrSector != 8 {
		t.Errorf("unexpected sector/nr_sector: %+v", got)
	}
	if got.Latency != 2_500_000 {
		t.Errorf("Latency = %v, want 2500000ns", got.Latency)
	}
	if got.RWBS != "W" {
		t.Errorf("RWBS = %q, want W", got.RWBS)
	}
	if got.Error != 0 {
		t.Errorf("Error = %d, want 0", got.Error)
	}
}

func TestCollector_RecentDiskIO_BoundedByMaxEvents(t *testing.T) {
	c := &Collector{maxEvents: 3}
	for i := 0; i < 5; i++ {
		ev := collectorEvent{Type: eventTypeDiskIO, DiskSector: uint64(i)}
		c.handleRecord(context.Background(), encodeEvent(t, ev))
	}
	disks := c.RecentDiskIO(0)
	if len(disks) != 3 {
		t.Fatalf("expected buffer bounded to 3, got %d", len(disks))
	}
	if disks[0].Sector != 2 || disks[2].Sector != 4 {
		t.Errorf("unexpected retained events: %+v", disks)
	}
}

func TestCollector_SlowestDiskIO(t *testing.T) {
	c := &Collector{maxEvents: 100}
	latencies := []uint64{1_000_000, 50_000_000, 500_000, 10_000_000}
	for _, ns := range latencies {
		ev := collectorEvent{Type: eventTypeDiskIO, DiskLatencyNs: ns}
		c.handleRecord(context.Background(), encodeEvent(t, ev))
	}
	slowest := c.SlowestDiskIO(2)
	if len(slowest) != 2 {
		t.Fatalf("expected 2 slowest events, got %d", len(slowest))
	}
	if slowest[0].Latency != 50_000_000 || slowest[1].Latency != 10_000_000 {
		t.Errorf("expected descending latency order [50ms, 10ms], got %+v", slowest)
	}
}

func TestHandleRecord_UnknownTypeIgnored(t *testing.T) {
	c := &Collector{maxEvents: 100}
	ev := collectorEvent{Type: 99}
	c.handleRecord(context.Background(), encodeEvent(t, ev))
	if len(c.RecentConns(0)) != 0 || len(c.RecentExecs(0)) != 0 || len(c.RecentDiskIO(0)) != 0 {
		t.Error("expected unknown event type to be ignored")
	}
}

func TestTCPStateName_KnownAndUnknown(t *testing.T) {
	if tcpStateName(1) != "ESTABLISHED" {
		t.Errorf("state 1 = %q, want ESTABLISHED", tcpStateName(1))
	}
	if tcpStateName(255) != "UNKNOWN(255)" {
		t.Errorf("state 255 = %q, want UNKNOWN(255)", tcpStateName(255))
	}
}

func TestCommToString_TrimsNulPadding(t *testing.T) {
	buf := make([]byte, 16)
	copy(buf, "nginx")
	if got := commToString(buf); got != "nginx" {
		t.Errorf("commToString = %q, want nginx", got)
	}
}

func TestIPFromRaw_RoundTrips(t *testing.T) {
	want := "192.168.1.42"
	ip := ipFromRaw(rawIPv4(want))
	if ip != want {
		t.Errorf("ipFromRaw round-trip = %v, want %v", ip, want)
	}
}

func TestCollector_RecentConns_BoundedByMaxEvents(t *testing.T) {
	c := &Collector{maxEvents: 3}
	for i := 0; i < 5; i++ {
		ev := collectorEvent{Type: eventTypeTCPConn, Pid: uint32(i)}
		c.handleRecord(context.Background(), encodeEvent(t, ev))
	}
	conns := c.RecentConns(0)
	if len(conns) != 3 {
		t.Fatalf("expected buffer bounded to 3, got %d", len(conns))
	}
	// Should keep the 3 most recent: pids 2, 3, 4.
	if conns[0].PID != 2 || conns[2].PID != 4 {
		t.Errorf("unexpected retained events: %+v", conns)
	}
}

func TestCollector_RecentConns_Limit(t *testing.T) {
	c := &Collector{maxEvents: 100}
	for i := 0; i < 10; i++ {
		ev := collectorEvent{Type: eventTypeTCPConn, Pid: uint32(i)}
		c.handleRecord(context.Background(), encodeEvent(t, ev))
	}
	conns := c.RecentConns(3)
	if len(conns) != 3 {
		t.Fatalf("expected 3 events with limit=3, got %d", len(conns))
	}
	if conns[2].PID != 9 {
		t.Errorf("expected the newest event last, got %+v", conns)
	}
}

func TestCollector_TopTalkers(t *testing.T) {
	c := &Collector{maxEvents: 100}
	add := func(comm, dst string, port uint16, newstate uint8) {
		ev := collectorEvent{
			Type: eventTypeTCPConn, Daddr: rawIPv4(dst), Dport: port, Newstate: newstate,
		}
		setComm(&ev.Comm, comm)
		c.handleRecord(context.Background(), encodeEvent(t, ev))
	}
	add("curl", "1.1.1.1", 443, 1) // ESTABLISHED
	add("curl", "1.1.1.1", 443, 1) // ESTABLISHED again -> count 2
	add("curl", "1.1.1.1", 443, 6) // TIME_WAIT -> should not count
	add("nginx", "2.2.2.2", 80, 1) // ESTABLISHED

	top := c.TopTalkers(0)
	if len(top) != 2 {
		t.Fatalf("expected 2 distinct talkers, got %d: %+v", len(top), top)
	}
	if top[0].Comm != "curl" || top[0].Count != 2 {
		t.Errorf("expected curl to be the top talker with count 2, got %+v", top[0])
	}
}

func TestCollector_TopTalkers_LimitN(t *testing.T) {
	c := &Collector{maxEvents: 100}
	for i := 0; i < 5; i++ {
		ev := collectorEvent{Type: eventTypeTCPConn, Dport: uint16(1000 + i), Newstate: 1}
		setComm(&ev.Comm, "svc")
		c.handleRecord(context.Background(), encodeEvent(t, ev))
	}
	top := c.TopTalkers(2)
	if len(top) != 2 {
		t.Fatalf("expected top talkers limited to 2, got %d", len(top))
	}
}
