package diagnosis

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func fakeRun(byCmd map[string]string) Runner {
	return func(_ context.Context, name string, _ ...string) ([]byte, error) {
		if out, ok := byCmd[name]; ok {
			return []byte(out), nil
		}
		return nil, nil
	}
}

func TestUpdateRemedyUsesASnapshotRollbackWhenPossible(t *testing.T) {
	// LVM root → upd.behind carries a remedy whose rollback restores an LVM snapshot.
	d := diagnoseUpdates(t, updSnap(func(s *UpdateSnapshot) {
		s.Upgradable = []UpgradablePkg{{Name: "bash"}}
		s.SnapshotTarget = SnapshotTarget{Kind: "lvm", ID: "vg0/root", Layout: "thick"}
	}))
	f := hasRule(d, "upd.behind")
	if f == nil || f.Remedy == nil {
		t.Fatalf("behind should carry a remedy on LVM: %+v", f)
	}
	if f.Remedy.Action != "install" || f.Remedy.Rollback.Action != "restore" {
		t.Fatalf("remedy actions: %+v", f.Remedy)
	}
	rb, _ := json.Marshal(f.Remedy.Rollback.Value)
	if !strings.Contains(string(rb), "lvconvert --merge vg0/root-preupdate") {
		t.Fatalf("rollback should merge the snapshot: %s", rb)
	}

	// ZFS root → zfs rollback.
	d = diagnoseUpdates(t, updSnap(func(s *UpdateSnapshot) {
		s.Upgradable = []UpgradablePkg{{Name: "bash"}}
		s.SnapshotTarget = SnapshotTarget{Kind: "zfs", ID: "rpool/ROOT/deb"}
	}))
	rb, _ = json.Marshal(hasRule(d, "upd.behind").Remedy.Rollback.Value)
	if !strings.Contains(string(rb), "zfs rollback rpool/ROOT/deb@preupdate") {
		t.Fatalf("zfs rollback: %s", rb)
	}

	// No snapshot-capable volume → no remedy, and a named gap instead of a fake rollback.
	d = diagnoseUpdates(t, updSnap(func(s *UpdateSnapshot) {
		s.Upgradable = []UpgradablePkg{{Name: "bash"}}
		s.SnapshotTarget = SnapshotTarget{Kind: "none", Reason: "/ is on /dev/sda1 (ext4), not a snapshot-capable volume"}
	}))
	if f := hasRule(d, "upd.behind"); f == nil || f.Remedy != nil {
		t.Fatalf("no remedy without a snapshot volume: %+v", f)
	}
	if len(d.Gaps) == 0 {
		t.Fatalf("a missing rollback point should be a named gap")
	}
}

func TestDetectSnapshotTarget(t *testing.T) {
	zfs := detectSnapshotTarget(context.Background(), fakeRun(map[string]string{"findmnt": "rpool/ROOT/deb zfs\n"}))
	if zfs.Kind != "zfs" || zfs.ID != "rpool/ROOT/deb" {
		t.Fatalf("zfs: %+v", zfs)
	}
	thick := detectSnapshotTarget(context.Background(), fakeRun(map[string]string{
		"findmnt": "/dev/mapper/vg0-root ext4\n", "lvs": "  vg0 root linear\n"}))
	if thick.Kind != "lvm" || thick.ID != "vg0/root" || thick.Layout != "thick" {
		t.Fatalf("lvm thick: %+v", thick)
	}
	thin := detectSnapshotTarget(context.Background(), fakeRun(map[string]string{
		"findmnt": "/dev/mapper/vg0-root ext4\n", "lvs": "  vg0 root thin,sparse\n"}))
	if thin.Layout != "thin" {
		t.Fatalf("lvm thin: %+v", thin)
	}
	plain := detectSnapshotTarget(context.Background(), fakeRun(map[string]string{"findmnt": "/dev/sda1 ext4\n"}))
	if plain.Kind != "none" || !strings.Contains(plain.Reason, "not a snapshot-capable volume") {
		t.Fatalf("plain: %+v", plain)
	}
}

var u0 = time.Date(2026, 10, 18, 16, 0, 0, 0, time.UTC)

func diagnoseUpdates(t *testing.T, s UpdateSnapshot) *Diagnosis {
	t.Helper()
	d, err := DiagnoseUpdates(s, "test", s.Host)
	if err != nil {
		t.Fatalf("DiagnoseUpdates: %v", err)
	}
	out, _ := json.Marshal(d)
	if err := resolvedSchema(t).Validate(generic(t, out)); err != nil {
		t.Fatalf("schema: %v\n%s", err, out)
	}
	return d
}

func updSnap(mod func(*UpdateSnapshot)) UpdateSnapshot {
	s := UpdateSnapshot{Host: "deb01", Family: "debian", Manager: "apt", CollectedAt: u0}
	if mod != nil {
		mod(&s)
	}
	return s
}

func hasRule(d *Diagnosis, rule string) *Finding {
	for i := range d.Findings {
		if d.Findings[i].RuleID == rule {
			return &d.Findings[i]
		}
	}
	return nil
}

func TestUpdateRulesLinux(t *testing.T) {
	// up-to-date
	d := diagnoseUpdates(t, updSnap(nil))
	if d.Status != StatusUpToDate || len(d.Findings) == 0 || d.Findings[0].RuleID != "upd.up_to_date" {
		t.Fatalf("up-to-date: %s %v", d.Status, rules(d))
	}

	// behind, with a security count
	d = diagnoseUpdates(t, updSnap(func(s *UpdateSnapshot) {
		s.Upgradable = []UpgradablePkg{{Name: "libc6", Security: true}, {Name: "bash"}}
		s.SecurityCount = 1
	}))
	if d.Status != StatusBehind || d.Findings[0].RuleID != "upd.behind" {
		t.Fatalf("behind: %s %v", d.Status, rules(d))
	}
	if f := hasRule(d, "upd.behind"); f == nil || !strings.Contains(f.Claim, "1 from the security suite") {
		t.Fatalf("behind claim: %+v", f)
	}

	// an interrupted dpkg leads over 'behind'
	d = diagnoseUpdates(t, updSnap(func(s *UpdateSnapshot) {
		s.DpkgInterrupted = true
		s.Upgradable = []UpgradablePkg{{Name: "bash"}}
	}))
	if d.Findings[0].RuleID != "upd.dpkg_interrupted" || d.Findings[0].Certainty != Proven {
		t.Fatalf("dpkg_interrupted should lead: %v", rules(d))
	}

	// held packages
	d = diagnoseUpdates(t, updSnap(func(s *UpdateSnapshot) { s.Held = []string{"docker-ce", "containerd.io"} }))
	if hasRule(d, "upd.held") == nil || d.Status != StatusBehind {
		t.Fatalf("held: %s %v", d.Status, rules(d))
	}

	// a pending reboot on an otherwise clean host is still 'behind'
	d = diagnoseUpdates(t, updSnap(func(s *UpdateSnapshot) { s.RebootRequired = true; s.RebootReason = "/run/reboot-required exists" }))
	if hasRule(d, "upd.reboot_pending") == nil || d.Status != StatusBehind {
		t.Fatalf("reboot: %s %v", d.Status, rules(d))
	}

	// an unreachable repo is Likely
	d = diagnoseUpdates(t, updSnap(func(s *UpdateSnapshot) { s.RepoErrors = []string{"deb.debian.org timed out"} }))
	if f := hasRule(d, "upd.repo_unreachable"); f == nil || f.Certainty != Likely {
		t.Fatalf("repo_unreachable: %v", rules(d))
	}
}
