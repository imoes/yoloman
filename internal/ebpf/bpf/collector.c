// SPDX-License-Identifier: GPL-2.0
//go:build ignore

// TCP connection lifecycle + process exec + disk I/O latency collector.
//
// Deliberately avoids CO-RE/vmlinux.h: all tracepoints used here
// (sock:inet_sock_set_state, sched:sched_process_exec,
// block:block_rq_issue, block:block_rq_complete) are part of the kernel's
// stable tracepoint ABI (their /sys/kernel/tracing/events/.../format
// layout does not change across kernel versions), so the struct layouts
// below can be hardcoded directly instead of relocated via BTF. They were
// verified against this project's dev/test kernels via
// `bpftool btf dump file /sys/kernel/btf/vmlinux format c` (block_rq_* via
// their own /sys/kernel/tracing/events/block/.../format directly, since
// they aren't in vmlinux's BTF the same way — see tracepoints.h).
//
// Container-awareness (mapping an event's pid to a container ID) is
// deliberately NOT done here: it would require walking kernel cgroup
// structs, whose layout is not part of any stable ABI and would need
// CO-RE/BTF relocation — exactly the complexity this collector avoids by
// tracepoint selection. Every event (including disk I/O, via the pid
// captured at block_rq_issue time) already carries a pid, and
// /proc/<pid>/cgroup is a stable, trivially-read userspace interface for
// exactly this lookup — done in Go instead (see collector.go's
// containerIDForPID).
#include <linux/bpf.h>
#include "tracepoints.h"
#include <bpf/bpf_helpers.h>

char __license[] SEC("license") = "Dual MIT/GPL";

#define TASK_COMM_LEN 16
#define FILENAME_LEN 128
#define RWBS_LEN 8
#define AF_INET 2

#define EVENT_TCP_CONN 1
#define EVENT_EXEC 2
#define EVENT_DISK_IO 3

// TCP states (net/tcp_states.h) needed for connect-latency correlation.
#define TCP_ESTABLISHED 1
#define TCP_SYN_SENT 2

struct event {
	__u32 type;
	__u32 pid;
	__u8 comm[TASK_COMM_LEN];

	// EVENT_TCP_CONN fields (network byte order addresses, host byte order ports).
	__u32 saddr;
	__u32 daddr;
	__u16 sport;
	__u16 dport;
	__u8 oldstate;
	__u8 newstate;
	// Outbound connect() latency: time from SYN_SENT to ESTABLISHED, set only
	// on the transition to ESTABLISHED (0 otherwise).
	__u64 conn_latency_ns;

	// EVENT_EXEC fields.
	__u8 filename[FILENAME_LEN];

	// EVENT_DISK_IO fields — emitted once, at completion, correlated
	// against the matching block_rq_issue via io_start (dev, sector).
	__u32 disk_dev;
	__u64 disk_sector;
	__u32 disk_nr_sector;
	__u64 disk_latency_ns;
	__u8 disk_rwbs[RWBS_LEN];
	__s32 disk_error;
};

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 256 * 1024);
} events SEC(".maps");

// io_key/io_start_val correlate a block_rq_issue with its eventual
// block_rq_complete by (dev, sector) — the standard blktrace correlation
// key (the same approach BCC's biolatency tool uses). A known
// simplification: request merging can mean the sector reported at
// completion isn't byte-identical to the one at issue for every case: good
// enough for a first pass, not a guarantee of matching every merged
// request precisely.
struct io_key {
	__u32 dev;
	__u64 sector;
};

struct io_start_val {
	__u64 ts_ns;
	__u32 pid;
	__u8 comm[TASK_COMM_LEN];
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 10240);
	__type(key, struct io_key);
	__type(value, struct io_start_val);
} io_start SEC(".maps");

// conn_start correlates an outbound connect: SYN_SENT records the start ts
// keyed by the sock pointer, ESTABLISHED looks it up to derive connect latency
// (the same sk-keyed correlation coroot-node-agent uses for connection time).
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 10240);
	__type(key, __u64);
	__type(value, __u64);
} conn_start SEC(".maps");

// Forces BTF debug info for struct event to be retained, so bpf2go's
// `-type event` can find it even though it is only ever used via pointers.
const struct event *unused_event_btf_anchor __attribute__((unused));

SEC("tracepoint/sock/inet_sock_set_state")
int trace_inet_sock_set_state(struct trace_event_raw_inet_sock_set_state *ctx)
{
	if (ctx->family != AF_INET)
		return 0; // v1 scope: IPv4 only

	__u64 sk = (__u64)ctx->skaddr;

	// Outbound connect start: remember when this socket entered SYN_SENT so
	// the eventual ESTABLISHED transition can be timed.
	if (ctx->newstate == TCP_SYN_SENT) {
		__u64 ts = bpf_ktime_get_ns();
		bpf_map_update_elem(&conn_start, &sk, &ts, BPF_ANY);
		return 0; // no event for the intermediate state
	}

	__u64 conn_latency_ns = 0;
	if (ctx->newstate == TCP_ESTABLISHED) {
		__u64 *start = bpf_map_lookup_elem(&conn_start, &sk);
		if (start) {
			conn_latency_ns = bpf_ktime_get_ns() - *start;
			bpf_map_delete_elem(&conn_start, &sk);
		}
	}

	struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
	if (!e)
		return 0;

	__builtin_memset(e, 0, sizeof(*e));
	e->type = EVENT_TCP_CONN;
	e->pid = bpf_get_current_pid_tgid() >> 32;
	bpf_get_current_comm(&e->comm, sizeof(e->comm));
	__builtin_memcpy(&e->saddr, ctx->saddr, 4);
	__builtin_memcpy(&e->daddr, ctx->daddr, 4);
	e->sport = ctx->sport;
	e->dport = ctx->dport;
	e->oldstate = (__u8)ctx->oldstate;
	e->newstate = (__u8)ctx->newstate;
	e->conn_latency_ns = conn_latency_ns;

	bpf_ringbuf_submit(e, 0);
	return 0;
}

SEC("tracepoint/sched/sched_process_exec")
int trace_sched_process_exec(struct trace_event_raw_sched_process_exec *ctx)
{
	struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
	if (!e)
		return 0;

	__builtin_memset(e, 0, sizeof(*e));
	e->type = EVENT_EXEC;
	e->pid = ctx->pid;
	bpf_get_current_comm(&e->comm, sizeof(e->comm));

	unsigned short offset = ctx->__data_loc_filename & 0xFFFF;
	bpf_probe_read_str(&e->filename, sizeof(e->filename), (void *)ctx + offset);

	bpf_ringbuf_submit(e, 0);
	return 0;
}

SEC("tracepoint/block/block_rq_issue")
int trace_block_rq_issue(struct trace_event_raw_block_rq_issue *ctx)
{
	struct io_key key = {};
	key.dev = ctx->dev;
	key.sector = ctx->sector;

	struct io_start_val val = {};
	val.ts_ns = bpf_ktime_get_ns();
	// Deliberately bpf_get_current_pid_tgid(), not ctx->ent.pid: the
	// verifier rejects direct access to trace_entry's common header
	// fields ("invalid bpf_context access") for tracepoint/* programs —
	// only the tracepoint-specific fields after it are checked/allowed.
	// This is also what trace_inet_sock_set_state already does above.
	val.pid = bpf_get_current_pid_tgid() >> 32;
	__builtin_memcpy(&val.comm, ctx->comm, TASK_COMM_LEN);

	bpf_map_update_elem(&io_start, &key, &val, BPF_ANY);
	return 0;
}

SEC("tracepoint/block/block_rq_complete")
int trace_block_rq_complete(struct trace_event_raw_block_rq_complete *ctx)
{
	struct io_key key = {};
	key.dev = ctx->dev;
	key.sector = ctx->sector;

	struct io_start_val *start = bpf_map_lookup_elem(&io_start, &key);
	if (!start)
		return 0; // no matching issue seen (e.g. attached mid-flight) — skip rather than guess

	__u64 latency_ns = bpf_ktime_get_ns() - start->ts_ns;

	struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
	if (!e) {
		bpf_map_delete_elem(&io_start, &key);
		return 0;
	}

	__builtin_memset(e, 0, sizeof(*e));
	e->type = EVENT_DISK_IO;
	e->pid = start->pid;
	__builtin_memcpy(&e->comm, start->comm, TASK_COMM_LEN);
	e->disk_dev = ctx->dev;
	e->disk_sector = ctx->sector;
	e->disk_nr_sector = ctx->nr_sector;
	e->disk_latency_ns = latency_ns;
	__builtin_memcpy(&e->disk_rwbs, ctx->rwbs, RWBS_LEN);
	e->disk_error = ctx->error;

	bpf_ringbuf_submit(e, 0);
	bpf_map_delete_elem(&io_start, &key);
	return 0;
}
