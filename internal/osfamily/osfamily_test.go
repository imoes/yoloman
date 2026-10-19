package osfamily

import "testing"

func TestFromRelease(t *testing.T) {
	for _, c := range []struct{ id, like, want string }{
		{"ubuntu", "debian", "debian"},
		{"rocky", "rhel centos fedora", "redhat"},
		{"opensuse-tumbleweed", "opensuse suse", "suse"},
		{"sles", "", "suse"},
		{"arch", "", "arch"},
		{"endeavouros", "arch", "arch"},
		{"alpine", "", "alpine"},
		{"nixos", "", ""},
	} {
		if got := FromRelease(c.id, c.like); got != c.want {
			t.Errorf("FromRelease(%q, %q) = %q, want %q", c.id, c.like, got, c.want)
		}
	}
}
