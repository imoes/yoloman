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

// ── BCC-inspired signals (added alongside the originals) ──────────────────
// Layouts reproduce the exact field offsets from a Debian-13 / kernel-6.12
// /sys/kernel/tracing/events/<subsys>/<event>/format; natural C alignment
// lines up with the kernel layout (same approach as the tracepoints above).
// Only the fields actually read by collector.c need be correct — trailing
// fields are omitted where unused.

// oom:mark_victim — the process the OOM killer selected. `pid` is the first
// field after the common header (stable across kernel versions); `comm` is a
// __data_loc string on modern kernels (read like sched_process_exec's
// filename). Answers "which process was OOM-killed, and when".
struct trace_event_raw_oom_mark_victim {
	struct trace_entry ent;
	int pid;
	__u32 __data_loc_comm;
	char __data[0];
};

// tcp:tcp_retransmit_skb — a segment was retransmitted on this socket. The
// 4-tuple identifies the affected connection; a rising rate is an early
// network-health signal (peer loss/congestion) before timeouts show up.
struct trace_event_raw_tcp_retransmit_skb {
	struct trace_entry ent;
	const void *skbaddr;
	const void *skaddr;
	int state;
	__u16 sport;
	__u16 dport;
	__u16 family;
	__u8 saddr[4];
	__u8 daddr[4];
	__u8 saddr_v6[16];
	__u8 daddr_v6[16];
	char __data[0];
};

// sched:sched_switch — used with sched_wakeup for run-queue latency: the
// time a task spent runnable-but-waiting before it got the CPU (runqlat).
struct trace_event_raw_sched_switch {
	struct trace_entry ent;
	char prev_comm[16];
	pid_t prev_pid;
	int prev_prio;
	long prev_state;
	char next_comm[16];
	pid_t next_pid;
	int next_prio;
	char __data[0];
};

// sched:sched_wakeup / sched_wakeup_new share this template: a task became
// runnable. We stamp its enqueue time here to measure run-queue latency.
struct trace_event_raw_sched_wakeup_template {
	struct trace_entry ent;
	char comm[16];
	pid_t pid;
	int prio;
	int target_cpu;
	char __data[0];
};

// signal:signal_generate — a signal was delivered to `pid` (target) with
// `comm` (target name). The sender is the current task. killsnoop-style.
struct trace_event_raw_signal_generate {
	struct trace_entry ent;
	int sig;
	int err_no;
	int code;
	char comm[16];
	pid_t pid;
	int group;
	int result;
	char __data[0];
};

// ── syscall tracepoints for passive L7 capture (Tier-2) ───────────────────
// The syscall enter/exit tracepoints share a fixed ABI: the 8-byte common
// header, then `int __syscall_nr` padded to 8, then the syscall arguments each
// at an 8-byte slot (offset 16, 24, 32, …). Rather than name the header/nr
// fields (which the verifier rejects for direct access anyway, see collector.c)
// we pad to offset 16 with two __u64 and expose only the argument slots we
// read. Pointer arguments are carried as __u64 and dereferenced with
// bpf_probe_read. This mirrors coroot-node-agent's sys_enter_rw stub.

// read/write/readv/writev/connect: fd, buf/ptr, count/len at args[0..2].
struct trace_event_raw_sys_enter_rw {
	__u64 _pad_header;
	__u64 _pad_nr;
	__u64 fd;
	__u64 buf;
	__u64 count;
};

// sendto/recvfrom: args[0..5] = fd, buf, len, flags, sockaddr*, addrlen.
struct trace_event_raw_sys_enter_sendrecv {
	__u64 _pad_header;
	__u64 _pad_nr;
	__u64 fd;
	__u64 buf;
	__u64 len;
	__u64 flags;
	__u64 addr;
	__u64 addr_len;
};

// Any sys_exit_*: the syscall return value at the first argument slot.
struct trace_event_raw_sys_exit {
	__u64 _pad_header;
	__u64 _pad_nr;
	__s64 ret;
};

// sockaddr_in as seen in a connect()/sendto() userspace pointer — only the
// family, port and IPv4 address are read (IPv4-only, matching the rest of the
// collector). sin_port/sin_addr are network byte order.
struct sockaddr_in_stub {
	__u16 sin_family;
	__u16 sin_port;
	__u32 sin_addr;
};

#endif
