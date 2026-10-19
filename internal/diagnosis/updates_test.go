package diagnosis

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

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
