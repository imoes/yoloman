package modules

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// baselineConfigPaths are core system config files no long-running daemon
// "owns" (so unit/man-page discovery misses them) but that operators still need
// to manage — decoded via their codec like any other observed config. Kept
// deliberately small; extend only for genuinely daemonless system files.
var baselineConfigPaths = []string{"/etc/fstab"}

// ConfigDiscover answers "which config files does this server actually use?"
// without hardcoding paths per package — by reading each enabled service's
// systemd unit (`systemctl cat`) and following the config files it really
// references (ExecStart -c/--config/... arguments, EnvironmentFile=, and paths
// under known config roots). This is the discovery that auto-populates the
// server-as-a-document state: point it at a host and it tells you the config
// resources worth managing. (Ported from the kb-inventory Ansible approach,
// native and live here.)
//
// Each service's unit file also names the PACKAGE that shipped it, and the
// package database says which files that package declares as configuration
// (rpm %config via `rpm -qcf`, dpkg conffiles via `dpkg-query`). That is the
// family-neutral source: RHEL images ship no man pages (tsflags=nodocs) and
// RPM packages never enable their daemon on install, so the unit/man route
// alone found nothing package-shipped on a RedHat host.
type ConfigDiscover struct {
	// Runner answers the package-database lookups; nil means the real tools.
	Runner CommandRunner
}

// NewConfigDiscover returns a ConfigDiscover module.
func NewConfigDiscover() *ConfigDiscover { return &ConfigDiscover{Runner: defaultCommandRunner} }

func (c *ConfigDiscover) Name() string { return "config_discover" }

func (c *ConfigDiscover) Description() string {
	return "" +
		"Discover the config files this host's enabled services actually use, by parsing each " +
		"service's systemd unit (systemctl cat) — the ExecStart config arguments (-c/--config/" +
		"--defaults-file/-f/…), EnvironmentFile=, and paths under known config roots — instead of " +
		"guessing per package. Returns per-service unit paths + referenced config paths (existing " +
		"files only), plus a flat, format-guessed list ready to feed the `config` module or the " +
		"server-as-a-document state. Read-only. Optional `only`: limit to these service names.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: service_facts + a `systemctl cat` loop + unit parsing (the kb-inventory method).\n" +
		"- Ties into: config (read/write the discovered files), state (manage them as a document)."
}

func (c *ConfigDiscover) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"only": map[string]any{"type": "array", "items": map[string]any{"type": "string"},
			"description": "Limit discovery to these service names (default: all enabled services)."},
	})
}

func (c *ConfigDiscover) Writes() bool { return false }

// discoveredService is one service's discovery result.
type discoveredService struct {
	Service     string   `json:"service"`
	ConfigPaths []string `json:"config_paths"`
}

func (c *ConfigDiscover) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	only := map[string]bool{}
	if raw, ok := params["only"].([]any); ok {
		for _, v := range raw {
			if s, ok := v.(string); ok {
				only[s] = true
			}
		}
	}

	services := installedServices(ctx)
	perService := []discoveredService{}
	allPaths := map[string]bool{}
	owned := map[string][]string{} // unit file → its package's declared config files (one lookup per unit)
	for _, svc := range services {
		if len(only) > 0 && !only[svc] {
			continue
		}
		unit := systemctlCat(ctx, svc)
		if unit == "" {
			continue
		}
		paths := parseUnitConfigPaths(unit)
		// Most daemons don't pass their config path on the command line — they
		// read a compiled-in default (sshd → /etc/ssh/sshd_config, chronyd →
		// /etc/chrony/chrony.conf). Mine those from the daemon's man page FILES
		// section so discovery isn't limited to what the unit declares.
		if bin := execStartBinary(unit); bin != "" {
			paths = append(paths, manConfigPaths(ctx, bin)...)
		}
		// The config files the unit's package declares (rpm %config / dpkg
		// conffiles) — the only source that works the same on both families.
		if uf := unitFilePath(unit); uf != "" {
			if _, done := owned[uf]; !done {
				owned[uf] = c.packageConfigFiles(ctx, uf)
			}
			paths = append(paths, owned[uf]...)
		}
		seen := map[string]bool{}
		existing := make([]string, 0, len(paths))
		for _, p := range paths {
			if seen[p] {
				continue
			}
			if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
				seen[p] = true
				existing = append(existing, p)
				allPaths[p] = true
			}
		}
		if len(existing) > 0 {
			sort.Strings(existing)
			perService = append(perService, discoveredService{Service: svc, ConfigPaths: existing})
		}
	}

	// Core system config files that no long-running daemon "owns", so the
	// unit/man-page discovery above never finds them, yet operators need to see
	// and edit them — /etc/fstab (read by mount at boot) is the canonical case.
	// Always included when present (and not filtered out by an explicit `only`).
	for _, p := range baselineConfigPaths {
		if len(only) > 0 && !only[p] {
			continue
		}
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			allPaths[p] = true
		}
	}

	flat := make([]map[string]any, 0, len(allPaths))
	paths := make([]string, 0, len(allPaths))
	for p := range allPaths {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		format, sep := GuessCodec(p)
		entry := map[string]any{"path": p, "format": format}
		if sep != "" {
			entry["separator"] = sep
		}
		flat = append(flat, entry)
	}

	return Result{
		Changed: false,
		Msg:     "discovered config for " + strconv.Itoa(len(perService)) + " services, " + strconv.Itoa(len(paths)) + " files",
		Data:    map[string]any{"services": perService, "config_files": flat},
	}, nil
}

// installedServices lists systemd service units in state "enabled" or
// "disabled" — installed daemons, whether or not they start at boot. Debian's
// maintainer scripts enable a daemon on install, RPM packages never do: listing
// only enabled units made a freshly installed redis/haproxy on RHEL invisible.
func installedServices(ctx context.Context) []string {
	out, err := exec.CommandContext(ctx, "systemctl", "list-unit-files", "--type=service",
		"--state=enabled,disabled", "--no-legend", "--no-pager", "--plain").Output()
	if err != nil {
		return nil
	}
	var svcs []string
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		name := strings.TrimSuffix(f[0], ".service")
		if name != "" {
			svcs = append(svcs, name)
		}
	}
	return svcs
}

// unitFilePath returns the unit's own file from `systemctl cat` output, whose
// first line is the comment "# /usr/lib/systemd/system/redis.service".
func unitFilePath(unit string) string {
	for _, line := range strings.Split(unit, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if p := strings.TrimSpace(strings.TrimPrefix(line, "#")); strings.HasPrefix(line, "#") && strings.HasPrefix(p, "/") {
			return p
		}
		return ""
	}
	return ""
}

// packageConfigFiles returns the config files the package owning file declares
// — rpm `%config` entries (`rpm -qcf`), or dpkg conffiles (`dpkg-query -S` for
// the owner, then its ${Conffiles}). Existence and config-ness are checked by
// the caller like every other candidate. Unowned file or no package manager → nil.
func (c *ConfigDiscover) packageConfigFiles(ctx context.Context, file string) []string {
	run := c.Runner
	if run == nil {
		run = defaultCommandRunner
	}
	if out, err := run(ctx, "rpm", "-qcf", file); err == nil {
		return declaredConfigPaths(string(out))
	}
	// dpkg records a usrmerged unit under its pre-merge path (/lib/systemd/…).
	candidates := []string{file}
	if strings.HasPrefix(file, "/usr/lib/") {
		candidates = append(candidates, strings.TrimPrefix(file, "/usr"))
	}
	for _, f := range candidates {
		out, err := run(ctx, "dpkg-query", "-S", f)
		if err != nil {
			continue
		}
		// "redis-server: /lib/systemd/system/redis-server.service" (or "pkg:arch: path").
		owner, _, ok := strings.Cut(strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0]), ": ")
		if !ok || strings.Contains(owner, ",") || strings.HasPrefix(owner, "diversion by") {
			continue
		}
		conf, err := run(ctx, "dpkg-query", "-W", "-f", "${Conffiles}\n", owner)
		if err != nil {
			return nil
		}
		return declaredConfigPaths(string(conf))
	}
	return nil
}

var rcDirRe = regexp.MustCompile(`^/etc/rc[0-6S]\.d/`)

// declaredConfigPaths parses a package database's config-file list — one path
// per line (rpm -qc), optionally followed by a checksum and flags (dpkg's
// " /etc/x md5 [obsolete]") — keeping current config files under /etc. Init
// scripts are conffiles to dpkg but code, not configuration.
func declaredConfigPaths(out string) []string {
	var paths []string
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) == 0 || !strings.HasPrefix(f[0], "/etc/") {
			continue
		}
		if len(f) > 2 && (f[2] == "obsolete" || f[2] == "remove-on-upgrade") {
			continue
		}
		p := f[0]
		if strings.HasPrefix(p, "/etc/init.d/") || strings.HasPrefix(p, "/etc/rc.d/") ||
			rcDirRe.MatchString(p) || !looksLikeConfig(p) {
			continue
		}
		paths = append(paths, p)
	}
	return paths
}

func systemctlCat(ctx context.Context, svc string) string {
	out, err := exec.CommandContext(ctx, "systemctl", "cat", svc).Output()
	if err != nil {
		return ""
	}
	return string(out)
}

var (
	// configPathRe: an absolute path under a config-ish root, no shell noise.
	configPathRe = regexp.MustCompile(`^/(?:etc|usr/local/etc|opt|srv)/[^\s;"'<>]+$`)
	execLineRe   = regexp.MustCompile(`(?m)^\s*Exec(?:Start|StartPre|Reload|StartPost)\s*=`)
	envFileRe    = regexp.MustCompile(`(?m)^\s*EnvironmentFile\s*=-?(.+)$`)
)

// argOptions: the flag whose following token is a config file path.
var argOptions = map[string]bool{
	"-c": true, "--config": true, "--config-file": true, "--defaults-file": true,
	"-f": true, "--file": true, "-C": true,
}

// parseUnitConfigPaths extracts the config file paths a systemd unit references:
// tokens following a config flag in an Exec* line, EnvironmentFile= values, and
// any bare absolute path under a config root. Directory/binary paths and
// non-config roots (e.g. /usr/sbin/nginx) are excluded by configPathRe.
func parseUnitConfigPaths(unit string) []string {
	found := map[string]bool{}

	for _, line := range strings.Split(unit, "\n") {
		if execLineRe.MatchString(line) {
			// take the value after the first '='
			if i := strings.Index(line, "="); i >= 0 {
				tokens := strings.Fields(line[i+1:])
				for j, raw := range tokens {
					// token after a config flag (e.g. -c /etc/nginx/nginx.conf)
					if argOptions[raw] && j+1 < len(tokens) {
						if p := strings.Trim(tokens[j+1], `"'`); configPathRe.MatchString(p) {
							found[p] = true
						}
					}
					// a bare absolute config path anywhere in the Exec line
					tok := strings.Trim(raw, `"'`)
					if configPathRe.MatchString(tok) && looksLikeConfig(tok) {
						found[tok] = true
					}
				}
			}
		}
		if m := envFileRe.FindStringSubmatch(line); m != nil {
			if p := strings.TrimSpace(strings.Trim(m[1], `"'`)); configPathRe.MatchString(p) {
				found[p] = true
			}
		}
	}

	out := make([]string, 0, len(found))
	for p := range found {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

var (
	execStartOnlyRe = regexp.MustCompile(`(?m)^\s*ExecStart\s*=`)
	manEtcPathRe    = regexp.MustCompile(`/(?:etc|usr/local/etc)/[A-Za-z0-9._+/-]+`)
	manSectionRe    = regexp.MustCompile(`^[A-Z][A-Z0-9 /_-]{1,30}$`)
)

// execStartBinary returns the basename of a unit's ExecStart executable
// (stripping systemd's @-+!: exec prefixes) — e.g. chronyd, sshd, rsyslogd —
// so we can look up that daemon's man page for its config files.
func execStartBinary(unit string) string {
	for _, line := range strings.Split(unit, "\n") {
		if !execStartOnlyRe.MatchString(line) {
			continue
		}
		i := strings.Index(line, "=")
		if i < 0 {
			continue
		}
		tokens := strings.Fields(line[i+1:])
		if len(tokens) == 0 {
			continue
		}
		return filepath.Base(strings.TrimLeft(tokens[0], "@-+!:"))
	}
	return ""
}

// manConfigPaths reads `man <name>` and returns the config file paths listed in
// its FILES section (existing regular files only). Scoping to the FILES section
// avoids the /etc/passwd-in-prose noise the whole page would otherwise bring.
// Best-effort: no `man` binary, no such page, or man-db not installed → nil.
func manConfigPaths(ctx context.Context, name string) []string {
	if _, err := exec.LookPath("man"); err != nil {
		return nil
	}
	cmd := exec.CommandContext(ctx, "man", name)
	cmd.Env = append(os.Environ(), "LC_ALL=C", "MANWIDTH=200", "PAGER=cat", "MANPAGER=cat")
	raw, err := cmd.Output()
	if err != nil {
		return nil
	}
	text := stripOverstrike(raw)
	var out []string
	seen := map[string]bool{}
	inFiles := false
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		// man section headers ("FILES", "SEE ALSO", …) sit at column 0.
		if line != "" && line[0] != ' ' && line[0] != '\t' && manSectionRe.MatchString(trimmed) {
			inFiles = trimmed == "FILES"
			continue
		}
		if !inFiles {
			continue
		}
		for _, m := range manEtcPathRe.FindAllString(line, -1) {
			p := strings.TrimRight(m, ".,;:)")
			if seen[p] || !looksLikeConfig(p) {
				continue
			}
			if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
				seen[p] = true
				out = append(out, p)
			}
		}
	}
	return out
}

// stripOverstrike removes man/groff overstrike ("X\bX" bold, "_\bX" underline),
// keeping the real character, so path regexes match clean text.
func stripOverstrike(b []byte) string {
	var sb strings.Builder
	sb.Grow(len(b))
	for i := 0; i < len(b); i++ {
		if i+1 < len(b) && b[i+1] == 0x08 {
			i++ // drop this char + the backspace; the next byte is the real one
			continue
		}
		sb.WriteByte(b[i])
	}
	return sb.String()
}

// looksLikeConfig keeps config-ish files (has a config extension or lives under
// /etc), dropping sockets/pids/runtime dirs that also match the path regex.
func looksLikeConfig(p string) bool {
	p = strings.Trim(p, `"'`)
	if !strings.HasPrefix(p, "/etc/") && !strings.Contains(p, "/etc/") {
		// allow /opt|/srv config too, but skip obvious runtime paths
		if strings.Contains(p, "/run/") || strings.HasSuffix(p, ".pid") || strings.HasSuffix(p, ".sock") {
			return false
		}
	}
	ext := strings.ToLower(filepath.Ext(p))
	switch ext {
	case ".pid", ".sock", ".log", ".pub", ".key", ".pem", ".crt", ".gpg":
		return false
	}
	// Key material a daemon's man page lists in FILES (e.g. sshd's host keys)
	// is state, not configuration — keep the config inventory focused.
	base := filepath.Base(p)
	if strings.HasSuffix(base, "_key") || strings.Contains(base, "_key.") {
		return false
	}
	return true
}

// GuessCodec is a best-effort (format, separator) hint for the config module.
// An empty format means "no clean structured codec" — read as raw / manage via
// a Class-B template. separator is only meaningful for the keyvalue format.
// It first consults the man-page-derived codec registry (config_codecs.json);
// the extension/name heuristic below is the fallback for files not in it.
func GuessCodec(p string) (format, separator string) {
	if f, sep, ok := lookupCodec(p); ok {
		return f, sep
	}
	base := strings.ToLower(filepath.Base(p))
	switch strings.ToLower(filepath.Ext(p)) {
	case ".json":
		return "json", ""
	case ".yaml", ".yml":
		return "yaml", ""
	}
	if base == "sshd_config" || base == "ssh_config" {
		return "keyvalue", " " // OpenSSH: space-separated directives
	}
	if strings.HasPrefix(p, "/etc/default/") || strings.HasPrefix(p, "/etc/sysconfig/") {
		return "keyvalue", "=" // shell KEY=value environment files
	}
	return "", "" // unknown — raw / Class-B template
}
