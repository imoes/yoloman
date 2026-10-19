package modules

import (
	"strings"
	"testing"
)

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

// A file of another release of the same package finds the codec measured on the recorded release.
func TestLookupCodec_AnotherVersionOfTheSamePath(t *testing.T) {
	var key string
	for k, s := range codecRegistry {
		if strings.HasPrefix(k, "/etc/java/java-21-openjdk/java-21-openjdk-21.") && strings.HasSuffix(k, "/conf/net.properties") && s.Codec != "none" {
			key = k
		}
	}
	if key == "" {
		t.Skip("no versioned java entry in the registry")
	}
	newer := digitRun.ReplaceAllStringFunc(key, func(d string) string { return d + "9" })
	if newer == key {
		t.Fatal("test path did not change")
	}
	got, _, ok := lookupCodec(newer)
	want := codecRegistry[key].Codec
	if !ok || got != want {
		t.Errorf("lookupCodec(%s) = %q,%v; want %q (from %s)", newer, got, ok, want, key)
	}
}
