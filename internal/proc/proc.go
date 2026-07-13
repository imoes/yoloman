// Package proc parses Linux /proc files into structured, JSON-friendly Go
// values, and provides a path-guarded raw reader for /proc entries that have
// no dedicated parser.
package proc

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// MemInfo maps /proc/meminfo field names (e.g. "MemTotal", "MemFree") to
// their value in kB, as reported by the kernel.
type MemInfo map[string]int64

// ParseMemInfo parses the contents of /proc/meminfo.
func ParseMemInfo(r io.Reader) (MemInfo, error) {
	info := MemInfo{}
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		key, rest, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		val, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("meminfo: parsing value for %q: %w", key, err)
		}
		info[key] = val
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return info, nil
}

// LoadAvg is the parsed content of /proc/loadavg.
type LoadAvg struct {
	Load1         float64 `json:"load1"`
	Load5         float64 `json:"load5"`
	Load15        float64 `json:"load15"`
	RunnableProcs int     `json:"runnable_procs"`
	TotalProcs    int     `json:"total_procs"`
	LastPID       int     `json:"last_pid"`
}

// ParseLoadAvg parses the contents of /proc/loadavg.
func ParseLoadAvg(r io.Reader) (LoadAvg, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return LoadAvg{}, err
	}
	fields := strings.Fields(string(data))
	if len(fields) != 5 {
		return LoadAvg{}, fmt.Errorf("loadavg: expected 5 fields, got %d", len(fields))
	}
	var la LoadAvg
	if la.Load1, err = strconv.ParseFloat(fields[0], 64); err != nil {
		return LoadAvg{}, fmt.Errorf("loadavg: load1: %w", err)
	}
	if la.Load5, err = strconv.ParseFloat(fields[1], 64); err != nil {
		return LoadAvg{}, fmt.Errorf("loadavg: load5: %w", err)
	}
	if la.Load15, err = strconv.ParseFloat(fields[2], 64); err != nil {
		return LoadAvg{}, fmt.Errorf("loadavg: load15: %w", err)
	}
	running, total, ok := strings.Cut(fields[3], "/")
	if !ok {
		return LoadAvg{}, fmt.Errorf("loadavg: malformed running/total field %q", fields[3])
	}
	if la.RunnableProcs, err = strconv.Atoi(running); err != nil {
		return LoadAvg{}, fmt.Errorf("loadavg: runnable procs: %w", err)
	}
	if la.TotalProcs, err = strconv.Atoi(total); err != nil {
		return LoadAvg{}, fmt.Errorf("loadavg: total procs: %w", err)
	}
	if la.LastPID, err = strconv.Atoi(fields[4]); err != nil {
		return LoadAvg{}, fmt.Errorf("loadavg: last pid: %w", err)
	}
	return la, nil
}

// Uptime is the parsed content of /proc/uptime.
type Uptime struct {
	UptimeSeconds float64 `json:"uptime_seconds"`
	IdleSeconds   float64 `json:"idle_seconds"`
}

// ParseUptime parses the contents of /proc/uptime.
func ParseUptime(r io.Reader) (Uptime, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return Uptime{}, err
	}
	fields := strings.Fields(string(data))
	if len(fields) != 2 {
		return Uptime{}, fmt.Errorf("uptime: expected 2 fields, got %d", len(fields))
	}
	var u Uptime
	if u.UptimeSeconds, err = strconv.ParseFloat(fields[0], 64); err != nil {
		return Uptime{}, fmt.Errorf("uptime: %w", err)
	}
	if u.IdleSeconds, err = strconv.ParseFloat(fields[1], 64); err != nil {
		return Uptime{}, fmt.Errorf("uptime: %w", err)
	}
	return u, nil
}

// statCPUModes names the columns of the aggregate "cpu" line in /proc/stat,
// in order. Values are jiffies (1/USER_HZ, typically 1/100s) since boot.
var statCPUModes = []string{"user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"}

// ParseStatCPUModes parses /proc/stat's aggregate "cpu" line into per-mode
// cumulative seconds (jiffies / 100). Coroot-style CPU-by-mode: the caller
// emits each as a counter and derives per-mode utilization from the rate.
func ParseStatCPUModes(r io.Reader) (map[string]float64, error) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 5 || fields[0] != "cpu" {
			continue
		}
		out := make(map[string]float64, len(statCPUModes))
		for i, mode := range statCPUModes {
			if i+1 >= len(fields) {
				break
			}
			v, err := strconv.ParseUint(fields[i+1], 10, 64)
			if err != nil {
				return nil, fmt.Errorf("stat: cpu %s: %w", mode, err)
			}
			out[mode] = float64(v) / 100.0 // jiffies -> seconds (USER_HZ=100)
		}
		return out, nil
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return nil, fmt.Errorf("stat: no aggregate cpu line found")
}

// CPU holds the key/value fields of a single /proc/cpuinfo processor block.
type CPU map[string]string

// ParseCPUInfo parses the contents of /proc/cpuinfo. Each processor block
// (separated by a blank line) becomes one CPU entry.
func ParseCPUInfo(r io.Reader) ([]CPU, error) {
	var cpus []CPU
	current := CPU{}
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" {
			if len(current) > 0 {
				cpus = append(cpus, current)
				current = CPU{}
			}
			continue
		}
		key, val, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		current[strings.TrimSpace(key)] = strings.TrimSpace(val)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(current) > 0 {
		cpus = append(cpus, current)
	}
	return cpus, nil
}

// Mount is one parsed line of /proc/mounts.
type Mount struct {
	Device     string   `json:"device"`
	MountPoint string   `json:"mount_point"`
	FSType     string   `json:"fs_type"`
	Options    []string `json:"options"`
}

// ParseMounts parses the contents of /proc/mounts.
func ParseMounts(r io.Reader) ([]Mount, error) {
	var mounts []Mount
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 4 {
			return nil, fmt.Errorf("mounts: malformed line %q", line)
		}
		mounts = append(mounts, Mount{
			Device:     fields[0],
			MountPoint: fields[1],
			FSType:     fields[2],
			Options:    strings.Split(fields[3], ","),
		})
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return mounts, nil
}

// NetDevStats is one parsed interface line of /proc/net/dev.
type NetDevStats struct {
	Interface string `json:"interface"`
	RxBytes   uint64 `json:"rx_bytes"`
	RxPackets uint64 `json:"rx_packets"`
	RxErrs    uint64 `json:"rx_errs"`
	RxDrop    uint64 `json:"rx_drop"`
	TxBytes   uint64 `json:"tx_bytes"`
	TxPackets uint64 `json:"tx_packets"`
	TxErrs    uint64 `json:"tx_errs"`
	TxDrop    uint64 `json:"tx_drop"`
}

// ParseNetDev parses the contents of /proc/net/dev.
func ParseNetDev(r io.Reader) ([]NetDevStats, error) {
	var stats []NetDevStats
	scanner := bufio.NewScanner(r)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		if lineNo <= 2 {
			continue // header lines
		}
		line := scanner.Text()
		iface, rest, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) < 16 {
			return nil, fmt.Errorf("net/dev: malformed line for %q", strings.TrimSpace(iface))
		}
		parseUint := func(s string) (uint64, error) { return strconv.ParseUint(s, 10, 64) }
		s := NetDevStats{Interface: strings.TrimSpace(iface)}
		var err error
		if s.RxBytes, err = parseUint(fields[0]); err != nil {
			return nil, fmt.Errorf("net/dev: %s: rx_bytes: %w", s.Interface, err)
		}
		if s.RxPackets, err = parseUint(fields[1]); err != nil {
			return nil, fmt.Errorf("net/dev: %s: rx_packets: %w", s.Interface, err)
		}
		if s.RxErrs, err = parseUint(fields[2]); err != nil {
			return nil, fmt.Errorf("net/dev: %s: rx_errs: %w", s.Interface, err)
		}
		if s.RxDrop, err = parseUint(fields[3]); err != nil {
			return nil, fmt.Errorf("net/dev: %s: rx_drop: %w", s.Interface, err)
		}
		if s.TxBytes, err = parseUint(fields[8]); err != nil {
			return nil, fmt.Errorf("net/dev: %s: tx_bytes: %w", s.Interface, err)
		}
		if s.TxPackets, err = parseUint(fields[9]); err != nil {
			return nil, fmt.Errorf("net/dev: %s: tx_packets: %w", s.Interface, err)
		}
		if s.TxErrs, err = parseUint(fields[10]); err != nil {
			return nil, fmt.Errorf("net/dev: %s: tx_errs: %w", s.Interface, err)
		}
		if s.TxDrop, err = parseUint(fields[11]); err != nil {
			return nil, fmt.Errorf("net/dev: %s: tx_drop: %w", s.Interface, err)
		}
		stats = append(stats, s)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return stats, nil
}

// DiskStats is one parsed line of /proc/diskstats.
// Field layout: https://www.kernel.org/doc/Documentation/iostats.txt
type DiskStats struct {
	Major           int    `json:"major"`
	Minor           int    `json:"minor"`
	Device          string `json:"device"`
	ReadsCompleted  uint64 `json:"reads_completed"`
	ReadsMerged     uint64 `json:"reads_merged"`
	SectorsRead     uint64 `json:"sectors_read"`
	MsReading       uint64 `json:"ms_reading"`
	WritesCompleted uint64 `json:"writes_completed"`
	WritesMerged    uint64 `json:"writes_merged"`
	SectorsWritten  uint64 `json:"sectors_written"`
	MsWriting       uint64 `json:"ms_writing"`
}

// ParseDiskStats parses the contents of /proc/diskstats.
func ParseDiskStats(r io.Reader) ([]DiskStats, error) {
	var stats []DiskStats
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 11 {
			return nil, fmt.Errorf("diskstats: malformed line %q", line)
		}
		var d DiskStats
		var err error
		if d.Major, err = strconv.Atoi(fields[0]); err != nil {
			return nil, fmt.Errorf("diskstats: major: %w", err)
		}
		if d.Minor, err = strconv.Atoi(fields[1]); err != nil {
			return nil, fmt.Errorf("diskstats: minor: %w", err)
		}
		d.Device = fields[2]
		parseUint := func(s string) (uint64, error) { return strconv.ParseUint(s, 10, 64) }
		if d.ReadsCompleted, err = parseUint(fields[3]); err != nil {
			return nil, fmt.Errorf("diskstats: %s: reads_completed: %w", d.Device, err)
		}
		if d.ReadsMerged, err = parseUint(fields[4]); err != nil {
			return nil, fmt.Errorf("diskstats: %s: reads_merged: %w", d.Device, err)
		}
		if d.SectorsRead, err = parseUint(fields[5]); err != nil {
			return nil, fmt.Errorf("diskstats: %s: sectors_read: %w", d.Device, err)
		}
		if d.MsReading, err = parseUint(fields[6]); err != nil {
			return nil, fmt.Errorf("diskstats: %s: ms_reading: %w", d.Device, err)
		}
		if d.WritesCompleted, err = parseUint(fields[7]); err != nil {
			return nil, fmt.Errorf("diskstats: %s: writes_completed: %w", d.Device, err)
		}
		if d.WritesMerged, err = parseUint(fields[8]); err != nil {
			return nil, fmt.Errorf("diskstats: %s: writes_merged: %w", d.Device, err)
		}
		if d.SectorsWritten, err = parseUint(fields[9]); err != nil {
			return nil, fmt.Errorf("diskstats: %s: sectors_written: %w", d.Device, err)
		}
		if d.MsWriting, err = parseUint(fields[10]); err != nil {
			return nil, fmt.Errorf("diskstats: %s: ms_writing: %w", d.Device, err)
		}
		stats = append(stats, d)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return stats, nil
}
