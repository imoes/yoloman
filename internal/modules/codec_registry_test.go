package modules

import "testing"

func TestDropinService(t *testing.T) {
	cases := map[string]string{
		"/etc/nginx/conf.d/app.conf": "nginx",
		"/etc/sysctl.d/99-x.conf":    "sysctl",
		"/etc/sudoers.d/admins":      "sudoers",
		"/etc/modprobe.d/blk.conf":   "modprobe",
		"/etc/ssh/sshd_config":       "", // not a drop-in
	}
	for path, want := range cases {
		if got := dropinService(path); got != want {
			t.Errorf("dropinService(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestLookupCodecWellKnownDirs(t *testing.T) {
	for _, p := range []string{"/etc/default/grub", "/etc/sysconfig/network"} {
		f, sep, ok := lookupCodec(p)
		if !ok || f != "keyvalue" || sep != "=" {
			t.Errorf("lookupCodec(%q) = (%q,%q,%v), want keyvalue = true", p, f, sep, ok)
		}
	}
	if _, _, ok := lookupCodec("/etc/some/unknown.thing"); ok {
		t.Error("unknown path should not resolve from the registry")
	}
}
