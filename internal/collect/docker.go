package collect

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/store"
)

// DefaultDockerSocket is the Docker Engine API unix socket.
const DefaultDockerSocket = "/var/run/docker.sock"

// DockerCollector samples per-container stats from the Docker Engine API over
// its unix socket (Block J3) and emits them as ordinary metric points, so
// container CPU/RAM/health flow into the same store → services → graphs →
// check-rules pipeline as every other metric — no Docker SDK dependency, pure
// net/http over the socket. Degrades gracefully: when the socket is absent
// (Docker not installed), Sample returns no points and no error.
type DockerCollector struct {
	socket string
	// cgroupRoot is the cgroup mount used to read per-container PSI / throttle /
	// disk-I/O straight from the filesystem (resolved via each container's
	// init-PID). Empty → /sys/fs/cgroup.
	cgroupRoot string
	client     *http.Client
	// monitored is the discovery-driven allow-list of container names to emit
	// metrics for. nil/empty means emit NOTHING — a container is collected only
	// after it is discovered and accepted (Bossman pushes the set into config).
	// This is what keeps an un-monitored container from costing any DB rows.
	monitored map[string]bool
}

// NewDockerCollector builds a collector for the given socket ("" →
// DefaultDockerSocket) and cgroup root ("" → /sys/fs/cgroup). `monitored` is the
// allow-list of container names to collect; empty means none (see the field).
func NewDockerCollector(socket, cgroupRoot string, monitored []string) *DockerCollector {
	if socket == "" {
		socket = DefaultDockerSocket
	}
	if cgroupRoot == "" {
		cgroupRoot = "/sys/fs/cgroup"
	}
	set := make(map[string]bool, len(monitored))
	for _, n := range monitored {
		set[n] = true
	}
	return &DockerCollector{
		socket:     socket,
		cgroupRoot: cgroupRoot,
		monitored:  set,
		client: &http.Client{
			Timeout: 10 * time.Second,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return (&net.Dialer{}).DialContext(ctx, "unix", socket)
				},
			},
		},
	}
}

type dockerContainer struct {
	ID    string   `json:"Id"`
	Names []string `json:"Names"`
	State string   `json:"State"`
}

type dockerCPU struct {
	CPUUsage struct {
		TotalUsage  uint64   `json:"total_usage"`
		PercpuUsage []uint64 `json:"percpu_usage"`
	} `json:"cpu_usage"`
	SystemUsage uint64 `json:"system_cpu_usage"`
	OnlineCPUs  uint32 `json:"online_cpus"`
}

type dockerStats struct {
	CPUStats    dockerCPU `json:"cpu_stats"`
	PreCPUStats dockerCPU `json:"precpu_stats"`
	MemoryStats struct {
		Usage uint64            `json:"usage"`
		Limit uint64            `json:"limit"`
		Stats map[string]uint64 `json:"stats"`
	} `json:"memory_stats"`
	// Per-interface network counters (summed across interfaces). Field layout
	// verified against internal/piggyback/docker.go, which already parses the
	// same /stats response.
	Networks map[string]struct {
		RxBytes uint64 `json:"rx_bytes"`
		TxBytes uint64 `json:"tx_bytes"`
	} `json:"networks"`
}

// dockerInspect carries the two fields the /containers/{id}/json endpoint gives
// us that /stats does not: the restart count and the init process's host PID
// (used to resolve the container's cgroup v2 path for PSI/throttle/disk reads).
type dockerInspect struct {
	RestartCount int `json:"RestartCount"`
	State        struct {
		Pid int `json:"Pid"`
	} `json:"State"`
}

// Sample lists running containers and, for each, fetches a one-shot stats
// snapshot, returning metric points labeled by container name plus an
// aggregate running-count. Returns (nil, nil) when Docker is unavailable.
func (d *DockerCollector) Sample(now time.Time) ([]store.Point, error) {
	// No monitored container → nothing to collect, and not even a socket probe.
	// This is the discovery gate: a host with no container opted in stores zero
	// container series, exactly as if the collector were off.
	if len(d.monitored) == 0 {
		return nil, nil
	}
	if _, err := os.Stat(d.socket); err != nil {
		return nil, nil // Docker not present — skip silently
	}
	containers, err := d.listContainers()
	if err != nil {
		return nil, err
	}

	var points []store.Point
	for _, c := range containers {
		name := containerName(c)
		if !d.monitored[name] {
			continue // not discovered/accepted — do not store its metrics
		}
		labels := map[string]string{"container": name}
		points = append(points, store.Point{Metric: "docker_container_running", Timestamp: now, Value: 1, Labels: labels})
		st, err := d.containerStats(c.ID)
		if err != nil {
			continue // a single container's stats failing must not drop the rest
		}
		points = append(points, containerStatPoints(name, st, now)...)

		// Network I/O (summed across the container's interfaces) — straight
		// from the same /stats snapshot, no extra call.
		var rx, tx uint64
		for _, n := range st.Networks {
			rx += n.RxBytes
			tx += n.TxBytes
		}
		points = append(points,
			store.Point{Metric: "docker_container_net_rx_bytes", Timestamp: now, Value: float64(rx), Labels: labels},
			store.Point{Metric: "docker_container_net_tx_bytes", Timestamp: now, Value: float64(tx), Labels: labels},
		)

		// One inspect call gives us RestartCount + the init PID, which unlocks
		// the container's cgroup path for PSI / throttling / disk I/O reads.
		insp, ierr := d.inspect(c.ID)
		if ierr != nil {
			continue // same "one container's extra data failing must not drop the rest"
		}
		points = append(points, store.Point{Metric: "docker_container_restart_count", Timestamp: now, Value: float64(insp.RestartCount), Labels: labels})
		cgroupPath, ok := containerCgroupPath(d.cgroupRoot, insp.State.Pid)
		if !ok {
			continue // container not running / v1 host — PSI/throttle/disk unavailable
		}
		if some, full, ok := readPSI(filepath.Join(cgroupPath, "cpu.pressure")); ok {
			points = append(points, psiPoints("docker_container_cpu_pressure", labels, now, some, full)...)
		}
		if some, full, ok := readPSI(filepath.Join(cgroupPath, "memory.pressure")); ok {
			points = append(points, psiPoints("docker_container_memory_pressure", labels, now, some, full)...)
		}
		if some, full, ok := readPSI(filepath.Join(cgroupPath, "io.pressure")); ok {
			points = append(points, psiPoints("docker_container_io_pressure", labels, now, some, full)...)
		}
		if _, throttled, usec, ok := readCPUThrottle(filepath.Join(cgroupPath, "cpu.stat")); ok {
			points = append(points,
				store.Point{Metric: "docker_container_cpu_throttled_periods_total", Timestamp: now, Value: float64(throttled), Labels: labels},
				store.Point{Metric: "docker_container_cpu_throttled_seconds_total", Timestamp: now, Value: float64(usec) / 1e6, Labels: labels},
			)
		}
		// Read io.stat directly rather than /stats' blkio_stats, which Moby
		// leaves empty (or inconsistently capitalized) on cgroup-v2 hosts.
		if r, w, ok := readIOStat(filepath.Join(cgroupPath, "io.stat")); ok {
			points = append(points,
				store.Point{Metric: "docker_container_disk_read_bytes_total", Timestamp: now, Value: float64(r), Labels: labels},
				store.Point{Metric: "docker_container_disk_write_bytes_total", Timestamp: now, Value: float64(w), Labels: labels},
			)
		}
	}
	return points, nil
}

func (d *DockerCollector) listContainers() ([]dockerContainer, error) {
	var out []dockerContainer
	if err := d.getJSON("http://docker/containers/json", &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (d *DockerCollector) containerStats(id string) (dockerStats, error) {
	var st dockerStats
	err := d.getJSON("http://docker/containers/"+id+"/stats?stream=false", &st)
	return st, err
}

func (d *DockerCollector) inspect(id string) (dockerInspect, error) {
	var insp dockerInspect
	err := d.getJSON("http://docker/containers/"+id+"/json", &insp)
	return insp, err
}

func (d *DockerCollector) getJSON(url string, v any) error {
	resp, err := d.client.Get(url)
	if err != nil {
		return fmt.Errorf("docker api: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("docker api %s: status %d", url, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

// containerName is the primary name without Docker's leading '/'.
func containerName(c dockerContainer) string {
	if len(c.Names) > 0 {
		return strings.TrimPrefix(c.Names[0], "/")
	}
	if len(c.ID) >= 12 {
		return c.ID[:12]
	}
	return c.ID
}

// containerStatPoints turns one container's stats snapshot into metric points
// (pure — the CPU%/memory math the Docker CLI itself uses). Exposed shape:
// docker_container_cpu_pct, docker_container_mem_bytes, docker_container_mem_pct.
func containerStatPoints(name string, s dockerStats, now time.Time) []store.Point {
	labels := map[string]string{"container": name}
	cpuPct := dockerCPUPercent(s)
	memBytes := dockerMemUsage(s)
	memPct := 0.0
	if s.MemoryStats.Limit > 0 {
		memPct = float64(memBytes) / float64(s.MemoryStats.Limit) * 100
	}
	return []store.Point{
		{Metric: "docker_container_cpu_pct", Timestamp: now, Value: cpuPct, Labels: labels},
		{Metric: "docker_container_mem_bytes", Timestamp: now, Value: float64(memBytes), Labels: labels},
		{Metric: "docker_container_mem_pct", Timestamp: now, Value: memPct, Labels: labels},
	}
}

// dockerCPUPercent replicates docker stats' CPU% (100% == one core): the
// container's CPU-time delta as a fraction of the system CPU-time delta,
// scaled by the number of online CPUs.
func dockerCPUPercent(s dockerStats) float64 {
	cpuDelta := float64(s.CPUStats.CPUUsage.TotalUsage) - float64(s.PreCPUStats.CPUUsage.TotalUsage)
	sysDelta := float64(s.CPUStats.SystemUsage) - float64(s.PreCPUStats.SystemUsage)
	online := float64(s.CPUStats.OnlineCPUs)
	if online == 0 {
		online = float64(len(s.CPUStats.CPUUsage.PercpuUsage))
	}
	if online == 0 {
		online = 1
	}
	if cpuDelta > 0 && sysDelta > 0 {
		return (cpuDelta / sysDelta) * online * 100
	}
	return 0
}

// dockerMemUsage is the working-set memory: total usage minus the page cache
// (inactive_file on cgroup v2, cache on v1), matching docker stats.
func dockerMemUsage(s dockerStats) uint64 {
	usage := s.MemoryStats.Usage
	for _, k := range []string{"inactive_file", "cache"} {
		if c, ok := s.MemoryStats.Stats[k]; ok {
			if usage >= c {
				return usage - c
			}
			return 0
		}
	}
	return usage
}
