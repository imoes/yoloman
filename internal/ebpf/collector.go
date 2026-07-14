// Package ebpf collects TCP connection lifecycle transitions, process exec
// events, and disk I/O latency via four stable kernel tracepoints
// (sock:inet_sock_set_state, sched:sched_process_exec, block:block_rq_issue,
// block:block_rq_complete), CO-RE-free since all four are part of the
// kernel's stable tracepoint ABI (see bpf/collector.c). Requires a kernel
// with BPF ring buffer support (>= 5.8) and CAP_BPF/CAP_PERFMON (or root).
package ebpf

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/cilium/ebpf/rlimit"
)

const (
	eventTypeTCPConn uint32 = 1
	eventTypeExec    uint32 = 2
	eventTypeDiskIO  uint32 = 3
)

// tcpStateNames maps Linux's net/tcp_states.h enum values to their names.
var tcpStateNames = map[uint8]string{
	1: "ESTABLISHED", 2: "SYN_SENT", 3: "SYN_RECV", 4: "FIN_WAIT1",
	5: "FIN_WAIT2", 6: "TIME_WAIT", 7: "CLOSE", 8: "CLOSE_WAIT",
	9: "LAST_ACK", 10: "LISTEN", 11: "CLOSING", 12: "NEW_SYN_RECV",
}

func tcpStateName(s uint8) string {
	if name, ok := tcpStateNames[s]; ok {
		return name
	}
	return fmt.Sprintf("UNKNOWN(%d)", s)
}

// TCPConnEvent is one observed TCP socket state transition (covers both
// outbound connect() completions and inbound accept() completions, since
// both surface as a transition to ESTABLISHED on this tracepoint).
//
// Addresses are plain dotted-decimal strings rather than net.IP: net.IP
// marshals to JSON as a string (via MarshalText), but its underlying Go
// type is []byte, which JSON Schema inference reads as an array — a real
// schema/runtime mismatch that a strict MCP client (the Inspector CLI)
// caught during verification. Plain strings sidestep it entirely and are
// simpler for any client to consume.
type TCPConnEvent struct {
	Timestamp   time.Time `json:"timestamp"`
	PID         uint32    `json:"pid"`
	Comm        string    `json:"comm"`
	SrcAddr     string    `json:"src_addr"`
	DstAddr     string    `json:"dst_addr"`
	SrcPort     uint16    `json:"src_port"`
	DstPort     uint16    `json:"dst_port"`
	OldState    string    `json:"old_state"`
	NewState    string    `json:"new_state"`
	ContainerID string    `json:"container_id,omitempty"`
}

// ExecEvent is one observed process exec.
type ExecEvent struct {
	Timestamp   time.Time `json:"timestamp"`
	PID         uint32    `json:"pid"`
	Comm        string    `json:"comm"`
	Filename    string    `json:"filename"`
	ContainerID string    `json:"container_id,omitempty"`
}

// DiskIOEvent is one completed block I/O request's latency, emitted once —
// at completion — after the eBPF program correlates it with its earlier
// block_rq_issue by (device, sector). Dev is the raw kernel dev_t; decode
// with DevMajor/DevMinor if needed (major = dev>>20, minor = dev&0xFFFFF,
// matching how the kernel's own trace print format decodes it). RWBS is
// the raw blktrace flag string (e.g. "R", "WS", "RA" — see the kernel's
// blk_fill_rwbs()); exposed as-is rather than parsed further, the same way
// TCPConnEvent exposes raw tcp state names instead of a derived boolean.
type DiskIOEvent struct {
	Timestamp   time.Time     `json:"timestamp"`
	PID         uint32        `json:"pid"`
	Comm        string        `json:"comm"`
	Dev         uint32        `json:"dev"`
	Sector      uint64        `json:"sector"`
	NrSector    uint32        `json:"nr_sector"`
	Latency     time.Duration `json:"latency_ns"`
	RWBS        string        `json:"rwbs"`
	Error       int32         `json:"error"`
	ContainerID string        `json:"container_id,omitempty"`
}

// EdgeSink receives observed connection edges for durable persistence — an
// optional dependency (nil is a fully valid, working Collector, matching
// every other dependency's graceful-degradation pattern in this project)
// so this package doesn't need to import internal/store directly. Every
// method of internal/store.Store already has this exact signature, so a
// *store.SQLiteStore satisfies EdgeSink with no adapter needed.
type EdgeSink interface {
	UpsertEdge(ctx context.Context, comm, dstAddr string, dstPort uint16, latencyNs *int64) error
}

// Collector loads the eBPF programs, attaches them to their tracepoints,
// and consumes the shared ring buffer into bounded in-memory event lists.
type Collector struct {
	objs   collectorObjects
	links  []link.Link
	reader *ringbuf.Reader

	mu        sync.Mutex
	conns     []TCPConnEvent
	execs     []ExecEvent
	disks     []DiskIOEvent
	maxEvents int

	// Per-interval latency histograms (Coroot-style heatmap source): counts of
	// events falling in each LatencyBucketsMs bucket since the last Snapshot.
	// len == len(LatencyBucketsMs)+1 (last is the +Inf overflow bucket).
	connLatHist []uint64
	diskLatHist []uint64

	edgeSink EdgeSink
}

// LatencyBucketsMs are the upper bounds (le, in ms) of the latency histogram
// buckets. Both signals we bucket — outbound TCP connect latency (LAN/loopback
// is routinely sub-millisecond) and block-I/O service time (mostly ≤1ms with a
// tail) — pile almost everything into a single ≥1ms bucket on a coarse ladder,
// making the heatmap a solid block. The low end is therefore sub-millisecond so
// the distribution actually spreads across rows; the high end still reaches 5s.
var LatencyBucketsMs = []float64{0.1, 0.25, 0.5, 1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000}

// latencyBucket returns the index of the first bucket whose upper bound is
// >= ms, or the overflow bucket (len(LatencyBucketsMs)) for anything larger.
func latencyBucket(ms float64) int {
	for i, le := range LatencyBucketsMs {
		if ms <= le {
			return i
		}
	}
	return len(LatencyBucketsMs)
}

// SnapshotLatencyHistograms returns the per-bucket event counts accumulated
// since the previous call and resets them — {le-label: count}, with the
// overflow bucket keyed "+Inf". Called once per metric-sampling tick.
func (c *Collector) SnapshotLatencyHistograms() (conn, disk map[string]uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	conn = histToMap(c.connLatHist)
	disk = histToMap(c.diskLatHist)
	c.connLatHist = make([]uint64, len(LatencyBucketsMs)+1)
	c.diskLatHist = make([]uint64, len(LatencyBucketsMs)+1)
	return conn, disk
}

func histToMap(h []uint64) map[string]uint64 {
	out := make(map[string]uint64, len(h))
	for i, n := range h {
		le := "+Inf"
		if i < len(LatencyBucketsMs) {
			le = strconv.FormatFloat(LatencyBucketsMs[i], 'g', -1, 64)
		}
		out[le] = n
	}
	return out
}

// recordLatency adds one observation (ms) to a histogram; caller holds c.mu.
func (c *Collector) recordLatency(hist *[]uint64, ms float64) {
	if *hist == nil {
		*hist = make([]uint64, len(LatencyBucketsMs)+1)
	}
	(*hist)[latencyBucket(ms)]++
}

// SetEdgeSink wires an optional destination for durable connection-edge
// persistence (see EdgeSink and docs/plan.md's Bossman "v3" Block A) — call
// before Run. Leaving it unset (the default) keeps this package's pre-v3
// behavior: edges only live in the bounded in-memory window.
func (c *Collector) SetEdgeSink(sink EdgeSink) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.edgeSink = sink
}

func (c *Collector) getEdgeSink() EdgeSink {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.edgeSink
}

// New loads and attaches the collector. Callers should treat any error as
// "eBPF unsupported on this host" and continue running without it (see
// docs/plan.md's graceful-degradation requirement) rather than failing the
// whole daemon.
func New(maxEvents int) (*Collector, error) {
	if maxEvents <= 0 {
		maxEvents = 1000
	}

	if err := rlimit.RemoveMemlock(); err != nil {
		return nil, fmt.Errorf("removing memlock rlimit: %w", err)
	}

	var objs collectorObjects
	if err := loadCollectorObjects(&objs, nil); err != nil {
		return nil, fmt.Errorf("loading eBPF objects: %w", err)
	}

	tcpLink, err := link.Tracepoint("sock", "inet_sock_set_state", objs.TraceInetSockSetState, nil)
	if err != nil {
		objs.Close()
		return nil, fmt.Errorf("attaching sock:inet_sock_set_state: %w", err)
	}

	execLink, err := link.Tracepoint("sched", "sched_process_exec", objs.TraceSchedProcessExec, nil)
	if err != nil {
		tcpLink.Close()
		objs.Close()
		return nil, fmt.Errorf("attaching sched:sched_process_exec: %w", err)
	}

	blockIssueLink, err := link.Tracepoint("block", "block_rq_issue", objs.TraceBlockRqIssue, nil)
	if err != nil {
		execLink.Close()
		tcpLink.Close()
		objs.Close()
		return nil, fmt.Errorf("attaching block:block_rq_issue: %w", err)
	}

	blockCompleteLink, err := link.Tracepoint("block", "block_rq_complete", objs.TraceBlockRqComplete, nil)
	if err != nil {
		blockIssueLink.Close()
		execLink.Close()
		tcpLink.Close()
		objs.Close()
		return nil, fmt.Errorf("attaching block:block_rq_complete: %w", err)
	}

	reader, err := ringbuf.NewReader(objs.Events)
	if err != nil {
		blockCompleteLink.Close()
		blockIssueLink.Close()
		execLink.Close()
		tcpLink.Close()
		objs.Close()
		return nil, fmt.Errorf("opening ring buffer: %w", err)
	}

	return &Collector{
		objs:      objs,
		links:     []link.Link{tcpLink, execLink, blockIssueLink, blockCompleteLink},
		reader:    reader,
		maxEvents: maxEvents,
	}, nil
}

// Close detaches all programs and releases kernel resources.
func (c *Collector) Close() error {
	_ = c.reader.Close()
	for _, l := range c.links {
		_ = l.Close()
	}
	return c.objs.Close()
}

// Run consumes ring buffer events until ctx is cancelled or the buffer is
// closed. Intended to be run in its own goroutine.
func (c *Collector) Run(ctx context.Context) {
	go func() {
		<-ctx.Done()
		_ = c.reader.Close()
	}()

	for {
		record, err := c.reader.Read()
		if err != nil {
			if errors.Is(err, ringbuf.ErrClosed) {
				return
			}
			slog.Warn("ebpf: ring buffer read error", "error", err)
			continue
		}
		c.handleRecord(ctx, record.RawSample)
	}
}

func (c *Collector) handleRecord(ctx context.Context, raw []byte) {
	var ev collectorEvent
	if err := binary.Read(bytes.NewReader(raw), binary.LittleEndian, &ev); err != nil {
		slog.Warn("ebpf: decoding event", "error", err)
		return
	}

	switch ev.Type {
	case eventTypeTCPConn:
		comm := commToString(ev.Comm[:])
		dstAddr := ipFromRaw(ev.Daddr)
		newState := tcpStateName(ev.Newstate)
		c.appendConn(TCPConnEvent{
			Timestamp:   time.Now(),
			PID:         ev.Pid,
			Comm:        comm,
			SrcAddr:     ipFromRaw(ev.Saddr),
			DstAddr:     dstAddr,
			SrcPort:     ev.Sport,
			DstPort:     ev.Dport,
			OldState:    tcpStateName(ev.Oldstate),
			NewState:    newState,
			ContainerID: containerIDForPID(ev.Pid),
		})
		// Persist the same ESTABLISHED-only aggregation TopTalkers already
		// computes in memory, so it survives restarts and is reachable via
		// ListEdgesSince's bulk-dump cursor (see docs/plan.md's Bossman "v3"
		// Block A) — best-effort: a nil sink (the default) just skips this.
		if newState == "ESTABLISHED" {
			if sink := c.getEdgeSink(); sink != nil {
				// conn_latency_ns is the SYN_SENT→ESTABLISHED connect latency,
				// set by the eBPF program only for outbound connects (0 for
				// inbound accepts, which have no connect timing) → pass nil then.
				var latencyNs *int64
				if ev.ConnLatencyNs > 0 {
					l := int64(ev.ConnLatencyNs)
					latencyNs = &l
					c.mu.Lock()
					c.recordLatency(&c.connLatHist, float64(ev.ConnLatencyNs)/1e6)
					c.mu.Unlock()
				}
				if err := sink.UpsertEdge(ctx, comm, dstAddr, ev.Dport, latencyNs); err != nil {
					slog.Warn("ebpf: persisting connection edge", "error", err)
				}
			}
		}
	case eventTypeExec:
		c.appendExec(ExecEvent{
			Timestamp:   time.Now(),
			PID:         ev.Pid,
			Comm:        commToString(ev.Comm[:]),
			Filename:    commToString(ev.Filename[:]),
			ContainerID: containerIDForPID(ev.Pid),
		})
	case eventTypeDiskIO:
		c.appendDisk(DiskIOEvent{
			Timestamp:   time.Now(),
			PID:         ev.Pid,
			Comm:        commToString(ev.Comm[:]),
			Dev:         ev.DiskDev,
			Sector:      ev.DiskSector,
			NrSector:    ev.DiskNrSector,
			Latency:     time.Duration(ev.DiskLatencyNs),
			RWBS:        commToString(ev.DiskRwbs[:]),
			Error:       ev.DiskError,
			ContainerID: containerIDForPID(ev.Pid),
		})
		c.mu.Lock()
		c.recordLatency(&c.diskLatHist, float64(ev.DiskLatencyNs)/1e6)
		c.mu.Unlock()
	}
}

// ipFromRaw reconstructs the original raw address bytes from a uint32 that
// was filled via a byte-for-byte memcpy on the (little-endian) BPF side and
// decoded here with binary.LittleEndian — using LittleEndian consistently
// on both ends round-trips the original bytes regardless of what numeric
// "endianness" they represent, which is what we want: the 4 raw address
// bytes as the kernel stored them, not a re-interpreted integer. Returns
// the dotted-decimal string form directly (see TCPConnEvent's doc comment
// for why not net.IP).
func ipFromRaw(v uint32) string {
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, v)
	return net.IP(buf).String()
}

// commToString trims a NUL-terminated/padded fixed-size C char array.
func commToString(b []byte) string {
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	return string(b)
}

func (c *Collector) appendConn(e TCPConnEvent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.conns = append(c.conns, e)
	if len(c.conns) > c.maxEvents {
		c.conns = c.conns[len(c.conns)-c.maxEvents:]
	}
}

func (c *Collector) appendExec(e ExecEvent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.execs = append(c.execs, e)
	if len(c.execs) > c.maxEvents {
		c.execs = c.execs[len(c.execs)-c.maxEvents:]
	}
}

func (c *Collector) appendDisk(e DiskIOEvent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.disks = append(c.disks, e)
	if len(c.disks) > c.maxEvents {
		c.disks = c.disks[len(c.disks)-c.maxEvents:]
	}
}

// RecentConns returns up to limit of the most recently observed TCP state
// transitions (newest last). limit <= 0 means "all retained".
func (c *Collector) RecentConns(limit int) []TCPConnEvent {
	c.mu.Lock()
	defer c.mu.Unlock()
	return lastN(c.conns, limit)
}

// RecentExecs returns up to limit of the most recently observed exec
// events (newest last). limit <= 0 means "all retained".
func (c *Collector) RecentExecs(limit int) []ExecEvent {
	c.mu.Lock()
	defer c.mu.Unlock()
	return lastN(c.execs, limit)
}

// RecentDiskIO returns up to limit of the most recently completed disk I/O
// requests (newest last). limit <= 0 means "all retained".
func (c *Collector) RecentDiskIO(limit int) []DiskIOEvent {
	c.mu.Lock()
	defer c.mu.Unlock()
	return lastN(c.disks, limit)
}

// SlowestDiskIO returns the n disk I/O requests with the highest latency
// from the retained window, descending.
func (c *Collector) SlowestDiskIO(n int) []DiskIOEvent {
	c.mu.Lock()
	out := append([]DiskIOEvent(nil), c.disks...)
	c.mu.Unlock()

	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].Latency > out[j-1].Latency; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	if n > 0 && len(out) > n {
		out = out[:n]
	}
	return out
}

// TopTalker summarizes one (process, remote address) pair's observed
// connection-establishment count.
type TopTalker struct {
	Comm    string `json:"comm"`
	DstAddr string `json:"dst_addr"`
	DstPort uint16 `json:"dst_port"`
	Count   int    `json:"count"`
}

// TopTalkers aggregates ESTABLISHED transitions from the retained window
// by (comm, destination), returning the top N by count descending.
func (c *Collector) TopTalkers(n int) []TopTalker {
	c.mu.Lock()
	conns := append([]TCPConnEvent(nil), c.conns...)
	c.mu.Unlock()

	type key struct {
		comm string
		dst  string
		port uint16
	}
	counts := map[key]*TopTalker{}
	var order []key
	for _, e := range conns {
		if e.NewState != "ESTABLISHED" {
			continue
		}
		k := key{comm: e.Comm, dst: e.DstAddr, port: e.DstPort}
		t, ok := counts[k]
		if !ok {
			t = &TopTalker{Comm: e.Comm, DstAddr: e.DstAddr, DstPort: e.DstPort}
			counts[k] = t
			order = append(order, k)
		}
		t.Count++
	}

	out := make([]TopTalker, 0, len(order))
	for _, k := range order {
		out = append(out, *counts[k])
	}
	sortTopTalkersDesc(out)
	if n > 0 && len(out) > n {
		out = out[:n]
	}
	return out
}

func sortTopTalkersDesc(t []TopTalker) {
	for i := 1; i < len(t); i++ {
		for j := i; j > 0 && t[j].Count > t[j-1].Count; j-- {
			t[j], t[j-1] = t[j-1], t[j]
		}
	}
}

func lastN[T any](s []T, limit int) []T {
	if limit <= 0 || limit >= len(s) {
		out := make([]T, len(s))
		copy(out, s)
		return out
	}
	out := make([]T, limit)
	copy(out, s[len(s)-limit:])
	return out
}
