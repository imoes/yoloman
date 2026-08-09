package ebpf

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

// readCgroupFile is overridable in tests (see container_test.go) so
// containerIDForPID's /proc read can be exercised without a real process.
var readCgroupFile = os.ReadFile

// containerIDPattern matches the long hex-ID segment every mainstream
// container runtime embeds in a process's cgroup path: Docker's own cgroup
// driver ("/docker/<64-hex>"), Docker via the systemd cgroup driver
// ("docker-<64-hex>.scope"), and containerd/CRI ("cri-containerd-<64-hex>.scope",
// used for both standalone containerd and Kubernetes pods). A bare-metal
// process's cgroup path (e.g. "/user.slice/...", "/init.scope",
// "/system.slice/sshd.service") contains no such run, which is exactly the
// desired "not containerized" result.
var containerIDPattern = regexp.MustCompile(`[0-9a-f]{12,64}`)

// containerIDForPID attempts to resolve pid's container ID (if it's running
// inside a container) by reading /proc/<pid>/cgroup. Deliberately
// implemented against /proc rather than as eBPF kernel cgroup-struct reads:
// the /proc interface is a stable userspace ABI, whereas walking kernel
// cgroup structs directly from BPF would need CO-RE/BTF-relocatable field
// offsets that change across kernel versions — exactly the complexity this
// collector's tracepoint-only design otherwise avoids (see bpf/collector.c).
// Best-effort: returns "" if the process has already exited by the time
// this runs, isn't containerized, or the path doesn't match a recognized
// pattern — never an error, since this is enrichment, not core event data.
func containerIDForPID(pid uint32) string {
	data, err := readCgroupFile(fmt.Sprintf("/proc/%d/cgroup", pid))
	if err != nil {
		return ""
	}
	return containerIDFromCgroupData(data)
}

// containerIDFromCgroupData extracts the longest recognized hex-ID segment
// across every line of a /proc/<pid>/cgroup file's content. Longest-match
// (rather than first-match) matters because some lines' hierarchy names
// (e.g. a controller name) can themselves contain shorter hex-looking runs;
// the actual container ID is reliably the longest one present.
func containerIDFromCgroupData(data []byte) string {
	var best string
	for _, line := range strings.Split(string(data), "\n") {
		if m := containerIDPattern.FindString(line); len(m) > len(best) {
			best = m
		}
	}
	return best
}
