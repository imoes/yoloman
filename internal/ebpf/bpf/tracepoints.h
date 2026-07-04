// SPDX-License-Identifier: GPL-2.0
//go:build ignore

// Minimal tracepoint argument struct definitions, hand-extracted from
// `bpftool btf dump file /sys/kernel/btf/vmlinux format c` (or, for the two
// block:* tracepoints added for disk I/O latency, directly from
// /sys/kernel/tracing/events/block/block_rq_{issue,complete}/format) rather
// than generated wholesale, since only these tracepoints' argument layouts
// are needed (see collector.c for why no full vmlinux.h/CO-RE is required
// here). Field order and types must match the kernel's
// /sys/kernel/tracing/events/<subsys>/<event>/format exactly.
#ifndef __TRACEPOINTS_H__
#define __TRACEPOINTS_H__

#include <linux/types.h>

typedef int pid_t;

struct trace_entry {
	unsigned short type;
	unsigned char flags;
	unsigned char preempt_count;
	int pid;
};

struct trace_event_raw_inet_sock_set_state {
	struct trace_entry ent;
	const void *skaddr;
	int oldstate;
	int newstate;
	__u16 sport;
	__u16 dport;
	__u16 family;
	__u16 protocol;
	__u8 saddr[4];
	__u8 daddr[4];
	__u8 saddr_v6[16];
	__u8 daddr_v6[16];
	char __data[0];
};

struct trace_event_raw_sched_process_exec {
	struct trace_entry ent;
	__u32 __data_loc_filename;
	pid_t pid;
	pid_t old_pid;
	char __data[0];
};

// block:block_rq_issue / block:block_rq_complete — the standard blktrace
// tracepoints (stable ABI, present since long-EOL kernels), used to
// correlate a request's issue and completion by (dev, sector) and compute
// its latency (see collector.c). Field order/types below reproduce the
// exact offsets from this project's dev/test kernel's
// /sys/kernel/tracing/events/block/block_rq_{issue,complete}/format —
// natural C struct alignment (no __attribute__((packed))) lines up with
// the kernel's layout here, the same approach already used above for the
// other two tracepoints.
struct trace_event_raw_block_rq_issue {
	struct trace_entry ent;
	__u32 dev;
	__u64 sector;
	__u32 nr_sector;
	__u32 bytes;
	__u16 ioprio;
	char rwbs[8];
	char comm[16];
	__u32 __data_loc_cmd;
};

struct trace_event_raw_block_rq_complete {
	struct trace_entry ent;
	__u32 dev;
	__u64 sector;
	__u32 nr_sector;
	__s32 error;
	__u16 ioprio;
	char rwbs[8];
	__u32 __data_loc_cmd;
};

#endif
