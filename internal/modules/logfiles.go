package modules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const (
	logDefaultLines = 200
	logMaxLines     = 5000
	logMaxListFiles = 800
	logTailMaxBytes = 4 << 20 // read at most the last 4 MiB when tailing
)

// binaryLogNames are files under /var/log that are not plain text (utmp/wtmp
// databases, the binary journal) — skipped from the listing.
var binaryLogNames = map[string]bool{
	"wtmp": true, "btmp": true, "lastlog": true, "faillog": true, "tallylog": true,
}

// LogFiles lists and tails plain-text log files under /var/log (plus any
// operator-configured custom roots), strictly read-only and path-jailed to
// those roots. It complements the `journal` module so hosts that log to files
// (not only journald) are covered — and so the AI can correlate file logs with
// the eBPF/service metrics when hunting for the source of an error.
type LogFiles struct {
	// Roots is the allow-list of directories (and files) that may be listed
	// and read. /var/log is always present; extra roots come from agent config
	// and/or the per-call extra_paths param.
	Roots []string
}

// NewLogFiles builds the module with /var/log plus any configured extra roots.
func NewLogFiles(extraRoots ...string) *LogFiles {
	roots := append([]string{"/var/log"}, extraRoots...)
	return &LogFiles{Roots: roots}
}

func (m *LogFiles) Name() string { return "logfiles" }

func (m *LogFiles) Description() string {
	return "" +
		"List and tail plain-text log files under /var/log and any operator-configured custom log " +
		"paths. Read-only and path-jailed: a file can only be listed/read if it resolves to within an " +
		"allowed root (/var/log plus extra_paths), so it can never read arbitrary files like /etc/shadow.\n\n" +
		"state=list (default) enumerates the log files (path, size, modified) under the roots, skipping " +
		"the binary journal dir and utmp/wtmp-style databases. state=read tails a single file — the last " +
		"`lines` lines (default 200, capped at 5000), optionally filtered by `grep`: a plain substring, " +
		"an extended regular expression when regex=true (like grep -E), and inverted when invert=true " +
		"(keep non-matching lines, like grep -v).\n\n" +
		"Companion to the `journal` module (journald); together they give the operator a full log view " +
		"and feed the AI's error-source analysis alongside the eBPF metrics."
}

func (m *LogFiles) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"state":       stringProp(`"list" (default) enumerates log files; "read" tails one file.`),
		"path":        stringProp("For state=read: the log file to tail (must resolve within an allowed root)."),
		"lines":       map[string]any{"type": "integer", "description": fmt.Sprintf("For state=read: how many trailing lines (default %d, capped at %d).", logDefaultLines, logMaxLines)},
		"grep":        stringProp("For state=read: keep only lines matching this pattern (plain substring by default; an extended regular expression when regex=true). Like grep's PATTERN."),
		"regex":       boolProp("For state=read: interpret `grep` as an extended regular expression (like grep -E) instead of a plain substring.", false),
		"invert":      boolProp("For state=read: return the lines that do NOT match `grep` (like grep -v).", false),
		"extra_paths": stringArrayProp("Additional custom log files or directories to include (operator-configured)."),
	})
}

func (m *LogFiles) Writes() bool { return false }

func (m *LogFiles) Run(_ context.Context, params map[string]any, _ bool) (Result, error) {
	state, err := stringParam(params, "state", false, "list")
	if err != nil {
		return Result{}, err
	}
	extra, err := stringSliceParam(params, "extra_paths", false)
	if err != nil {
		return Result{}, err
	}
	roots := m.allowedRoots(extra)

	switch state {
	case "list":
		return m.list(roots)
	case "read":
		return m.read(params, roots)
	default:
		return Result{}, fmt.Errorf("state must be one of: list, read")
	}
}

// allowedRoots returns the cleaned allow-list (config roots + per-call extras).
func (m *LogFiles) allowedRoots(extra []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, r := range append(append([]string{}, m.Roots...), extra...) {
		if r == "" {
			continue
		}
		c := filepath.Clean(r)
		if !seen[c] {
			seen[c] = true
			out = append(out, c)
		}
	}
	return out
}

// withinRoots reports whether target (after symlink resolution) is inside one
// of the allowed roots — the path jail that keeps reads to the log tree.
func withinRoots(target string, roots []string) bool {
	real, err := filepath.EvalSymlinks(target)
	if err != nil {
		real = filepath.Clean(target) // non-existent: fall back to lexical
	}
	for _, root := range roots {
		rr, err := filepath.EvalSymlinks(root)
		if err != nil {
			rr = filepath.Clean(root)
		}
		if real == rr || strings.HasPrefix(real, rr+string(os.PathSeparator)) {
			return true
		}
	}
	return false
}

func (m *LogFiles) list(roots []string) (Result, error) {
	type entry struct {
		Path     string `json:"path"`
		Size     int64  `json:"size"`
		Modified int64  `json:"modified"` // unix seconds
	}
	var files []entry
	seen := map[string]bool{}
	for _, root := range roots {
		fi, err := os.Stat(root)
		if err != nil {
			continue
		}
		if !fi.IsDir() {
			if !seen[root] && !binaryLogNames[filepath.Base(root)] {
				seen[root] = true
				files = append(files, entry{root, fi.Size(), fi.ModTime().Unix()})
			}
			continue
		}
		_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				// Skip the binary systemd journal tree.
				if d.Name() == "journal" {
					return filepath.SkipDir
				}
				return nil
			}
			if !d.Type().IsRegular() || binaryLogNames[d.Name()] || seen[p] {
				return nil
			}
			info, ierr := d.Info()
			if ierr != nil {
				return nil
			}
			seen[p] = true
			files = append(files, entry{p, info.Size(), info.ModTime().Unix()})
			if len(files) >= logMaxListFiles {
				return filepath.SkipAll
			}
			return nil
		})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Modified > files[j].Modified })
	return Result{Data: map[string]any{"roots": roots, "files": files, "count": len(files)}}, nil
}

func (m *LogFiles) read(params map[string]any, roots []string) (Result, error) {
	path, err := stringParam(params, "path", true, "")
	if err != nil {
		return Result{}, err
	}
	if !withinRoots(path, roots) {
		return Result{}, fmt.Errorf("path %q is outside the allowed log roots", path)
	}
	lines, err := intParam(params, "lines", logDefaultLines)
	if err != nil {
		return Result{}, err
	}
	if lines <= 0 {
		lines = logDefaultLines
	}
	if lines > logMaxLines {
		lines = logMaxLines
	}
	grep, err := stringParam(params, "grep", false, "")
	if err != nil {
		return Result{}, err
	}
	useRegex, err := boolParam(params, "regex", false)
	if err != nil {
		return Result{}, err
	}
	invert, err := boolParam(params, "invert", false)
	if err != nil {
		return Result{}, err
	}
	// Build the line matcher once: a compiled RE2 pattern (~grep -E) or a plain
	// substring test. A bad regex is a caller error, not a module fault.
	var re *regexp.Regexp
	if grep != "" && useRegex {
		if re, err = regexp.Compile(grep); err != nil {
			return Result{}, fmt.Errorf("invalid regex %q: %w", grep, err)
		}
	}

	f, err := os.Open(path) // #nosec G304 — path is jailed to the allowed roots above
	if err != nil {
		return Result{}, fmt.Errorf("open %q: %w", path, err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return Result{}, err
	}
	// Tail: read at most the last logTailMaxBytes so a huge log can't blow up
	// memory or the wire.
	var buf []byte
	if info.Size() > logTailMaxBytes {
		buf = make([]byte, logTailMaxBytes)
		if _, err := f.ReadAt(buf, info.Size()-logTailMaxBytes); err != nil && err.Error() != "EOF" {
			return Result{}, err
		}
	} else {
		buf, err = os.ReadFile(path) // #nosec G304 — jailed above
		if err != nil {
			return Result{}, err
		}
	}
	all := strings.Split(strings.TrimRight(string(buf), "\n"), "\n")
	if grep != "" {
		filtered := all[:0]
		for _, l := range all {
			match := re != nil && re.MatchString(l) || re == nil && strings.Contains(l, grep)
			if match != invert { // invert flips the keep decision (grep -v)
				filtered = append(filtered, l)
			}
		}
		all = filtered
	}
	truncated := false
	if len(all) > lines {
		all = all[len(all)-lines:]
		truncated = true
	}
	return Result{Data: map[string]any{
		"path":      path,
		"lines":     all,
		"truncated": truncated || info.Size() > logTailMaxBytes,
		"size":      info.Size(),
		"grep":      grep,
		"regex":     useRegex,
		"invert":    invert,
	}}, nil
}
