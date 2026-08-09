// Package piggyback collects monitoring data on behalf of OTHER hosts — the
// CheckMK "piggyback" idea: an agent on a hypervisor/container host queries the
// local runtime and reports each guest as its own host. Bossman's
// hosts/overview already distributes such extra hosts (as satellites), so a
// collector here only needs to produce one Host per guest with its metrics.
//
// This file implements the Docker collector: it talks to the local Docker
// daemon over its unix socket (no SDK dependency — just net/http) and reports
// each running container as a host with CPU / memory / network metrics derived
// from the Docker stats API.
package piggyback

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"
)

// Metric is one named reading for a piggyback host (mirrors the overview's
// MetricSample without importing package server).
type Metric struct {
	Name   string
	Value  float64
	Labels map[string]string
}

// Host is one guest reported on behalf of the querying host.
type Host struct {
	Name    string // the guest's host name (container name)
	Metrics []Metric
}

// Collector produces piggyback hosts on behalf of the querying host — one
// implementation per source (Docker containers, Proxmox guests, vSphere VMs).
type Collector interface {
	// Collect returns the guests + their metrics, or an error if the source
	// isn't present/reachable (treated as "nothing to report").
	Collect(ctx context.Context) ([]Host, error)
	// Kind labels the reported hosts' Mode, e.g. "container".
	Kind() string
	// Source describes this collector for display (F-9): what kind of source
	// it is and where it points, so the operator can see which piggyback
	// sources a host is configured with — not just the guests they produce.
	Source() SourceInfo
}

// SourceInfo describes a configured piggyback source for display (F-9).
type SourceInfo struct {
	Type   string `json:"type"`   // "docker" | "proxmox" | "vsphere" | "libvirt"
	Target string `json:"target"` // socket path / API host / connection URI
}

// Kind implements Collector.
func (c *DockerCollector) Kind() string { return "container" }

// Source implements Collector.
func (c *DockerCollector) Source() SourceInfo {
	target := c.SocketPath
	if target == "" {
		target = "/var/run/docker.sock"
	}
	return SourceInfo{Type: "docker", Target: target}
}

// DockerCollector reports each running container as a piggyback host. SocketPath
// defaults to /var/run/docker.sock; on a containerized agent point it at
// /proc/1/root/run/docker.sock.
type DockerCollector struct {
	SocketPath string
	client     *http.Client
}

// NewDockerCollector returns a collector over the given socket (empty →
// /var/run/docker.sock).
func NewDockerCollector(socketPath string) *DockerCollector {
	if socketPath == "" {
		socketPath = "/var/run/docker.sock"
	}
	return &DockerCollector{
		SocketPath: socketPath,
		client: &http.Client{
			Timeout: 15 * time.Second,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
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

type dockerStats struct {
	CPUStats    dockerCPU `json:"cpu_stats"`
	PreCPUStats dockerCPU `json:"precpu_stats"`
	MemoryStats struct {
		Usage uint64            `json:"usage"`
		Limit uint64            `json:"limit"`
		Stats map[string]uint64 `json:"stats"`
	} `json:"memory_stats"`
	Networks map[string]struct {
		RxBytes uint64 `json:"rx_bytes"`
		TxBytes uint64 `json:"tx_bytes"`
	} `json:"networks"`
}

type dockerCPU struct {
	CPUUsage struct {
		TotalUsage  uint64   `json:"total_usage"`
		PercpuUsage []uint64 `json:"percpu_usage"`
	} `json:"cpu_usage"`
	SystemUsage uint64 `json:"system_cpu_usage"`
	OnlineCPUs  uint64 `json:"online_cpus"`
}

// Collect returns one Host per running container. A daemon that isn't reachable
// (no Docker on this host) yields an error the caller treats as "no Docker".
func (c *DockerCollector) Collect(ctx context.Context) ([]Host, error) {
	var containers []dockerContainer
	if err := c.getJSON(ctx, "/containers/json", &containers); err != nil {
		return nil, err
	}
	out := make([]Host, 0, len(containers))
	for _, ct := range containers {
		name := containerName(ct.Names)
		if name == "" {
			continue
		}
		metrics := []Metric{{Name: "container_running", Value: boolValue(ct.State == "running")}}
		var st dockerStats
		if err := c.getJSON(ctx, "/containers/"+ct.ID+"/stats?stream=false", &st); err == nil {
			metrics = append(metrics, statsToMetrics(st)...)
		}
		out = append(out, Host{Name: name, Metrics: metrics})
	}
	return out, nil
}

func (c *DockerCollector) getJSON(ctx context.Context, path string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://docker"+path, nil)
	if err != nil {
		return err
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("docker %s: %w", path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("docker %s: status %d", path, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

// statsToMetrics turns one stats sample into CPU%, memory, and network metrics
// the same way `docker stats` does.
func statsToMetrics(st dockerStats) []Metric {
	var out []Metric

	cpuDelta := float64(st.CPUStats.CPUUsage.TotalUsage) - float64(st.PreCPUStats.CPUUsage.TotalUsage)
	sysDelta := float64(st.CPUStats.SystemUsage) - float64(st.PreCPUStats.SystemUsage)
	cpus := float64(st.CPUStats.OnlineCPUs)
	if cpus == 0 {
		cpus = float64(len(st.CPUStats.CPUUsage.PercpuUsage))
	}
	if sysDelta > 0 && cpuDelta > 0 {
		out = append(out, Metric{Name: "container_cpu_pct", Value: (cpuDelta / sysDelta) * cpus * 100.0})
	}

	// RSS-ish working set: usage minus page cache (matches docker stats' MEM USAGE).
	cache := st.MemoryStats.Stats["inactive_file"]
	if cache == 0 {
		cache = st.MemoryStats.Stats["cache"]
	}
	used := st.MemoryStats.Usage
	if used > cache {
		used -= cache
	}
	out = append(out, Metric{Name: "container_mem_used_bytes", Value: float64(used)})
	if st.MemoryStats.Limit > 0 {
		out = append(out, Metric{Name: "container_mem_pct", Value: float64(used) / float64(st.MemoryStats.Limit) * 100.0})
	}

	var rx, tx uint64
	for _, n := range st.Networks {
		rx += n.RxBytes
		tx += n.TxBytes
	}
	out = append(out,
		Metric{Name: "container_net_rx_bytes", Value: float64(rx)},
		Metric{Name: "container_net_tx_bytes", Value: float64(tx)},
	)
	return out
}

// containerName returns the container's primary name without Docker's leading
// slash (e.g. "/upbeat_borg" → "upbeat_borg").
func containerName(names []string) string {
	if len(names) == 0 {
		return ""
	}
	return strings.TrimPrefix(names[0], "/")
}

func boolValue(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
