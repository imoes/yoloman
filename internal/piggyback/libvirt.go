package piggyback

// This file implements the libvirt/KVM collector: on a host that runs virtual
// machines directly via libvirt (no Proxmox/vCenter in front), it reports each
// domain as its own piggyback host — the CheckMK agent_kvm idea. It shells out
// to the local `virsh` (already relied on by the virsh / virt_facts modules)
// rather than speaking the libvirt RPC protocol, so there's no CGO or SDK
// dependency. Like the Docker collector it auto-detects: no virsh / no running
// libvirtd → a harmless no-op.

import (
	"bufio"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// LibvirtCollector reports every libvirt domain (running or defined) as its own
// piggyback host. URI is the libvirt connection URI (empty → qemu:///system).
type LibvirtCollector struct {
	URI string
}

// NewLibvirtCollector builds a collector for the given libvirt URI (empty →
// qemu:///system, the local system-wide QEMU/KVM instance).
func NewLibvirtCollector(uri string) *LibvirtCollector {
	if uri == "" {
		uri = "qemu:///system"
	}
	return &LibvirtCollector{URI: uri}
}

// Kind implements Collector.
func (l *LibvirtCollector) Kind() string { return "vm" }

// Source implements Collector (F-9): the libvirt connection URI.
func (l *LibvirtCollector) Source() SourceInfo {
	return SourceInfo{Type: "libvirt", Target: l.URI}
}

// virsh runs `virsh -c <uri> <args...>` with a bounded timeout and returns its
// stdout.
func (l *LibvirtCollector) virsh(ctx context.Context, args ...string) (string, error) {
	path, err := exec.LookPath("virsh")
	if err != nil {
		return "", fmt.Errorf("virsh not present: %w", err)
	}
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	full := append([]string{"-c", l.URI}, args...)
	out, err := exec.CommandContext(cctx, path, full...).Output()
	if err != nil {
		return "", fmt.Errorf("virsh %s: %w", strings.Join(args, " "), err)
	}
	return string(out), nil
}

// Collect lists all domains and reads per-domain stats in a single domstats
// call, mapping each domain to a piggyback host.
func (l *LibvirtCollector) Collect(ctx context.Context) ([]Host, error) {
	// All defined domains (running + shut off), one name per line.
	nameOut, err := l.virsh(ctx, "list", "--all", "--name")
	if err != nil {
		return nil, err
	}
	var names []string
	sc := bufio.NewScanner(strings.NewReader(nameOut))
	for sc.Scan() {
		if n := strings.TrimSpace(sc.Text()); n != "" {
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		return nil, nil
	}

	// Live stats for active domains only (inactive ones report nothing here and
	// fall through to vm_running=0 below).
	statsOut, err := l.virsh(ctx, "domstats", "--state", "--cpu-total", "--balloon", "--vcpu")
	if err != nil {
		return nil, err
	}
	stats := parseDomstats(statsOut)
	return domainsToHosts(names, stats), nil
}

// parseDomstats parses `virsh domstats` output — blocks led by "Domain: 'name'"
// then indented "key=value" lines — into name → {key: value}.
func parseDomstats(out string) map[string]map[string]string {
	res := map[string]map[string]string{}
	var cur string
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "Domain:") {
			// Domain: 'web01'
			name := strings.Trim(strings.TrimSpace(strings.TrimPrefix(line, "Domain:")), "'")
			cur = name
			res[cur] = map[string]string{}
			continue
		}
		if cur == "" {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok {
			res[cur][k] = v
		}
	}
	return res
}

// domainsToHosts maps every domain to a piggyback host with its metrics. Memory
// (balloon) is reported in KiB by virsh; cpu.time is cumulative nanoseconds.
func domainsToHosts(names []string, stats map[string]map[string]string) []Host {
	var out []Host
	for _, name := range names {
		s := stats[name] // nil for inactive domains
		running := statFloat(s, "state.state") == 1
		metrics := []Metric{{Name: "vm_running", Value: boolValue(running)}}
		if running {
			if v := statFloat(s, "vcpu.current"); v > 0 {
				metrics = append(metrics, Metric{Name: "vm_vcpus", Value: v})
			}
			if v := statFloat(s, "cpu.time"); v > 0 {
				metrics = append(metrics, Metric{Name: "vm_cpu_time_seconds", Value: v / 1e9})
			}
			cur := statFloat(s, "balloon.current")
			max := statFloat(s, "balloon.maximum")
			if cur > 0 {
				metrics = append(metrics, Metric{Name: "vm_mem_used_bytes", Value: cur * 1024})
			}
			if max > 0 {
				metrics = append(metrics, Metric{Name: "vm_mem_max_bytes", Value: max * 1024})
				if cur > 0 {
					metrics = append(metrics, Metric{Name: "vm_mem_pct", Value: cur / max * 100.0})
				}
			}
		}
		out = append(out, Host{Name: name, Metrics: metrics})
	}
	return out
}

// statFloat reads a numeric domstats value, 0 if absent/unparseable.
func statFloat(s map[string]string, key string) float64 {
	if s == nil {
		return 0
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(s[key]), 64)
	if err != nil {
		return 0
	}
	return f
}
