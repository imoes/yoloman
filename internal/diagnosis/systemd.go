package diagnosis

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Runner runs a command and returns its stdout (the same shape as modules.CommandRunner, so the agent passes its
// own runner and tests pass a fake).
type Runner func(ctx context.Context, name string, args ...string) ([]byte, error)

// SystemdSnapshot is everything the Linux rules look at — collected once, so the rules are plain functions over it
// and are tested on recorded snapshots.
type SystemdSnapshot struct {
	Unit        string            `json:"unit"`
	Show        map[string]string `json:"show"`
	ExecPath    string            `json:"exec_path"`
	ExecExists  *bool             `json:"exec_exists"`
	ExecIsExec  *bool             `json:"exec_is_executable"`
	User        string            `json:"user"`
	UserExists  *bool             `json:"user_exists"`
	Deps        []SystemdDep      `json:"deps"`
	Journal     []JournalLine     `json:"journal"`
	JournalErr  string            `json:"journal_error"`
	Files       []FileTime        `json:"files"`
	Threads     []ProcThread      `json:"threads"`
	ThreadsErr  string            `json:"threads_error"`
	Crash       *CrashFrame       `json:"crash"`
	Packages    []PackageChange   `json:"packages"`
	PackagesErr string            `json:"packages_error"`
	// RecentIncidents are PAST events for this unit's process (OOM kill, fatal signal), newest first, read from the
	// agent's eBPF incident ring (plan docs/etw-ringbuffer-plan.md). Each becomes evidence under svc.recent_incident.
	RecentIncidents []Incident `json:"recent_incidents,omitempty"`
	CollectedAt     time.Time  `json:"collected_at"`
}

// SystemdDep is a unit the target requires (Requires=/BindsTo=, recursively), with the chain that leads to it.
type SystemdDep struct {
	Unit  string            `json:"unit"`
	Via   []string          `json:"via"`
	Show  map[string]string `json:"show"`
	Depth int               `json:"depth"`
}

// JournalLine is one journal entry of the unit's current invocation.
type JournalLine struct {
	Cursor   string    `json:"cursor"`
	Time     time.Time `json:"time"`
	Message  string    `json:"message"`
	Priority int       `json:"priority"`
}

// FileTime is a file whose change may be a precedent: the unit file, its drop-ins, the program. Changed is the inode
// change time (when it changed on this host); MTime is kept as read, because for packaged files it is the build date.
type FileTime struct {
	Path    string    `json:"path"`
	Role    string    `json:"role"` // "unit file", "drop-in", "program"
	MTime   time.Time `json:"mtime"`
	Changed time.Time `json:"changed"`
}

// ProcThread is one thread of a unit's main process while it starts or stops (B14): its state letter (R running,
// S sleeping, D uninterruptible — usually I/O, T stopped, Z zombie) and the kernel function it waits in (wchan).
type ProcThread struct {
	TID   int    `json:"tid"`
	State string `json:"state"`
	Wchan string `json:"wchan"`
	Comm  string `json:"comm"`
}

// PackageChange is the last install, upgrade or removal of a package — from dpkg.log, or the rpm database's install
// time (rpm records no removals and does not tell an upgrade from an install: Action is then "install").
type PackageChange struct {
	Name   string    `json:"name"`
	Action string    `json:"action"` // dpkg.log's words: install, upgrade, remove; "unchanged" = an owner the log never mentions
	From   string    `json:"from"`
	To     string    `json:"to"`
	At     time.Time `json:"at"`
	Source string    `json:"source"` // "dpkg.log" or "rpm"
	Owner  bool      `json:"owner"`  // the package owns the unit file or the program
	Raw    string    `json:"raw"`
	// Since bounds an "unchanged" owner: dpkg.log begins here and mentions no change of the package after it.
	Since time.Time `json:"since"`
}

var showProps = []string{"LoadState", "ActiveState", "SubState", "Result", "ExecMainCode", "ExecMainStatus",
	"ExecMainExitTimestamp", "InactiveEnterTimestamp", "ActiveEnterTimestamp", "NRestarts", "InvocationID",
	"FragmentPath", "DropInPaths", "User", "UnitFileState", "Type", "ConditionResult", "AssertResult", "Requires",
	"BindsTo", "ExecStart", "ConditionTimestamp", "AssertTimestamp", "MainPID", "InactiveExitTimestamp"}

// systemctlShow reads the properties of one unit. Timestamps as unix seconds (`@1697550000`), so nothing depends on
// the host's locale or time zone.
func systemctlShow(ctx context.Context, run Runner, unit string) (map[string]string, error) {
	out, err := run(ctx, "systemctl", "show", unit, "--timestamp=unix", "-p", strings.Join(showProps, ","))
	if err != nil {
		return nil, err
	}
	props := map[string]string{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		if k, v, ok := strings.Cut(sc.Text(), "="); ok {
			props[k] = v
		}
	}
	return props, nil
}

var execPathRe = regexp.MustCompile(`path=([^ ;]+)`)

// unixTime parses systemd's `@<seconds>` form; zero for empty/unset.
func unixTime(s string) *time.Time {
	s = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(s), "@"))
	if s == "" || s == "0" || s == "n/a" {
		return nil
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n <= 0 {
		return nil
	}
	t := time.Unix(n, 0).UTC()
	return &t
}

// CollectSystemd reads the snapshot of one unit. stat is os.Stat in production (a parameter so a test can fake it).
func CollectSystemd(ctx context.Context, run Runner, stat func(string) (os.FileInfo, error), unit string,
	now time.Time) (SystemdSnapshot, error) {
	if !strings.Contains(unit, ".") {
		unit += ".service"
	}
	snap := SystemdSnapshot{Unit: unit, Deps: []SystemdDep{}, Journal: []JournalLine{}, Files: []FileTime{},
		Packages: []PackageChange{}, CollectedAt: now.UTC()}
	show, err := systemctlShow(ctx, run, unit)
	if err != nil {
		return snap, err
	}
	snap.Show = show
	if m := execPathRe.FindStringSubmatch(show["ExecStart"]); m != nil {
		snap.ExecPath = m[1]
		if fi, err := stat(m[1]); err == nil {
			yes, isExec := true, fi.Mode()&0o111 != 0
			snap.ExecExists, snap.ExecIsExec = &yes, &isExec
		} else if errors.Is(err, os.ErrNotExist) {
			no := false
			snap.ExecExists = &no
		}
	}
	if u := strings.TrimSpace(show["User"]); u != "" {
		snap.User = u
		_, err := run(ctx, "getent", "passwd", u)
		exists := err == nil
		var ee *exec.ExitError
		if err == nil || (errors.As(err, &ee) && ee.ExitCode() == 2) || strings.Contains(err.Error(), "exit status 2") {
			snap.UserExists = &exists
		}
	}
	snap.Deps = collectDeps(ctx, run, show, []string{unit}, 1, map[string]bool{unit: true})
	files := []FileTime{{Path: show["FragmentPath"], Role: "unit file"}}
	for _, p := range strings.Fields(show["DropInPaths"]) {
		files = append(files, FileTime{Path: p, Role: "drop-in"})
	}
	files = append(files, FileTime{Path: snap.ExecPath, Role: "program"})
	owned := []string{}
	for _, f := range files {
		if f.Path == "" {
			continue
		}
		if fi, err := stat(f.Path); err == nil {
			f.MTime, f.Changed = fi.ModTime().UTC().Truncate(time.Second), changedAt(fi).Truncate(time.Second)
			snap.Files = append(snap.Files, f)
			if f.Role != "drop-in" {
				owned = append(owned, f.Path)
			}
		}
	}
	failedAt := now.UTC()
	if t := endedAt(show, systemdStatusOf(show)); t != nil {
		failedAt = *t
	}
	snap.Packages, snap.PackagesErr = collectPackages(ctx, run, owned, failedAt)
	snap.Journal, snap.JournalErr = collectJournal(ctx, run, unit, show["InvocationID"])
	if result := show["Result"]; result == "core-dump" || result == "signal" {
		snap.Crash = collectCrash(ctx, run, snap.ExecPath, show["ExecMainPID"])
	}
	if st := show["ActiveState"]; (st == "activating" || st == "deactivating") && show["MainPID"] != "" && show["MainPID"] != "0" {
		snap.Threads, snap.ThreadsErr = collectThreads(ctx, run, show["MainPID"])
	}
	return snap, nil
}

const maxDepDepth = 5

func collectDeps(ctx context.Context, run Runner, show map[string]string, via []string, depth int,
	seen map[string]bool) []SystemdDep {
	out := []SystemdDep{}
	if depth > maxDepDepth {
		return out
	}
	for _, d := range append(strings.Fields(show["Requires"]), strings.Fields(show["BindsTo"])...) {
		if seen[d] {
			continue
		}
		seen[d] = true
		ds, err := systemctlShow(ctx, run, d)
		if err != nil {
			continue
		}
		out = append(out, SystemdDep{Unit: d, Via: append([]string{}, via...), Show: ds, Depth: depth})
		out = append(out, collectDeps(ctx, run, ds, append(append([]string{}, via...), d), depth+1, seen)...)
	}
	return out
}

// collectJournal reads the unit's journal and keeps the entries of the current invocation (systemd's own messages
// about the unit carry INVOCATION_ID, the daemon's carry _SYSTEMD_INVOCATION_ID). Without an invocation id, the last
// entries of the unit. The cursor becomes the evidence id, so every line is addressable.
func collectJournal(ctx context.Context, run Runner, unit, invocation string) ([]JournalLine, string) {
	out, err := run(ctx, "journalctl", "-u", unit, "-n", "60", "-o", "json", "--no-pager")
	if err != nil {
		return []JournalLine{}, err.Error()
	}
	lines := []JournalLine{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		var e map[string]any
		if json.Unmarshal(sc.Bytes(), &e) != nil {
			continue
		}
		inv, _ := e["_SYSTEMD_INVOCATION_ID"].(string)
		if inv == "" {
			inv, _ = e["INVOCATION_ID"].(string)
		}
		if invocation != "" && inv != "" && inv != invocation {
			continue
		}
		msg := journalString(e["MESSAGE"])
		cursor, _ := e["__CURSOR"].(string)
		if msg == "" || cursor == "" {
			continue
		}
		var ts time.Time
		if us, err := strconv.ParseInt(journalString(e["__REALTIME_TIMESTAMP"]), 10, 64); err == nil {
			ts = time.UnixMicro(us).UTC().Truncate(time.Second)
		}
		prio, _ := strconv.Atoi(journalString(e["PRIORITY"]))
		lines = append(lines, JournalLine{Cursor: cursor, Time: ts, Message: msg, Priority: prio})
	}
	if len(lines) > 20 {
		lines = lines[len(lines)-20:]
	}
	return lines, ""
}

// journalString reads a journal JSON field: a string, or an array of bytes for non-UTF-8 messages.
func journalString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case []any:
		b := make([]byte, 0, len(x))
		for _, c := range x {
			if f, ok := c.(float64); ok {
				b = append(b, byte(f))
			}
		}
		return string(b)
	case float64:
		return strconv.FormatInt(int64(x), 10)
	}
	return ""
}

// collectPackages reads which package owns the unit file and the program, that package's last change, and the most
// recent change of any other package at or before failedAt (within PrecedentWindow). dpkg first, then rpm; neither
// is a named reason, not an empty list.
func collectPackages(ctx context.Context, run Runner, owned []string, failedAt time.Time) ([]PackageChange, string) {
	if _, err := run(ctx, "dpkg-query", "--version"); err == nil {
		return dpkgChanges(ctx, run, owned, failedAt)
	}
	if _, err := run(ctx, "rpm", "--version"); err == nil {
		return rpmChanges(ctx, run, owned, failedAt)
	}
	return []PackageChange{}, "neither dpkg-query nor rpm answered, so package changes cannot be read on this host"
}

// keepChanges keeps the owners' last changes and the newest other change at or before failedAt, inside the window.
func keepChanges(last map[string]PackageChange, owners map[string]bool, failedAt time.Time) []PackageChange {
	out := []PackageChange{}
	var other *PackageChange
	for name, c := range last {
		if owners[name] {
			c.Owner = true
			out = append(out, c)
			continue
		}
		if c.At.After(failedAt) || failedAt.Sub(c.At) > PrecedentWindow {
			continue
		}
		if other == nil || c.At.After(other.At) || (c.At.Equal(other.At) && c.Name < other.Name) {
			cc := c
			other = &cc
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	if other != nil {
		out = append(out, *other)
	}
	return out
}

var dpkgLogRe = regexp.MustCompile(`^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (install|upgrade|remove) ([^ :]+)(?::[^ ]+)? (\S+) (\S+)$`)

func dpkgChanges(ctx context.Context, run Runner, owned []string, failedAt time.Time) ([]PackageChange, string) {
	owners := map[string]bool{}
	for _, p := range owned {
		for _, c := range dpkgCandidates(ctx, run, p) {
			if names := dpkgOwners(ctx, run, c); len(names) > 0 {
				for _, n := range names {
					owners[n] = true
				}
				break
			}
		}
	}
	// dpkg.log.1 first: logrotate keeps the previous month uncompressed (delaycompress), and the window may reach back
	// into it. A missing .1 is normal; an unreadable dpkg.log is the named reason.
	old, _ := run(ctx, "cat", "/var/log/dpkg.log.1")
	cur, err := run(ctx, "cat", "/var/log/dpkg.log")
	if err != nil {
		return []PackageChange{}, "/var/log/dpkg.log could not be read: " + clip(err.Error(), 160)
	}
	last := map[string]PackageChange{}
	var since time.Time
	for _, line := range strings.Split(string(old)+"\n"+string(cur), "\n") {
		line = strings.TrimSpace(line)
		if len(line) >= 19 && since.IsZero() {
			if t, err := time.ParseInLocation("2006-01-02 15:04:05", line[:19], time.Local); err == nil {
				since = t.UTC()
			}
		}
		m := dpkgLogRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		at, err := time.ParseInLocation("2006-01-02 15:04:05", m[1], time.Local) // dpkg.log is in local time
		if err != nil {
			continue
		}
		last[m[3]] = PackageChange{Name: m[3], Action: m[2], From: m[4], To: m[5], At: at.UTC(), Source: "dpkg.log", Raw: m[0]}
	}
	out := keepChanges(last, owners, failedAt)
	// An owner the log does not mention was installed before the log begins (a base image, a rotated-away month):
	// that is a fact with its bound, not nothing.
	for name := range owners {
		if _, ok := last[name]; !ok {
			out = append(out, PackageChange{Name: name, Action: "unchanged", Source: "dpkg.log", Owner: true, Since: since})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { // owners by name, then the one other change
		if out[i].Owner != out[j].Owner {
			return out[i].Owner
		}
		return out[i].Owner && out[i].Name < out[j].Name
	})
	return out, ""
}

// dpkgCandidates are the names dpkg may know a path under: as written, merged into /usr (trixie's database lists
// /usr/bin/sh, not /bin/sh — measured in the debian-trixie image), and the symlink target.
func dpkgCandidates(ctx context.Context, run Runner, p string) []string {
	c := []string{p}
	for _, pre := range []string{"/bin/", "/sbin/", "/lib/", "/lib64/"} {
		if strings.HasPrefix(p, pre) {
			c = append(c, "/usr"+p)
		}
	}
	if out, err := run(ctx, "readlink", "-f", p); err == nil {
		if r := strings.TrimSpace(string(out)); r != "" && r != p {
			c = append(c, r)
		}
	}
	return c
}

// dpkgOwners parses `dpkg-query -S` ("pkg:arch, pkg2: /path"); none when no package owns the path (exit 1).
func dpkgOwners(ctx context.Context, run Runner, p string) []string {
	out, _ := run(ctx, "dpkg-query", "-S", p)
	var names []string
	for _, line := range strings.Split(string(out), "\n") {
		left, right, ok := strings.Cut(line, ": ")
		if !ok || strings.TrimSpace(right) != p || strings.HasPrefix(left, "diversion by") {
			continue
		}
		for _, name := range strings.Split(left, ", ") {
			name, _, _ = strings.Cut(strings.TrimSpace(name), ":")
			names = append(names, name)
		}
	}
	return names
}

func rpmChanges(ctx context.Context, run Runner, owned []string, failedAt time.Time) ([]PackageChange, string) {
	owners := map[string]bool{}
	for _, p := range owned {
		out, err := run(ctx, "rpm", "-qf", "--qf", "%{NAME}\n", p)
		if err != nil {
			continue // "file … is not owned by any package"
		}
		for _, name := range strings.Fields(string(out)) {
			owners[name] = true
		}
	}
	out, err := run(ctx, "rpm", "-qa", "--qf", "%{INSTALLTIME} %{NAME} %{VERSION}-%{RELEASE}\n")
	if err != nil {
		return []PackageChange{}, "rpm -qa failed: " + clip(err.Error(), 160)
	}
	last := map[string]PackageChange{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) != 3 {
			continue
		}
		sec, err := strconv.ParseInt(f[0], 10, 64)
		if err != nil {
			continue
		}
		at := time.Unix(sec, 0).UTC()
		if prev, ok := last[f[1]]; !ok || at.After(prev.At) {
			last[f[1]] = PackageChange{Name: f[1], Action: "install", To: f[2], At: at, Source: "rpm", Raw: line}
		}
	}
	return keepChanges(last, owners, failedAt), ""
}

// collectThreads reads, for every thread of pid, the state letter and the kernel wait channel from /proc — what a
// starting or stopping unit is doing right now, without attaching a debugger or reading its memory.
func collectThreads(ctx context.Context, run Runner, pid string) ([]ProcThread, string) {
	if _, err := strconv.Atoi(pid); err != nil {
		return []ProcThread{}, "MainPID is not a number: " + pid
	}
	out, err := run(ctx, "sh", "-c", `for t in /proc/`+pid+`/task/*; do id=${t##*/}; st=$(cut -d')' -f2 "$t/stat" 2>/dev/null | awk '{print $1}'); wc=$(cat "$t/wchan" 2>/dev/null); cm=$(cat "$t/comm" 2>/dev/null); echo "$id ${st:--} ${wc:-0} $cm"; done`)
	if err != nil {
		return []ProcThread{}, "reading /proc/" + pid + "/task failed: " + clip(err.Error(), 160)
	}
	threads := []ProcThread{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.SplitN(line, " ", 4)
		if len(f) < 3 {
			continue
		}
		tid, err := strconv.Atoi(f[0])
		if err != nil {
			continue
		}
		th := ProcThread{TID: tid, State: f[1], Wchan: f[2]}
		if len(f) == 4 {
			th.Comm = f[3]
		}
		threads = append(threads, th)
	}
	if len(threads) == 0 {
		return threads, "no thread of process " + pid + " could be read (it ended, or /proc is not visible to the agent)"
	}
	return threads, ""
}

// collectCrash finds the kernel's fault line for the unit's program and resolves it to a function (plan B14). The
// kernel logs "<comm>[<pid>]: segfault at …" / "traps: …" when a user process dies on a fault; dmesg -t carries them
// without needing a core dump. debuginfodURL (settings/env) is where the module's debug symbols are fetched by build id.
func collectCrash(ctx context.Context, run Runner, execPath, mainPID string) *CrashFrame {
	out, err := run(ctx, "dmesg", "-t", "--level=info,warn,err")
	if err != nil {
		out, err = run(ctx, "sh", "-c", "journalctl -k -o cat --since -1h 2>/dev/null")
		if err != nil {
			return &CrashFrame{Gap: "the kernel log could not be read (dmesg and journalctl -k both failed): " + clip(err.Error(), 160)}
		}
	}
	comm := ""
	if execPath != "" {
		comm = filepath.Base(execPath)
	}
	var frame *CrashFrame
	for _, line := range strings.Split(string(out), "\n") {
		if cf, ok := ParseKernelCrash(line); ok {
			// the newest line for this program (comm is truncated to 15 chars in the kernel, so match on a prefix)
			if comm == "" || strings.HasPrefix(comm, cf.Comm) || strings.HasPrefix(cf.Comm, comm) {
				c := cf
				frame = &c
			}
		}
	}
	if frame == nil {
		return &CrashFrame{Gap: "the service crashed, but no matching kernel fault line was found (the kernel log rotated, " +
			"or the agent may not read it) — Result says a signal/core-dump, the location is not recoverable from what remains"}
	}
	module := frame.Module
	if !strings.HasPrefix(module, "/") {
		// the kernel names the mapped file by basename for the main binary; the ExecStart path is the full one
		if execPath != "" && filepath.Base(execPath) == module {
			module = execPath
		}
	}
	Symbolize(frame, module, debuginfodFetch(ctx, run))
	return frame
}

// debuginfodFetch asks a debuginfod server for a build id's debug file, via the debuginfod-find tool when present
// (it honours DEBUGINFOD_URLS and caches), else nil — then only local and the module's own symbols are tried.
func debuginfodFetch(ctx context.Context, run Runner) FetchDebug {
	if _, err := run(ctx, "sh", "-c", "command -v debuginfod-find"); err != nil {
		return nil
	}
	return func(buildID string) (string, error) {
		out, err := run(ctx, "debuginfod-find", "debuginfo", buildID)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(out)), nil
	}
}
