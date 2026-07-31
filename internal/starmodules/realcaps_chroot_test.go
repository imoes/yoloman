package starmodules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Chroot mode configures a system mounted somewhere else — the offline pass that lets a machine be
// installed and fully configured before its single reboot. Every test here pins a way that mode can
// silently do the wrong thing rather than fail.

func TestChrootRefusesAReadOnlyModule(t *testing.T) {
	// The central rule: a reading module in a chroot answers about the HELPER — its kernel, its
	// memory, its running services. It would report plausible, confident, wrong values and nothing
	// downstream could tell, so the mode refuses it outright.
	_, err := NewChrootCaps(false, true, false, "/mnt/target")
	if err == nil {
		t.Fatal("a writes:false module must be refused in chroot mode")
	}
	if !strings.Contains(err.Error(), "read-only") {
		t.Fatalf("the refusal should say why, got %v", err)
	}
}

func TestChrootNeedsARealTargetRoot(t *testing.T) {
	// "/" would mean "configure the helper itself", which is the opposite of the intent.
	for _, root := range []string{"", "/", "."} {
		if _, err := NewChrootCaps(false, true, true, root); err == nil {
			t.Fatalf("target root %q must be refused", root)
		}
	}
}

func TestChrootPathsResolveUnderTheTargetAndCannotEscape(t *testing.T) {
	c, err := NewChrootCaps(false, true, true, "/mnt/target")
	if err != nil {
		t.Fatal(err)
	}
	got, err := c.resolve("/etc/hostname")
	if err != nil || got != "/mnt/target/etc/hostname" {
		t.Fatalf("resolve = %q, %v", got, err)
	}
	// ".." is CLAMPED at the root, exactly as a real chroot clamps it — the kernel does not let you
	// climb out of a chroot with "..", and filepath.Clean resolves it against "/" the same way. So
	// these are not escapes but ordinary paths inside the target, and asserting an error here (my
	// first version of this test did) would have been asserting the wrong semantics.
	for path, want := range map[string]string{
		"/../etc/shadow":                        "/etc/shadow",
		"/etc/../../root/.ssh/authorized_keys":  "/root/.ssh/authorized_keys",
	} {
		got, err := c.resolve(path)
		if err != nil {
			t.Fatalf("resolve(%q) failed: %v", path, err)
		}
		if got != filepath.Join("/mnt/target", want) {
			t.Fatalf("resolve(%q) = %q, want it clamped to %q", path, got, want)
		}
	}
	if _, err := c.resolve("relative/path"); err == nil {
		t.Fatal("a relative path is ambiguous in chroot mode and must be refused")
	}
}

func TestChrootWrapsCommandsAndKeepsSystemctlOffline(t *testing.T) {
	c, _ := NewChrootCaps(false, true, true, "/mnt/target")

	got := c.chrootArgv([]string{"apt-get", "install", "-y", "nginx"})
	want := []string{"chroot", "/mnt/target", "apt-get", "install", "-y", "nginx"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("got %v", got)
	}

	// There is no init inside the chroot: `enable` works offline, `start` cannot work at all.
	got = c.chrootArgv([]string{"systemctl", "enable", "nginx"})
	if strings.Join(got, " ") != "systemctl --root=/mnt/target enable nginx" {
		t.Fatalf("systemctl enable should be rewritten offline, got %v", got)
	}
	// `start` is deliberately NOT rewritten — it fails loudly inside the chroot instead of looking
	// like it worked.
	got = c.chrootArgv([]string{"systemctl", "start", "nginx"})
	if got[0] != "chroot" {
		t.Fatalf("systemctl start should not be given --root, got %v", got)
	}
}

func TestWithoutChrootNothingChanges(t *testing.T) {
	c := NewRealCaps(false, true, true)
	if c.InChroot() {
		t.Fatal("a plain backend must not claim to be in a chroot")
	}
	argv := []string{"systemctl", "enable", "nginx"}
	if strings.Join(c.chrootArgv(argv), " ") != strings.Join(argv, " ") {
		t.Fatal("argv must be untouched outside chroot mode")
	}
	if got, _ := c.resolve("/etc/hostname"); got != "/etc/hostname" {
		t.Fatalf("paths must be untouched outside chroot mode, got %q", got)
	}
}

func TestChrootFactsDescribeTheTargetAndAdmitWhatTheyCannotKnow(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	osRelease := "ID=debian\nVERSION_ID=\"12\"\nVERSION_CODENAME=bookworm\n"
	if err := os.WriteFile(filepath.Join(root, "etc/os-release"), []byte(osRelease), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc/hostname"), []byte("web07\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := NewChrootCaps(false, true, true, root)
	if err != nil {
		t.Fatal(err)
	}
	facts, err := c.Facts()
	if err != nil {
		t.Fatal(err)
	}
	if facts["distribution"] != "debian" || facts["hostname"] != "web07" {
		t.Fatalf("facts must describe the TARGET, got %v", facts)
	}
	// The running kernel belongs to the helper, and the target's is not booted. Empty is something a
	// module can notice; the helper's version would be silently wrong.
	if facts["kernel"] != "" {
		t.Fatalf("kernel must not be reported in chroot mode, got %q", facts["kernel"])
	}
	if facts["chroot"] != true {
		t.Fatal("facts should say the module is running against another root")
	}
}

func TestChrootFileWriteLandsInsideTheTarget(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	c, err := NewChrootCaps(false, true, true, root)
	if err != nil {
		t.Fatal(err)
	}
	changed, err := c.FileWrite("/etc/hostname", "web07\n", "0644")
	if err != nil || !changed {
		t.Fatalf("write failed: %v (changed=%v)", err, changed)
	}
	b, err := os.ReadFile(filepath.Join(root, "etc/hostname"))
	if err != nil || string(b) != "web07\n" {
		t.Fatalf("the file did not land in the target: %v %q", err, b)
	}
	// And it must be readable back through the same mapping.
	if got, err := c.FileRead("/etc/hostname"); err != nil || got != "web07\n" {
		t.Fatalf("read back gave %q, %v", got, err)
	}
	if ok, _ := c.FileExists("/etc/hostname"); !ok {
		t.Fatal("file_exists must see it too")
	}
}

// The reserved parameter, tested through StarModule.Run — the path Bossman actually takes. Using a
// param instead of a new endpoint means the REST and MCP surfaces need no change at all, so this is
// where the feature is either wired up or it is not.

func TestTargetRootParamWritesIntoTheTarget(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &StarModule{
		fqcn: "test.chroot.writer", shortName: "writer", writes: true, agentWrite: true,
		options: map[string]any{},
		src: []byte(`
def main(ctx, params):
    ctx.file_write("/etc/motd", "installed offline\n", mode="0644")
    return {"changed": True, "msg": "wrote motd"}
`),
	}
	res, err := m.Run(context.Background(), map[string]any{TargetRootParam: root}, false)
	if err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if !res.Changed {
		t.Fatal("the module should report a change")
	}
	// The decisive assertion: it landed in the TARGET, not on the machine running the agent.
	b, err := os.ReadFile(filepath.Join(root, "etc/motd"))
	if err != nil || string(b) != "installed offline\n" {
		t.Fatalf("not written into the target: %v %q", err, b)
	}
}

func TestTargetRootParamRefusesAReadOnlyModule(t *testing.T) {
	// The gate has to hold on the real path too, not just in the constructor: a check asked to run
	// against a chroot would otherwise report the helper's state as the target's.
	m := &StarModule{
		fqcn: "test.chroot.reader", shortName: "reader", writes: false, agentWrite: true,
		options: map[string]any{},
		src:     []byte("def main(ctx, params):\n    return {\"state\": \"OK\"}\n"),
	}
	_, err := m.Run(context.Background(), map[string]any{TargetRootParam: t.TempDir()}, false)
	if err == nil {
		t.Fatal("a writes:false module must not run against a chroot")
	}
	if !strings.Contains(err.Error(), "read-only") {
		t.Fatalf("the error should explain why, got %v", err)
	}
}

func TestWithoutTheParamNothingIsRedirected(t *testing.T) {
	// Every existing invocation has to behave exactly as before — the param is absent, so the
	// module writes where it always did.
	dir := t.TempDir()
	target := filepath.Join(dir, "plain.txt")
	m := &StarModule{
		fqcn: "test.plain", shortName: "plain", writes: true, agentWrite: true,
		options: map[string]any{},
		src: []byte("def main(ctx, params):\n" +
			"    ctx.file_write(params[\"path\"], \"x\", mode=\"0644\")\n" +
			"    return {\"changed\": True, \"msg\": \"wrote\"}\n"),
	}
	if _, err := m.Run(context.Background(), map[string]any{"path": target}, false); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("the plain path should have been used verbatim: %v", err)
	}
}

func TestAnEmptyTargetRootIsTreatedAsAbsent(t *testing.T) {
	// A caller threading an empty string through (a template variable that resolved to nothing)
	// must get normal behaviour, not a confusing "target root must not be \"\"" failure.
	c, err := capsFor(false, true, true, map[string]any{TargetRootParam: "   "})
	if err != nil {
		t.Fatalf("an empty target root should mean 'not set', got %v", err)
	}
	if c.InChroot() {
		t.Fatal("whitespace must not enable chroot mode")
	}
}
