package ebpf

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// L7 protocol ids — mirror the L7_PROTO_* constants in bpf/l7.c.
const (
	l7ProtoHTTP     uint8 = 1
	l7ProtoPostgres uint8 = 2
	l7ProtoMySQL    uint8 = 5
	l7ProtoDNS      uint8 = 13
)

// L7Event is one captured request/response exchange (the rich, UI-facing form of
// a bpf/l7.c l7_event). Protocol-specific fields are populated as available;
// the raw payloads never leave this struct — only the classified Status /
// Destination become metric labels (cardinality discipline, see SnapshotL7).
type L7Event struct {
	Timestamp   time.Time `json:"timestamp"`
	PID         uint32    `json:"pid"`
	Comm        string    `json:"comm,omitempty"`
	Protocol    string    `json:"protocol"`         // http|dns|postgres|mysql
	Method      string    `json:"method,omitempty"` // HTTP method / DNS query type
	Target      string    `json:"target,omitempty"` // HTTP path / DNS name / SQL text
	Status      string    `json:"status"`           // 2xx|3xx|4xx|5xx / ok|nxdomain|servfail|…
	StatusCode  int32     `json:"status_code"`      // raw HTTP status / DNS rcode
	DurationMs  float64   `json:"duration_ms"`
	DstAddr     string    `json:"dst_addr,omitempty"`
	DstPort     uint16    `json:"dst_port,omitempty"`
	Answers     []string  `json:"answers,omitempty"` // DNS A/AAAA answers
	ContainerID string    `json:"container_id,omitempty"`
}

func protocolName(p uint8) string {
	switch p {
	case l7ProtoHTTP:
		return "http"
	case l7ProtoPostgres:
		return "postgres"
	case l7ProtoMySQL:
		return "mysql"
	case l7ProtoDNS:
		return "dns"
	default:
		return "unknown"
	}
}

// handleL7Record decodes one l7_event from the L7 ring buffer, enriches it into
// an L7Event, and folds it into both the recent-events window and the per-tick
// RED counters.
func (c *Collector) handleL7Record(raw []byte) {
	var ev collectorL7Event
	if err := binary.Read(bytes.NewReader(raw), binary.LittleEndian, &ev); err != nil {
		return
	}

	e := L7Event{
		Timestamp:   time.Now(),
		PID:         ev.Pid,
		Protocol:    protocolName(ev.Protocol),
		StatusCode:  ev.Status,
		DurationMs:  float64(ev.DurationNs) / 1e6,
		DstPort:     ev.Dport,
		ContainerID: containerIDForPID(ev.Pid),
	}
	if ev.Daddr != 0 {
		e.DstAddr = ipFromRaw(ev.Daddr)
	}

	req := ev.ReqPayload[:min(int(ev.ReqPayloadSize), len(ev.ReqPayload))]
	resp := ev.Payload[:min(int(ev.PayloadSize), len(ev.Payload))]

	switch ev.Protocol {
	case l7ProtoHTTP:
		method, path := parseHTTPRequestLine(req)
		e.Method, e.Target = method, path
		e.Status = httpStatusClass(ev.Status)
	case l7ProtoDNS:
		// The response echoes the question and carries the answers, so parsing
		// it alone yields name + type + answers.
		name, qtype, answers := parseDNS(resp)
		if name == "" { // fall back to the query if the response didn't parse
			name, qtype, _ = parseDNS(req)
		}
		e.Method, e.Target, e.Answers = qtype, name, answers
		e.Status = dnsStatus(ev.Status)
	case l7ProtoPostgres:
		e.Target = parsePostgresQuery(req)
		e.Status = sqlStatus(ev.Status)
	case l7ProtoMySQL:
		e.Target = parseMySQLQuery(req)
		e.Status = sqlStatus(ev.Status)
	default:
		e.Status = "ok"
	}

	c.appendL7(e)
}

func (c *Collector) appendL7(e L7Event) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.recentL7 = append(c.recentL7, e)
	if len(c.recentL7) > c.maxEvents {
		c.recentL7 = c.recentL7[len(c.recentL7)-c.maxEvents:]
	}
	dest := e.DstAddr
	if dest == "" {
		dest = "unknown"
	}
	dest = dest + ":" + strconv.Itoa(int(e.DstPort))
	if c.l7Reqs == nil {
		c.l7Reqs = map[string]uint64{}
		c.l7Lat = map[string][]uint64{}
	}
	c.l7Reqs[e.Protocol+"|"+e.Status+"|"+dest]++
	latKey := e.Protocol + "|" + dest
	h := c.l7Lat[latKey]
	if h == nil {
		h = make([]uint64, len(LatencyBucketsMs)+1)
	}
	h[latencyBucket(e.DurationMs)]++
	c.l7Lat[latKey] = h
}

// RecentL7 returns up to limit recent L7 exchanges (newest last), optionally
// filtered to one protocol ("" = all).
func (c *Collector) RecentL7(protocol string, limit int) []L7Event {
	c.mu.Lock()
	defer c.mu.Unlock()
	if protocol == "" {
		return lastN(c.recentL7, limit)
	}
	filtered := make([]L7Event, 0, len(c.recentL7))
	for _, e := range c.recentL7 {
		if e.Protocol == protocol {
			filtered = append(filtered, e)
		}
	}
	return lastN(filtered, limit)
}

// L7Sample is one snapshot row: a request count + latency histogram for a
// (protocol, status, destination) — the shape main.go turns into metric points.
type L7Sample struct {
	Protocol    string
	Status      string
	Destination string
	Count       uint64
}

// SnapshotL7Requests returns the per-(protocol,status,destination) request
// counts accumulated since the previous call and resets them (same per-tick
// delta pattern as SnapshotLatencyHistograms).
func (c *Collector) SnapshotL7Requests() []L7Sample {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]L7Sample, 0, len(c.l7Reqs))
	for k, n := range c.l7Reqs {
		parts := strings.SplitN(k, "|", 3)
		if len(parts) != 3 {
			continue
		}
		out = append(out, L7Sample{Protocol: parts[0], Status: parts[1], Destination: parts[2], Count: n})
	}
	c.l7Reqs = map[string]uint64{}
	return out
}

// L7LatencySample is one protocol+destination latency histogram (le→count).
type L7LatencySample struct {
	Protocol    string
	Destination string
	Buckets     map[string]uint64
}

// SnapshotL7Latency returns and resets the per-(protocol,destination) latency
// histograms accumulated since the previous call.
func (c *Collector) SnapshotL7Latency() []L7LatencySample {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]L7LatencySample, 0, len(c.l7Lat))
	for k, h := range c.l7Lat {
		parts := strings.SplitN(k, "|", 2)
		if len(parts) != 2 {
			continue
		}
		out = append(out, L7LatencySample{Protocol: parts[0], Destination: parts[1], Buckets: histToMap(h)})
	}
	c.l7Lat = map[string][]uint64{}
	return out
}

// ── rich-text parsers (run in userspace, never in BPF) ───────────────────

// parseHTTPRequestLine extracts the method and request URI from the start of an
// HTTP request ("GET /path HTTP/1.1\r\n…"). The path is NOT normalized/templated
// (kept raw) — it only ever appears in the recent-events text, never a label.
func parseHTTPRequestLine(payload []byte) (method, path string) {
	line := payload
	if i := bytes.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	m, rest, ok := bytes.Cut(line, []byte(" "))
	if !ok {
		return "", ""
	}
	p, _, _ := bytes.Cut(rest, []byte(" "))
	return string(bytes.TrimSpace(m)), string(bytes.TrimSpace(p))
}

func httpStatusClass(code int32) string {
	switch {
	case code >= 100 && code < 200:
		return "1xx"
	case code >= 200 && code < 300:
		return "2xx"
	case code >= 300 && code < 400:
		return "3xx"
	case code >= 400 && code < 500:
		return "4xx"
	case code >= 500 && code < 600:
		return "5xx"
	default:
		return "unknown"
	}
}

// sqlStatus maps the BPF STATUS_OK/STATUS_FAILED sentinels to a label.
func sqlStatus(status int32) string {
	if status == 500 {
		return "failed"
	}
	return "ok"
}

// parsePostgresQuery pulls the SQL text out of a Postgres request frame
// ([cmd:1][len:int32][sql NUL]). For a simple query the SQL starts at offset 5;
// for the extended protocol the first frame is Parse ('P') whose SQL also
// follows a NUL-terminated statement name — best-effort, we return the first
// printable run. Never becomes a metric label.
func parsePostgresQuery(req []byte) string {
	if len(req) < 6 {
		return ""
	}
	body := req[5:]
	// Parse frames ('P') carry a NUL-terminated statement name before the SQL.
	if req[0] == 'P' {
		if i := bytes.IndexByte(body, 0); i >= 0 && i+1 < len(body) {
			body = body[i+1:]
		}
	}
	if i := bytes.IndexByte(body, 0); i >= 0 {
		body = body[:i]
	}
	return strings.TrimSpace(string(body))
}

// parseMySQLQuery pulls the SQL text out of a MySQL COM_QUERY/COM_STMT_* packet
// ([len:3][seq:1][cmd:1][sql]). SQL starts at offset 5. Never a metric label.
func parseMySQLQuery(req []byte) string {
	if len(req) < 6 {
		return ""
	}
	return strings.TrimSpace(string(req[5:]))
}

func dnsStatus(rcode int32) string {
	switch rcode {
	case 0:
		return "ok"
	case 2:
		return "servfail"
	case 3:
		return "nxdomain"
	case 5:
		return "refused"
	default:
		return "rcode" + strconv.Itoa(int(rcode))
	}
}

// parseDNS unpacks a DNS message (query or response) into the question name +
// type and, for responses, the A/AAAA answer IPs. Best-effort: a truncated or
// malformed payload yields whatever parsed so far.
func parseDNS(payload []byte) (name, qtype string, answers []string) {
	var p dnsmessage.Parser
	if _, err := p.Start(payload); err != nil {
		return "", "", nil
	}
	q, err := p.Question()
	if err != nil {
		return "", "", nil
	}
	name = strings.TrimSuffix(q.Name.String(), ".")
	qtype = dnsTypeName(q.Type)
	if err := p.SkipAllQuestions(); err != nil {
		return name, qtype, nil
	}
	for {
		h, err := p.AnswerHeader()
		if err != nil {
			break
		}
		switch h.Type {
		case dnsmessage.TypeA:
			if r, err := p.AResource(); err == nil {
				answers = append(answers, fmt.Sprintf("%d.%d.%d.%d", r.A[0], r.A[1], r.A[2], r.A[3]))
			}
		case dnsmessage.TypeAAAA:
			if r, err := p.AAAAResource(); err == nil {
				answers = append(answers, net16(r.AAAA))
			}
		default:
			if err := p.SkipAnswer(); err != nil {
				break
			}
		}
	}
	return name, qtype, answers
}

func dnsTypeName(t dnsmessage.Type) string {
	switch t {
	case dnsmessage.TypeA:
		return "A"
	case dnsmessage.TypeAAAA:
		return "AAAA"
	case dnsmessage.TypeCNAME:
		return "CNAME"
	case dnsmessage.TypeMX:
		return "MX"
	case dnsmessage.TypeNS:
		return "NS"
	case dnsmessage.TypePTR:
		return "PTR"
	case dnsmessage.TypeSRV:
		return "SRV"
	case dnsmessage.TypeTXT:
		return "TXT"
	case dnsmessage.TypeSOA:
		return "SOA"
	default:
		return "TYPE" + strconv.Itoa(int(t))
	}
}

func net16(b [16]byte) string {
	parts := make([]string, 8)
	for i := 0; i < 8; i++ {
		parts[i] = strconv.FormatUint(uint64(b[2*i])<<8|uint64(b[2*i+1]), 16)
	}
	return strings.Join(parts, ":")
}
