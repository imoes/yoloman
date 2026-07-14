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

// ConfigDiscover answers "which config files does this server actually use?"
// without hardcoding paths per package — by reading each enabled service's
// systemd unit (`systemctl cat`) and following the config files it really
// references (ExecStart -c/--config/... arguments, EnvironmentFile=, and paths
// under known config roots). This is the discovery that auto-populates the
// server-as-a-document state: point it at a host and it tells you the config
// resources worth managing. (Ported from the kb-inventory Ansible approach,
// native and live here.)
type ConfigDiscover struct{}

// NewConfigDiscover returns a ConfigDiscover module.
func NewConfigDiscover() *ConfigDiscover { return &ConfigDiscover{} }

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

	services := enabledServices(ctx)
	perService := []discoveredService{}
	allPaths := map[string]bool{}
	for _, svc := range services {
		if len(only) > 0 && !only[svc] {
			continue
		}
		unit := systemctlCat(ctx, svc)
		if unit == "" {
			continue
		}
		paths := parseUnitConfigPaths(unit)
		existing := make([]string, 0, len(paths))
		for _, p := range paths {
			if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
				existing = append(existing, p)
				allPaths[p] = true
			}
		}
		if len(existing) > 0 {
			sort.Strings(existing)
			perService = append(perService, discoveredService{Service: svc, ConfigPaths: existing})
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

// enabledServices lists systemd service units in state "enabled".
func enabledServices(ctx context.Context) []string {
	out, err := exec.CommandContext(ctx, "systemctl", "list-unit-files", "--type=service",
		"--state=enabled", "--no-legend", "--no-pager", "--plain").Output()
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
	case ".pid", ".sock", ".log":
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
