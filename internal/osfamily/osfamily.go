// Package osfamily is the one mapping from /etc/os-release ID / ID_LIKE to
// the coarse package family (debian | redhat | suse | arch | alpine). The
// setup module's ansible_os_family and the Starlark ctx.facts()["os_family"]
// both use it, so a module and a runbook `when:` can never disagree about
// which family a host belongs to.
package osfamily

import "strings"

var families = map[string]string{
	"debian": "debian", "ubuntu": "debian", "mint": "debian", "linuxmint": "debian", "raspbian": "debian", "pop": "debian",
	"rhel": "redhat", "centos": "redhat", "fedora": "redhat", "rocky": "redhat", "almalinux": "redhat",
	"ol": "redhat", "oracle": "redhat", "oraclelinux": "redhat",
	"suse": "suse", "opensuse": "suse", "sles": "suse", "opensuse-leap": "suse", "opensuse-tumbleweed": "suse",
	"arch": "arch", "alpine": "alpine",
}

// FromRelease returns the family for an os-release ID and ID_LIKE, or ""
// when no token is known. ID is consulted before ID_LIKE.
func FromRelease(id, idLike string) string {
	for _, t := range strings.Fields(strings.ToLower(id + " " + idLike)) {
		if f, ok := families[t]; ok {
			return f
		}
	}
	return ""
}
