// SPDX-License-Identifier: GPL-2.0
//go:build ignore

// Passive L7 capture (Tier-2), #included into collector.c so it compiles into
// the same bpf2go object. Methodology ported from coroot-node-agent
// (ebpftracer/ebpf/l7/*), simplified for our host-centric, plaintext-only,
// four-protocol scope:
//
//   * We hook the read/write/sendto/recvfrom syscall tracepoints (payload is in
//     userspace memory at these points — no kprobes, no sock-struct walking).
//   * Protocol is detected by sniffing the first payload bytes (never by port).
//   * The destination (addr:port) is taken straight from the connect()/sendto()
//     sockaddr argument — no fd↔sock-pointer bridge (coroot needs that for
//     inbound/accept accuracy; we only report the host's OUTBOUND L7, which is
//     the HTTP-client / DNS / DB-client traffic we care about).
//   * A request is remembered per (pid,fd); the matching response computes the
//     duration and emits one l7_event carrying the raw payload. Rich parsing
//     (URI, SQL, DNS name) happens in Go — the payload is NEVER a metric label.
//
// Deliberate gaps vs. coroot (documented, extendable later): no TLS uprobes, no
// sendmsg/recvmsg (msghdr/iovec), no request pipelining (one outstanding
// request per connection).

#include <bpf/bpf_endian.h>

#define MAX_PAYLOAD_SIZE 512 // power of two — truncation is a bit-mask, verifier-safe
#define AF_INET_L7 2

#define L7_PROTO_HTTP 1
#define L7_PROTO_POSTGRES 2
#define L7_PROTO_MYSQL 5
#define L7_PROTO_DNS 13

#define L7_STATUS_UNKNOWN 0
#define L7_STATUS_OK 200
#define L7_STATUS_FAILED 500

// One captured request/response pair, emitted on the response. payload holds up
// to MAX_PAYLOAD_SIZE bytes of the RESPONSE (for DNS: answers; for HTTP: status
// line) plus, for request-bearing protocols, Go re-reads the request text from
// its own recent-request tracking — here we only carry what the response shows.
struct l7_event {
	__u32 pid;
	__u32 fd;
	__u32 daddr; // network byte order (IPv4)
	__u16 dport; // host byte order
	__u8 protocol;
	__u8 _pad;
	__s32 status;
	__u64 duration_ns;
	__u32 statement_id;
	__u32 req_payload_size;
	__u32 payload_size;
	__u8 req_payload[MAX_PAYLOAD_SIZE]; // the request bytes (method+URI / SQL / DNS query)
	__u8 payload[MAX_PAYLOAD_SIZE];     // the response bytes
};

// (pid,fd) identity shared by the destination and active-request maps.
struct l7_conn_key {
	__u32 pid;
	__u32 fd;
};

// Destination captured at connect()/sendto() time.
struct l7_conn_info {
	__u32 daddr;
	__u16 dport;
};

// An in-flight request awaiting its response.
struct l7_req {
	__u64 ts;
	__u8 protocol;
	__s16 stream_id; // DNS transaction id; -1 for single-stream protocols
	__u32 statement_id;
	__u32 req_size;
	__u8 req_payload[MAX_PAYLOAD_SIZE];
};

// read/recvfrom args stashed at enter, consumed at exit (the kernel fills the
// buffer between enter and exit, so the payload is only valid at exit).
struct l7_read_args {
	__u64 fd;
	__u64 buf;
};

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 10240);
	__type(key, struct l7_conn_key);
	__type(value, struct l7_conn_info);
} l7_conns SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 10240);
	__type(key, struct l7_conn_key);
	__type(value, struct l7_req);
} active_l7_reqs SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 10240);
	__type(key, __u64); // pid_tgid
	__type(value, struct l7_read_args);
} active_l7_reads SEC(".maps");

// The l7_event is far too big for the 512-byte BPF stack, so it lives in a
// per-CPU scratch array (the standard trick; coroot does the same).
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct l7_event);
} l7_event_heap SEC(".maps");

// A second per-CPU scratch for building an l7_req (holds a MAX_PAYLOAD_SIZE
// buffer, too big for the stack).
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct l7_req);
} l7_req_heap SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 256 * 1024);
} l7_events SEC(".maps");

// Force BTF retention for bpf2go's `-type l7_event`.
const struct l7_event *unused_l7_event_btf_anchor __attribute__((unused));

// ── protocol detectors (byte-sniffing, ported verbatim from coroot) ──────────

static __always_inline int l7_is_http_request(__u8 *b)
{
	if (b[0] == 'G' && b[1] == 'E' && b[2] == 'T')
		return 1;
	if (b[0] == 'P' && b[1] == 'O' && b[2] == 'S' && b[3] == 'T')
		return 1;
	if (b[0] == 'H' && b[1] == 'E' && b[2] == 'A' && b[3] == 'D')
		return 1;
	if (b[0] == 'P' && b[1] == 'U' && b[2] == 'T')
		return 1;
	if (b[0] == 'D' && b[1] == 'E' && b[2] == 'L' && b[3] == 'E' && b[4] == 'T' && b[5] == 'E')
		return 1;
	if (b[0] == 'O' && b[1] == 'P' && b[2] == 'T' && b[3] == 'I' && b[4] == 'O' && b[5] == 'N' && b[6] == 'S')
		return 1;
	if (b[0] == 'P' && b[1] == 'A' && b[2] == 'T' && b[3] == 'C' && b[4] == 'H')
		return 1;
	return 0;
}

static __always_inline int l7_is_http_response(__u8 *b, __s32 *status)
{
	if (b[0] != 'H' || b[1] != 'T' || b[2] != 'T' || b[3] != 'P' || b[4] != '/')
		return 0;
	if (b[5] < '0' || b[5] > '9' || b[6] != '.' || b[7] < '0' || b[7] > '9' || b[8] != ' ')
		return 0;
	if (b[9] < '0' || b[9] > '9' || b[10] < '0' || b[10] > '9' || b[11] < '0' || b[11] > '9')
		return 0;
	*status = (b[9] - '0') * 100 + (b[10] - '0') * 10 + (b[11] - '0');
	return 1;
}

#define DNS_QR_RESPONSE 0b10000000
#define DNS_OPCODE 0b01111000
#define DNS_RCODE 0b00001111

// DNS wire header: id(2) bits0(1) bits1(1) qdcount(2). b must have >=6 bytes.
static __always_inline int l7_is_dns_request(__u8 *b, __s16 *stream_id)
{
	if (b[2] & DNS_QR_RESPONSE)
		return 0;
	if (b[2] & DNS_OPCODE)
		return 0;
	__u16 qdcount = ((__u16)b[4] << 8) | b[5];
	if (qdcount != 1)
		return 0;
	*stream_id = (__s16)(((__u16)b[0] << 8) | b[1]);
	return 1;
}

static __always_inline int l7_is_dns_response(__u8 *b, __s16 *stream_id, __s32 *status)
{
	if (!(b[2] & DNS_QR_RESPONSE))
		return 0;
	if (b[2] & DNS_OPCODE)
		return 0;
	__u16 qdcount = ((__u16)b[4] << 8) | b[5];
	if (qdcount != 1)
		return 0;
	*status = b[3] & DNS_RCODE;
	*stream_id = (__s16)(((__u16)b[0] << 8) | b[1]);
	return 1;
}

// ── helpers ──────────────────────────────────────────────────────────────

// Read a connect()/sendto() sockaddr pointer, storing dst addr:port for (pid,fd)
// if it is an IPv4 address.
static __always_inline void l7_capture_dst(__u32 pid, __u32 fd, __u64 addr_ptr)
{
	if (!addr_ptr)
		return;
	struct sockaddr_in_stub sa = {};
	if (bpf_probe_read(&sa, sizeof(sa), (void *)addr_ptr))
		return;
	if (sa.sin_family != AF_INET_L7)
		return;
	struct l7_conn_key k = {.pid = pid, .fd = (__u32)fd};
	struct l7_conn_info ci = {.daddr = sa.sin_addr, .dport = bpf_ntohs(sa.sin_port)};
	bpf_map_update_elem(&l7_conns, &k, &ci, BPF_ANY);
}

// The request side: detect a protocol in the outgoing payload and remember it
// per (pid,fd) so the matching response can time it.
static __always_inline void l7_handle_request(__u32 pid, __u64 fd, __u64 buf, __u64 size)
{
	if (size < 16)
		return;
	__u8 b[16];
	if (bpf_probe_read(&b, sizeof(b), (void *)buf))
		return;

	__u8 protocol = 0;
	__s16 stream_id = -1;
	if (l7_is_http_request(b)) {
		protocol = L7_PROTO_HTTP;
	} else if (l7_is_dns_request(b, &stream_id)) {
		protocol = L7_PROTO_DNS;
	}
	if (protocol == 0)
		return;

	__u32 zero = 0;
	// Reuse the event heap's request scratch is unavailable here; build the
	// l7_req on the stack (it holds a MAX_PAYLOAD_SIZE buffer → too big). Use a
	// per-CPU heap for the request too.
	struct l7_req *r = bpf_map_lookup_elem(&l7_req_heap, &zero);
	if (!r)
		return;
	// The l7_req lives in a per-CPU map (valid memory to the verifier), so we
	// set every scalar explicitly instead of a bulk memset (unsupported for a
	// struct this large); the payload tail beyond req_size is never read (Go
	// bounds by req_size).
	r->ts = bpf_ktime_get_ns();
	r->protocol = protocol;
	r->stream_id = stream_id;
	r->statement_id = 0;
	__u64 psize = size;
	psize &= (MAX_PAYLOAD_SIZE - 1);
	r->req_size = (__u32)psize;
	if (psize > 0)
		bpf_probe_read(&r->req_payload, psize, (void *)buf);

	struct l7_conn_key k = {.pid = pid, .fd = (__u32)fd};
	bpf_map_update_elem(&active_l7_reqs, &k, r, BPF_ANY);
}

// The response side, run at read/recvfrom EXIT: correlate with the stored
// request, compute the duration, and emit one l7_event.
static __always_inline void l7_handle_response(void *ctx, __u32 pid, __u64 fd, __u64 buf, __s64 ret)
{
	if (ret < 16)
		return;
	struct l7_conn_key k = {.pid = pid, .fd = (__u32)fd};
	struct l7_req *req = bpf_map_lookup_elem(&active_l7_reqs, &k);
	if (!req)
		return; // never saw the request — skip

	__u8 b[16];
	if (bpf_probe_read(&b, sizeof(b), (void *)buf)) {
		bpf_map_delete_elem(&active_l7_reqs, &k);
		return;
	}

	__s32 status = L7_STATUS_UNKNOWN;
	__s16 stream_id = -1;
	int matched = 0;
	if (req->protocol == L7_PROTO_HTTP) {
		matched = l7_is_http_response(b, &status);
	} else if (req->protocol == L7_PROTO_DNS) {
		matched = l7_is_dns_response(b, &stream_id, &status);
		if (matched && stream_id != req->stream_id)
			matched = 0; // response for a different query on this socket
	}
	if (!matched)
		return; // leave the request in place; a later read may be the response

	__u32 zero = 0;
	struct l7_event *e = bpf_map_lookup_elem(&l7_event_heap, &zero);
	if (!e) {
		bpf_map_delete_elem(&active_l7_reqs, &k);
		return;
	}
	// Per-CPU map memory (see l7_handle_request) — set every scalar explicitly,
	// no bulk memset. Payload tails beyond *_payload_size are never read in Go.
	e->pid = pid;
	e->fd = (__u32)fd;
	e->protocol = req->protocol;
	e->_pad = 0;
	e->status = status;
	e->statement_id = req->statement_id;
	e->duration_ns = bpf_ktime_get_ns() - req->ts;
	e->daddr = 0;
	e->dport = 0;

	struct l7_conn_info *ci = bpf_map_lookup_elem(&l7_conns, &k);
	if (ci) {
		e->daddr = ci->daddr;
		e->dport = ci->dport;
	}

	// Request payload (already truncated on capture).
	__u32 rq = req->req_size & (MAX_PAYLOAD_SIZE - 1);
	e->req_payload_size = rq;
	if (rq > 0)
		bpf_probe_read(&e->req_payload, rq, &req->req_payload);

	// Response payload.
	__u64 rsize = (__u64)ret;
	rsize &= (MAX_PAYLOAD_SIZE - 1);
	e->payload_size = (__u32)rsize;
	if (rsize > 0)
		bpf_probe_read(&e->payload, rsize, (void *)buf);

	bpf_map_delete_elem(&active_l7_reqs, &k);
	bpf_ringbuf_output(&l7_events, e, sizeof(*e), 0);
}

// ── syscall tracepoint handlers ──────────────────────────────────────────

SEC("tracepoint/syscalls/sys_enter_connect")
int l7_sys_enter_connect(struct trace_event_raw_sys_enter_rw *ctx)
{
	__u32 pid = bpf_get_current_pid_tgid() >> 32;
	l7_capture_dst(pid, ctx->fd, ctx->buf); // buf slot = sockaddr* for connect
	return 0;
}

SEC("tracepoint/syscalls/sys_enter_write")
int l7_sys_enter_write(struct trace_event_raw_sys_enter_rw *ctx)
{
	__u32 pid = bpf_get_current_pid_tgid() >> 32;
	l7_handle_request(pid, ctx->fd, ctx->buf, ctx->count);
	return 0;
}

SEC("tracepoint/syscalls/sys_enter_sendto")
int l7_sys_enter_sendto(struct trace_event_raw_sys_enter_sendrecv *ctx)
{
	__u32 pid = bpf_get_current_pid_tgid() >> 32;
	l7_capture_dst(pid, ctx->fd, ctx->addr); // UDP DNS carries the server here
	l7_handle_request(pid, ctx->fd, ctx->buf, ctx->len);
	return 0;
}

SEC("tracepoint/syscalls/sys_enter_read")
int l7_sys_enter_read(struct trace_event_raw_sys_enter_rw *ctx)
{
	__u64 id = bpf_get_current_pid_tgid();
	struct l7_read_args a = {.fd = ctx->fd, .buf = ctx->buf};
	bpf_map_update_elem(&active_l7_reads, &id, &a, BPF_ANY);
	return 0;
}

SEC("tracepoint/syscalls/sys_enter_recvfrom")
int l7_sys_enter_recvfrom(struct trace_event_raw_sys_enter_sendrecv *ctx)
{
	__u64 id = bpf_get_current_pid_tgid();
	struct l7_read_args a = {.fd = ctx->fd, .buf = ctx->buf};
	bpf_map_update_elem(&active_l7_reads, &id, &a, BPF_ANY);
	return 0;
}

static __always_inline int l7_exit_read(void *ctx, __s64 ret)
{
	__u64 id = bpf_get_current_pid_tgid();
	struct l7_read_args *a = bpf_map_lookup_elem(&active_l7_reads, &id);
	if (!a)
		return 0;
	__u64 fd = a->fd;
	__u64 buf = a->buf;
	bpf_map_delete_elem(&active_l7_reads, &id);
	if (ret > 0)
		l7_handle_response(ctx, id >> 32, fd, buf, ret);
	return 0;
}

SEC("tracepoint/syscalls/sys_exit_read")
int l7_sys_exit_read(struct trace_event_raw_sys_exit *ctx)
{
	return l7_exit_read(ctx, ctx->ret);
}

SEC("tracepoint/syscalls/sys_exit_recvfrom")
int l7_sys_exit_recvfrom(struct trace_event_raw_sys_exit *ctx)
{
	return l7_exit_read(ctx, ctx->ret);
}
