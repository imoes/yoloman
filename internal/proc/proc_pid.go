package proc

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// PidStat is the subset of /proc/<pid>/stat we use for the process list
// (Block J1). Fields are numbered as in proc(5); we keep those needed for
// identity (pid/comm/state/ppid), CPU accounting (utime+stime, in clock
// ticks) and memory/threads.
type PidStat struct {
	PID        int    `json:"pid"`
	Comm       string `json:"comm"`
	State      string `json:"state"`
	PPID       int    `json:"ppid"`
	Utime      uint64 `json:"utime"`
	Stime      uint64 `json:"stime"`
	NumThreads int    `json:"num_threads"`
	Starttime  uint64 `json:"starttime"`
	RSSPages   int64  `json:"rss_pages"`
}

// CPUTicks is the total CPU time (user+system) this process has consumed, in
// clock ticks — the numerator for a CPU% delta against total system jiffies.
func (p PidStat) CPUTicks() uint64 { return p.Utime + p.Stime }

// ParsePidStat parses one /proc/<pid>/stat line. The comm field (field 2) is
// wrapped in parentheses and may itself contain spaces or parentheses (e.g.
// "(Web Content)"), so we split on the first '(' and the *last* ')' rather
// than on whitespace, exactly as the kernel documentation advises.
func ParsePidStat(r io.Reader) (PidStat, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return PidStat{}, err
	}
	s := strings.TrimSpace(string(data))
	open := strings.IndexByte(s, '(')
	closeIdx := strings.LastIndexByte(s, ')')
	if open < 0 || closeIdx < 0 || closeIdx < open {
		return PidStat{}, fmt.Errorf("pidstat: malformed comm field in %q", s)
	}

	var ps PidStat
	if ps.PID, err = strconv.Atoi(strings.TrimSpace(s[:open])); err != nil {
		return PidStat{}, fmt.Errorf("pidstat: pid: %w", err)
	}
	ps.Comm = s[open+1 : closeIdx]

	// After the comm, everything is whitespace-separated. rest[0] is field 3
	// (state), so proc(5) field N lives at rest[N-3].
	rest := strings.Fields(s[closeIdx+1:])
	if len(rest) < 20 {
		return PidStat{}, fmt.Errorf("pidstat: expected at least 20 trailing fields, got %d", len(rest))
	}
	ps.State = rest[0]
	if ps.PPID, err = strconv.Atoi(rest[1]); err != nil {
		return PidStat{}, fmt.Errorf("pidstat: ppid: %w", err)
	}
	if ps.Utime, err = strconv.ParseUint(rest[11], 10, 64); err != nil {
		return PidStat{}, fmt.Errorf("pidstat: utime: %w", err)
	}
	if ps.Stime, err = strconv.ParseUint(rest[12], 10, 64); err != nil {
		return PidStat{}, fmt.Errorf("pidstat: stime: %w", err)
	}
	if ps.NumThreads, err = strconv.Atoi(rest[17]); err != nil {
		return PidStat{}, fmt.Errorf("pidstat: num_threads: %w", err)
	}
	if ps.Starttime, err = strconv.ParseUint(rest[19], 10, 64); err != nil {
		return PidStat{}, fmt.Errorf("pidstat: starttime: %w", err)
	}
	// rss (field 24, pages) is optional — kernel threads may omit later fields.
	if len(rest) > 21 {
		ps.RSSPages, _ = strconv.ParseInt(rest[21], 10, 64)
	}
	return ps, nil
}

// ParseStatCPU parses /proc/stat and returns the total jiffies across all
// states from the aggregate "cpu" line (the denominator for CPU%), plus the
// number of per-core "cpuN" lines (so a process' share can be scaled to a
// familiar "100% = one core" reading, as top does).
func ParseStatCPU(r io.Reader) (total uint64, numCPU int, err error) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 0 || !strings.HasPrefix(fields[0], "cpu") {
			continue
		}
		if fields[0] == "cpu" {
			for _, f := range fields[1:] {
				v, perr := strconv.ParseUint(f, 10, 64)
				if perr != nil {
					return 0, 0, fmt.Errorf("stat: cpu field %q: %w", f, perr)
				}
				total += v
			}
		} else {
			// "cpu0", "cpu1", … — one per logical core.
			numCPU++
		}
	}
	if err = scanner.Err(); err != nil {
		return 0, 0, err
	}
	if total == 0 {
		return 0, 0, fmt.Errorf("stat: no aggregate cpu line found")
	}
	if numCPU == 0 {
		numCPU = 1
	}
	return total, numCPU, nil
}

// PidStatus is the subset of /proc/<pid>/status we use: the real UID (first
// field of the Uid line) and resident set size in kiB (VmRSS, which — unlike
// stat's rss pages — excludes swapped-out pages).
type PidStatus struct {
	UID      int   `json:"uid"`
	VmRSSKiB int64 `json:"vm_rss_kib"`
}

// ParsePidStatus parses /proc/<pid>/status. Missing lines (kernel threads
// have no VmRSS) leave their fields at zero rather than erroring.
func ParsePidStatus(r io.Reader) (PidStatus, error) {
	var st PidStatus
	st.UID = -1
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		key, rest, ok := strings.Cut(scanner.Text(), ":")
		if !ok {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		switch key {
		case "Uid":
			// "Uid:\treal\teffective\tsaved\tfs" — real uid is first.
			st.UID, _ = strconv.Atoi(fields[0])
		case "VmRSS":
			st.VmRSSKiB, _ = strconv.ParseInt(fields[0], 10, 64)
		}
	}
	if err := scanner.Err(); err != nil {
		return PidStatus{}, err
	}
	return st, nil
}

// ParseCmdline turns the NUL-separated /proc/<pid>/cmdline into a readable
// command string. An empty cmdline (kernel threads, zombies) yields "" so the
// caller can fall back to the bracketed comm.
func ParseCmdline(r io.Reader) (string, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return "", err
	}
	// Trailing NUL(s) are normal; drop them, then join arg separators with
	// spaces.
	trimmed := strings.TrimRight(string(data), "\x00")
	if trimmed == "" {
		return "", nil
	}
	return strings.ReplaceAll(trimmed, "\x00", " "), nil
}
