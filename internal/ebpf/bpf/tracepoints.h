// SPDX-License-Identifier: GPL-2.0
//go:build ignore

// Minimal tracepoint argument struct definitions, hand-extracted from
// `bpftool btf dump file /sys/kernel/btf/vmlinux format c` rather than
// generated wholesale, since only these two tracepoints' argument layouts
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

#endif
