package modules

import (
	"bufio"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/mutkluge/agentic-mcp/internal/proc"
)

// Setup gathers system facts, mirroring ansible.builtin.setup's well-known
// fact names (ansible_hostname, ansible_kernel, ...). Its data sources are
// injectable so it can be tested without touching the real host.
type Setup struct {
	ProcRoot      string
	OSReleasePath string
	Architecture  string
	HostnameFunc  func() (string, error)
	// DMIRoot is /sys/class/dmi/id on a real host — the SMBIOS/DMI facts
	// (motherboard vendor, product, serial, BIOS) so runbooks can key on
	// hardware the way Ansible's ansible_board_*/ansible_product_* facts do.
	DMIRoot string
}

// NewSetup returns a Setup module reading from the real host: /proc,
// /etc/os-release, os.Hostname, and the Go runtime's GOARCH mapped to the
// uname-style name (e.g. "amd64" -> "x86_64").
func NewSetup() *Setup {
	return &Setup{
		ProcRoot:      "/proc",
		OSReleasePath: "/etc/os-release",
		Architecture:  unameArch(runtime.GOARCH),
		HostnameFunc:  os.Hostname,
		DMIRoot:       "/sys/class/dmi/id",
	}
}

// dmiFacts maps ansible_* fact names to their /sys/class/dmi/id file.
var dmiFacts = map[string]string{
	"ansible_board_vendor":   "board_vendor",
	"ansible_board_name":     "board_name",
	"ansible_board_serial":   "board_serial",
	"ansible_product_name":   "product_name",
	"ansible_product_serial": "product_serial",
	"ansible_product_uuid":   "product_uuid",
	"ansible_system_vendor":  "sys_vendor",
	"ansible_bios_vendor":    "bios_vendor",
	"ansible_bios_version":   "bios_version",
	"ansible_chassis_vendor": "chassis_vendor",
}

func (s *Setup) Name() string { return "setup" }

func (s *Setup) Description() string {
	return "" +
		"Gather baseline facts about this host: hostname, kernel release, CPU architecture, " +
		"Linux distribution/version, total memory (MB), and logical CPU count. Takes no " +
		"parameters. Call this first when reconciling any desired-state description against " +
		"a real machine — it is the starting point for the 'read current state' step before " +
		"planning changes.\n\n" +
		"Cross-tool equivalents (use this mapping to translate other formats into agentic-mcp calls):\n" +
		"- Ansible: ansible.builtin.setup / the automatic 'gather_facts' step at play start. " +
		"Native keys use the yoloman_ prefix (yoloman_hostname, yoloman_kernel, " +
		"yoloman_architecture, yoloman_distribution, yoloman_distribution_version, " +
		"yoloman_memtotal_mb, yoloman_processor_vcpus); the ansible_ keys are also " +
		"returned as compat aliases for imported Ansible content.\n" +
		"- Chef: the automatic Ohai run that populates node attributes (node['hostname'], " +
		"node['kernel'], node['platform'], node['platform_version'], node['memory']['total'], " +
		"node['cpu']['total']).\n" +
		"- Puppet: Facter facts available as top-scope variables ($facts['networking']['hostname'], " +
		"$facts['kernelrelease'], $facts['os']['name'], $facts['os']['release']['full'], " +
		"$facts['memory']['system']['total'], $facts['processors']['count']).\n" +
		"- Salt: grains (grains['host'], grains['kernelrelease'], grains['os'], grains['osrelease'], " +
		"grains['mem_total'], grains['num_cpus']).\n" +
		"- Terraform: has no direct remote-facts equivalent (Terraform is declarative and provider-" +
		"driven); the closest analogues are a provider's computed data source attributes or an " +
		"`external`/`http` data source that shells out to gather machine facts before apply."
}

func (s *Setup) InputSchema() map[string]any {
	return objectSchema(map[string]any{})
}

func (s *Setup) Writes() bool { return false }

func (s *Setup) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	facts := map[string]any{}

	if s.HostnameFunc != nil {
		if hostname, err := s.HostnameFunc(); err == nil {
			facts["ansible_hostname"] = hostname
		}
	}

	if s.Architecture != "" {
		facts["ansible_architecture"] = s.Architecture
	}

	if release, err := readFirstLine(filepath.Join(s.ProcRoot, "sys/kernel/osrelease")); err == nil {
		facts["ansible_kernel"] = release
	}

	if osrel, err := parseOSRelease(s.OSReleasePath); err == nil {
		facts["ansible_distribution"] = osrel["NAME"]
		facts["ansible_distribution_version"] = osrel["VERSION_ID"]
		// os_family — normalise ID/ID_LIKE into debian|redhat|... so runbook
		// `when:` clauses can branch on the package family without string-matching
		// the pretty NAME.
		facts["ansible_os_family"] = osFamilyFromRelease(osrel["ID"], osrel["ID_LIKE"])
	}

	if f, err := os.Open(filepath.Join(s.ProcRoot, "meminfo")); err == nil {
		mi, parseErr := proc.ParseMemInfo(f)
		f.Close()
		if parseErr == nil {
			facts["ansible_memtotal_mb"] = mi["MemTotal"] / 1024
		}
	}

	if f, err := os.Open(filepath.Join(s.ProcRoot, "cpuinfo")); err == nil {
		cpus, parseErr := proc.ParseCPUInfo(f)
		f.Close()
		if parseErr == nil {
			facts["ansible_processor_vcpus"] = len(cpus)
		}
	}

	// DMI/SMBIOS facts (best-effort; unreadable on VMs/containers or without
	// privilege — a missing file just omits that fact, never an error).
	if s.DMIRoot != "" {
		for factName, file := range dmiFacts {
			if v, err := readFirstLine(filepath.Join(s.DMIRoot, file)); err == nil && v != "" {
				facts[factName] = v
			}
		}
	}

	// Three names for every fact, because three things need to resolve:
	//
	//   ansible_distribution              flat, Ansible <2.5 style — what we already emitted
	//   ansible_facts['distribution']     the MODERN Ansible form; this is what imported roles use
	//   yoloman_distribution              our native prefix
	//
	// The nested `ansible_facts` dict was missing, so an imported role templating
	// `{{ ansible_facts['distribution'] }}` failed against a StrictUndefined engine even though we had the
	// value under two other names. Ansible-task syntax is the only authoring format now and importing
	// upstream roles is a headline promise, so the form those roles actually use has to work.
	nested := make(map[string]any, len(facts))
	for k, v := range facts {
		if strings.HasPrefix(k, "ansible_") {
			bare := strings.TrimPrefix(k, "ansible_")
			facts["yoloman_"+bare] = v
			nested[bare] = v
		}
	}
	facts["ansible_facts"] = nested

	return Result{Changed: false, Data: facts}, nil
}

// unameArch maps a Go GOARCH value to its traditional `uname -m` name, so
// gathered facts match what ansible_architecture would normally contain.
func unameArch(goarch string) string {
	switch goarch {
	case "amd64":
		return "x86_64"
	case "arm64":
		return "aarch64"
	case "386":
		return "i686"
	default:
		return goarch
	}
}

// readFirstLine returns the first line of path with surrounding whitespace
// trimmed (e.g. for single-value pseudo-files like /proc/sys/kernel/osrelease).
func readFirstLine(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	if scanner.Scan() {
		return strings.TrimSpace(scanner.Text()), nil
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", nil
}

// osFamilyFromRelease maps an os-release ID / ID_LIKE into a coarse package
// family (debian | redhat | suse | arch | alpine), or "" when unknown.
func osFamilyFromRelease(id, idLike string) string {
	tokens := strings.Fields(strings.ToLower(id + " " + idLike))
	fam := map[string]string{
		"debian": "debian", "ubuntu": "debian", "mint": "debian", "raspbian": "debian", "pop": "debian",
		"rhel": "redhat", "centos": "redhat", "fedora": "redhat", "rocky": "redhat", "almalinux": "redhat",
		"ol": "redhat", "oracle": "redhat",
		"suse": "suse", "opensuse": "suse", "sles": "suse",
		"arch": "arch", "alpine": "alpine",
	}
	for _, t := range tokens {
		if f, ok := fam[t]; ok {
			return f
		}
	}
	return ""
}

// parseOSRelease parses a /etc/os-release-style file (KEY=VALUE per line,
// values optionally double-quoted) into a plain string map.
func parseOSRelease(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	fields := map[string]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		val = strings.Trim(val, `"`)
		fields[key] = val
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return fields, nil
}
