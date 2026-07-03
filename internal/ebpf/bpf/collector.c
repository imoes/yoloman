// SPDX-License-Identifier: GPL-2.0
//go:build ignore

// TCP connection lifecycle + process exec collector.
//
// Deliberately avoids CO-RE/vmlinux.h: both tracepoints used here
// (sock:inet_sock_set_state, sched:sched_process_exec) are part of the
// kernel's stable tracepoint ABI (their /sys/kernel/tracing/events/.../format
// layout does not change across kernel versions), so the struct layouts
// below can be hardcoded directly instead of relocated via BTF. They were
// verified against this project's dev/test kernels via
// `bpftool btf dump file /sys/kernel/btf/vmlinux format c`.
#include <linux/bpf.h>
#include "tracepoints.h"
#include <bpf/bpf_helpers.h>

char __license[] SEC("license") = "Dual MIT/GPL";

#define TASK_COMM_LEN 16
#define FILENAME_LEN 128
#define AF_INET 2

#define EVENT_TCP_CONN 1
#define EVENT_EXEC 2

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

	// EVENT_EXEC fields.
	__u8 filename[FILENAME_LEN];
};

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 256 * 1024);
} events SEC(".maps");

// Forces BTF debug info for struct event to be retained, so bpf2go's
// `-type event` can find it even though it is only ever used via pointers.
const struct event *unused_event_btf_anchor __attribute__((unused));

SEC("tracepoint/sock/inet_sock_set_state")
int trace_inet_sock_set_state(struct trace_event_raw_inet_sock_set_state *ctx)
{
	if (ctx->family != AF_INET)
		return 0; // v1 scope: IPv4 only

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
