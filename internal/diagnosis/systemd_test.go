package diagnosis

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 17, 14, 20, 44, 0, time.UTC)

func yes() *bool { b := true; return &b }
func no() *bool  { b := false; return &b }

func snap(show map[string]string, mod func(*SystemdSnapshot)) SystemdSnapshot {
	s := SystemdSnapshot{Unit: "probe.service", Show: map[string]string{"LoadState": "loaded", "UnitFileState": "disabled",
		"ExecMainExitTimestamp": "@1792246839"}, Deps: []SystemdDep{}, Journal: []JournalLine{}, Files: []FileTime{},
		CollectedAt: t0}
	for k, v := range show {
		s.Show[k] = v
	}
	if mod != nil {
		mod(&s)
	}
	return s
}

func jl(cursor, msg string) JournalLine {
	return JournalLine{Cursor: cursor, Time: t0.Add(-5 * time.Second), Message: msg, Priority: 3}
}

// diagnose runs the rules and checks the document against the contract and the schema — every case below is also
// a contract test.
func diagnose(t *testing.T, s SystemdSnapshot) *Diagnosis {
	t.Helper()
	d, err := DiagnoseSystemd(s, "test", "e2e-deb-1")
	if err != nil {
		t.Fatalf("DiagnoseSystemd: %v", err)
	}
	out, _ := json.Marshal(d)
	if err := resolvedSchema(t).Validate(generic(t, out)); err != nil {
		t.Fatalf("schema: %v\n%s", err, out)
	}
	return d
}

func rules(d *Diagnosis) []string {
	var r []string
	for _, f := range d.Findings {
		r = append(r, f.RuleID+"/"+string(f.Certainty))
	}
	return r
}

func TestSystemdRules(t *testing.T) {
	cases := []struct {
		name string
		s    SystemdSnapshot
		want string // leading finding rule/certainty
	}{
		{"203 exec missing", snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "203"},
			func(s *SystemdSnapshot) {
				s.ExecPath, s.ExecExists = "/usr/local/bin/probe-missing", no()
				s.Journal = []JournalLine{jl("c1", "probe.service: Failed to locate executable /usr/local/bin/probe-missing: No such file or directory")}
			}), "svc.image_missing/Proven"},
		{"203 exists not executable", snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "203"},
			func(s *SystemdSnapshot) { s.ExecPath, s.ExecExists, s.ExecIsExec = "/opt/x", yes(), no() }), "svc.image_missing/Likely"},
		{"217 user", snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "217", "User": "nosuchuser"},
			func(s *SystemdSnapshot) { s.User, s.UserExists = "nosuchuser", no() }), "svc.account_missing/Proven"},
		{"masked", snap(map[string]string{"ActiveState": "inactive", "LoadState": "masked", "UnitFileState": "masked"}, nil), "svc.disabled/Proven"},
		{"not found", snap(map[string]string{"ActiveState": "inactive", "LoadState": "not-found"}, nil), "svc.not_installed/Proven"},
		{"timeout", snap(map[string]string{"ActiveState": "failed", "Result": "timeout"}, nil), "svc.timeout/Proven"},
		{"crash", snap(map[string]string{"ActiveState": "failed", "Result": "core-dump", "ExecMainCode": "3", "ExecMainStatus": "11"}, nil), "svc.crash/Proven"},
		{"oom", snap(map[string]string{"ActiveState": "failed", "Result": "oom-kill"}, nil), "svc.oom_killed/Proven"},
		{"start limit", snap(map[string]string{"ActiveState": "failed", "Result": "start-limit-hit", "NRestarts": "5"}, nil), "svc.start_limit/Proven"},
		{"condition", snap(map[string]string{"ActiveState": "inactive", "Result": "success", "ConditionResult": "no", "ConditionTimestamp": "@1792246839"},
			func(s *SystemdSnapshot) {
				s.Journal = []JournalLine{jl("c2", "probe.service was skipped because no trigger condition checks were met.")}
			}), "svc.condition_failed/Proven"},
		{"state directory", snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "238"}, nil), "svc.access_denied/Proven"},
		{"own exit code + config text", snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "1"},
			func(s *SystemdSnapshot) {
				s.Journal = []JournalLine{jl("c3", "nginx: [emerg] unknown directive \"lisen\" in /etc/nginx/nginx.conf:12")}
			}), "svc.exits_immediately/Proven"},
		{"oneshot finished", snap(map[string]string{"ActiveState": "inactive", "Result": "success", "Type": "oneshot"}, nil), "svc.stopped_cleanly/Proven"},
		{"nothing matches", snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "200"}, nil), "svc.unexplained/Unknown"},
	}
	for _, c := range cases {
		d := diagnose(t, c.s)
		if got := rules(d); len(got) == 0 || got[0] != c.want {
			t.Errorf("%s: findings %v, want leading %s", c.name, got, c.want)
		}
		if d.Summary != d.Findings[0].Claim {
			t.Errorf("%s: summary is not the leading claim", c.name)
		}
	}
}

func TestTheJournalCauseIsAddedAsLikelyAfterTheStructuralOne(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "1"},
		func(s *SystemdSnapshot) {
			s.Journal = []JournalLine{jl("c3", "nginx: [emerg] unknown directive \"lisen\" in /etc/nginx/nginx.conf:12")}
		}))
	got := strings.Join(rules(d), " ")
	if got != "svc.exits_immediately/Proven svc.config_invalid/Likely" {
		t.Fatalf("findings: %s", got)
	}
	if d.Findings[1].EvidenceIDs[0] != "journal:c3" {
		t.Fatalf("the journal finding cites the matching line: %v", d.Findings[1].EvidenceIDs)
	}
}

func TestDependencyPointsAtTheDeepestFailedLink(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "inactive", "Result": "dependency"}, func(s *SystemdSnapshot) {
		s.Deps = []SystemdDep{
			{Unit: "a.service", Via: []string{"probe.service"}, Depth: 1, Show: map[string]string{"ActiveState": "failed", "Result": "dependency", "LoadState": "loaded"}},
			{Unit: "b.service", Via: []string{"probe.service", "a.service"}, Depth: 2, Show: map[string]string{"ActiveState": "inactive", "LoadState": "masked"}},
		}
	}))
	f := d.Findings[0]
	if f.RuleID != "svc.dependency_failed" || !strings.Contains(f.Claim, "b.service (required via a.service → b.service), is masked") {
		t.Fatalf("claim: %s", f.Claim)
	}
	if f.EvidenceIDs[1] != "systemd:show:b.service" {
		t.Fatalf("evidence: %v", f.EvidenceIDs)
	}
}

func TestARunningUnitHasNoFinding(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "active", "SubState": "running", "Result": "success"}, nil))
	if d.Status != StatusRunning || len(d.Findings) != 0 || d.Summary != "probe.service is running." {
		t.Fatalf("%+v", d)
	}
}

func findingByRule(d *Diagnosis, rule string) *Finding {
	for i := range d.Findings {
		if d.Findings[i].RuleID == rule {
			return &d.Findings[i]
		}
	}
	return nil
}

func TestRecentIncidentIsAddedFromTheRing(t *testing.T) {
	oom := Incident{Kind: IncidentOOMKill, At: t0.Add(-2 * time.Minute), PID: 4242, Image: "probe", Source: "ebpf"}

	// A unit that is not running, with a past OOM kill: the present state leads, the incident follows (Likely), never
	// above, and ranked last (order 950).
	d := diagnose(t, snap(map[string]string{"ActiveState": "inactive", "UnitFileState": "disabled"},
		func(s *SystemdSnapshot) { s.RecentIncidents = []Incident{oom} }))
	got := rules(d)
	if len(got) < 2 || got[len(got)-1] != "svc.recent_incident/Likely" {
		t.Fatalf("svc.recent_incident should be present and last: %v", got)
	}
	f := findingByRule(d, "svc.recent_incident")
	if f == nil || f.Certainty != Likely {
		t.Fatalf("no svc.recent_incident/Likely: %v", rules(d))
	}
	if len(f.EvidenceIDs) != 1 || f.EvidenceIDs[0] != oom.EvidenceID() {
		t.Fatalf("evidence ids: %v (want %s)", f.EvidenceIDs, oom.EvidenceID())
	}
	if f.Precedent != nil {
		t.Fatalf("a historical incident must not carry a precedent: %+v", f.Precedent)
	}

	// A RUNNING unit with a past fatal signal: still reported — it crashed and came back.
	run := diagnose(t, snap(map[string]string{"ActiveState": "active", "SubState": "running", "Result": "success"},
		func(s *SystemdSnapshot) {
			s.RecentIncidents = []Incident{{Kind: IncidentFatalSignal, At: t0.Add(-time.Minute), PID: 99, Image: "probe", Detail: "SIGSEGV", Source: "ebpf"}}
		}))
	if findingByRule(run, "svc.recent_incident") == nil {
		t.Fatalf("running unit should still report a past crash: %v", rules(run))
	}

	// No incidents → no such finding.
	none := diagnose(t, snap(map[string]string{"ActiveState": "inactive", "UnitFileState": "disabled"}, nil))
	if findingByRule(none, "svc.recent_incident") != nil {
		t.Fatalf("unexpected svc.recent_incident: %v", rules(none))
	}
}

func TestUnexplainedNamesWhatWasRead(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "200"}, nil))
	if g := *d.Findings[0].Gap; !strings.Contains(g, "journal holds no entry") {
		t.Fatalf("gap: %s", g)
	}
}

// --- collector, against a fake systemctl/getent/journalctl ---

type fakeInfo struct {
	mode  fs.FileMode
	mtime time.Time
}

func (f fakeInfo) Name() string       { return "" }
func (f fakeInfo) Size() int64        { return 0 }
func (f fakeInfo) Mode() fs.FileMode  { return f.mode }
func (f fakeInfo) ModTime() time.Time { return f.mtime }
func (f fakeInfo) IsDir() bool        { return false }
func (f fakeInfo) Sys() any           { return nil }

func TestCollectSystemdReadsShowUserDepsAndTheInvocationJournal(t *testing.T) {
	run := func(_ context.Context, name string, args ...string) ([]byte, error) {
		switch {
		case name == "systemctl" && args[1] == "probe.service":
			return []byte("LoadState=loaded\nActiveState=failed\nResult=exit-code\nExecMainStatus=217\nUser=svcuser\n" +
				"InvocationID=inv1\nFragmentPath=/etc/systemd/system/probe.service\nRequires=base.service\n" +
				"ExecStart={ path=/usr/bin/probe ; argv[]=/usr/bin/probe -f ; ignore_errors=no }\nExecMainExitTimestamp=@1792246839\n"), nil
		case name == "systemctl" && args[1] == "base.service":
			return []byte("LoadState=loaded\nActiveState=active\n"), nil
		case name == "getent":
			return nil, fmt.Errorf("getent: exit status 2")
		case name == "journalctl":
			return []byte(`{"__CURSOR":"cur-old","MESSAGE":"old run","_SYSTEMD_INVOCATION_ID":"inv0","__REALTIME_TIMESTAMP":"1792246000000000"}
{"__CURSOR":"cur-new","MESSAGE":"probe.service: Failed to determine user credentials: No such process","INVOCATION_ID":"inv1","__REALTIME_TIMESTAMP":"1792246839000000","PRIORITY":"3"}
`), nil
		}
		return nil, errors.New("unexpected " + name)
	}
	stat := func(p string) (os.FileInfo, error) {
		if p == "/usr/bin/probe" {
			return fakeInfo{mode: 0o755}, nil
		}
		return fakeInfo{mtime: t0.Add(-time.Hour)}, nil
	}
	s, err := CollectSystemd(context.Background(), run, stat, "probe", t0)
	if err != nil {
		t.Fatal(err)
	}
	if s.Unit != "probe.service" || s.ExecPath != "/usr/bin/probe" || s.ExecExists == nil || !*s.ExecExists {
		t.Fatalf("exec: %+v", s)
	}
	if s.UserExists == nil || *s.UserExists {
		t.Fatalf("user: %+v", s.UserExists)
	}
	if len(s.Deps) != 1 || s.Deps[0].Unit != "base.service" {
		t.Fatalf("deps: %+v", s.Deps)
	}
	if len(s.Journal) != 1 || s.Journal[0].Cursor != "cur-new" {
		t.Fatalf("journal must keep the current invocation only: %+v", s.Journal)
	}
	d := diagnose(t, s)
	if d.Findings[0].RuleID != "svc.account_missing" || d.Status != StatusFailed {
		t.Fatalf("%v", rules(d))
	}
}

func TestAnEmptyJournalIsANamedGap(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "1"}, nil))
	if len(d.Gaps) != 1 || !strings.Contains(d.Gaps[0].Why, "no entry for the current invocation") {
		t.Fatalf("gaps: %+v", d.Gaps)
	}
}

func TestAConditionThatWasNeverEvaluatedIsNoFinding(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "inactive", "Result": "success", "Type": "oneshot", "ConditionResult": "no"}, nil))
	if rules(d)[0] != "svc.stopped_cleanly/Proven" {
		t.Fatalf("%v", rules(d))
	}
}

func TestTheStartLimitIsReadFromSystemdsOwnMessage(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "1", "NRestarts": "2"},
		func(s *SystemdSnapshot) {
			s.Journal = []JournalLine{jl("c9", "probe-limit.service: Start request repeated too quickly.")}
		}))
	if rules(d)[0] != "svc.start_limit/Proven" || rules(d)[1] != "svc.exits_immediately/Proven" {
		t.Fatalf("%v", rules(d))
	}
}

func TestASkippedUnitIsReadFromSystemdsConditionMessage(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "inactive", "Result": "success", "ConditionResult": "no"},
		func(s *SystemdSnapshot) {
			s.Journal = []JournalLine{jl("c8", "probe-cond.service - x was skipped because of an unmet condition check (ConditionPathExists=/nonexistent/probe).")}
		}))
	if rules(d)[0] != "svc.condition_failed/Proven" {
		t.Fatalf("%v", rules(d))
	}
}

// --- B7: precedent — the most recent change before the failure ---

func failed(mod func(*SystemdSnapshot)) SystemdSnapshot {
	return snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainCode": "1", "ExecMainStatus": "1"}, mod)
}

func TestThePrecedentIsTheNewestChangeOfTheTargetNotANewerHostChange(t *testing.T) {
	d := diagnose(t, failed(func(s *SystemdSnapshot) {
		s.Files = []FileTime{
			{Path: "/etc/systemd/system/probe.service", Role: "unit file", Changed: t0.Add(-2 * time.Minute)},
			{Path: "/etc/systemd/system/probe.service.d/x.conf", Role: "drop-in", Changed: t0.Add(-10 * time.Minute)},
		}
		s.Packages = []PackageChange{{Name: "libfoo", Action: "upgrade", From: "1", To: "2", At: t0.Add(-time.Minute), Source: "dpkg.log"}}
	}))
	for _, f := range d.Findings {
		p := f.Precedent
		if p == nil || p.EvidenceID != "file:changed:/etc/systemd/system/probe.service" || p.GapSeconds != 115 {
			t.Fatalf("%s: precedent %+v", f.RuleID, p)
		}
	}
}

func TestAHostChangeIsThePrecedentOnlyWhenTheTargetDidNotChange(t *testing.T) {
	d := diagnose(t, failed(func(s *SystemdSnapshot) {
		s.Files = []FileTime{{Path: "/usr/lib/systemd/system/probe.service", Role: "unit file", Changed: t0.Add(-30 * 24 * time.Hour)}}
		s.Packages = []PackageChange{{Name: "libfoo", Action: "upgrade", From: "1", To: "2", At: t0.Add(-time.Hour), Source: "dpkg.log"}}
	}))
	p := d.Findings[0].Precedent
	if p == nil || p.EvidenceID != "pkg:dpkg.log:libfoo" || p.Change != "libfoo was upgraded from 1 to 2" {
		t.Fatalf("precedent %+v", p)
	}
}

func TestNoChangeInsideTheWindowBeforeTheFailureIsNoPrecedent(t *testing.T) {
	d := diagnose(t, failed(func(s *SystemdSnapshot) {
		s.Files = []FileTime{
			{Path: "/usr/lib/systemd/system/probe.service", Role: "unit file", Changed: t0.Add(-8 * 24 * time.Hour)}, // too old
			{Path: "/usr/bin/probe", Role: "program", Changed: t0.Add(time.Minute)},                                  // after the failure
		}
	}))
	for _, f := range d.Findings {
		if f.Precedent != nil {
			t.Fatalf("%s: %+v", f.RuleID, f.Precedent)
		}
	}
	if len(d.Timeline) < 2 {
		t.Fatalf("the changes stay on the timeline: %+v", d.Timeline)
	}
}

func TestUnreadablePackageChangesAreAGap(t *testing.T) {
	d := diagnose(t, failed(func(s *SystemdSnapshot) { s.PackagesErr = "neither dpkg-query nor rpm answered" }))
	for _, g := range d.Gaps {
		if g.What == "package changes before the failure" {
			return
		}
	}
	t.Fatalf("gaps: %+v", d.Gaps)
}

func TestDpkgChangesKeepTheOwnerAndTheNewestOtherChangeInTheWindow(t *testing.T) {
	loc := func(d time.Duration) string { return t0.Add(d).In(time.Local).Format("2006-01-02 15:04:05") }
	run := func(_ context.Context, name string, args ...string) ([]byte, error) {
		switch {
		case name == "dpkg-query" && args[0] == "--version":
			return []byte("Debian dpkg-query 1.22"), nil
		case name == "dpkg-query" && args[1] == "/usr/sbin/probed":
			return []byte("probed:amd64: /usr/sbin/probed\n"), nil
		case name == "dpkg-query":
			return []byte("dpkg-query: no path found matching pattern " + args[1] + "\n"), errors.New("exit status 1")
		case name == "cat" && args[0] == "/var/log/dpkg.log.1":
			return nil, errors.New("No such file")
		case name == "cat":
			return []byte(loc(-40*24*time.Hour) + " upgrade probed:amd64 1.0 1.1\n" +
				loc(-9*24*time.Hour) + " install oldpkg:all <none> 3\n" +
				loc(-2*time.Hour) + " status installed libfoo:amd64 2\n" +
				loc(-2*time.Hour) + " upgrade libfoo:amd64 1 2\n" +
				loc(-time.Hour) + " remove libbar:amd64 5 <none>\n" +
				loc(time.Hour) + " upgrade later:amd64 1 2\n"), nil
		}
		return nil, errors.New("unexpected " + name)
	}
	got, gap := collectPackages(context.Background(), run, []string{"/etc/systemd/system/probed.service", "/usr/sbin/probed"}, t0)
	if gap != "" || len(got) != 2 {
		t.Fatalf("%q %+v", gap, got)
	}
	if !got[0].Owner || got[0].Name != "probed" || got[0].To != "1.1" || !got[0].At.Equal(t0.Add(-40*24*time.Hour)) {
		t.Fatalf("owner: %+v", got[0])
	}
	if got[1].Owner || got[1].Name != "libbar" || got[1].Action != "remove" || pkgChangeText(got[1]) != "libbar 5 was removed" {
		t.Fatalf("newest other change before the failure: %+v", got[1])
	}
}

func TestRpmChangesReadTheInstallTime(t *testing.T) {
	run := func(_ context.Context, name string, args ...string) ([]byte, error) {
		switch {
		case name == "dpkg-query":
			return nil, errors.New("executable file not found")
		case name == "rpm" && args[0] == "--version":
			return []byte("RPM version 4.16"), nil
		case name == "rpm" && args[0] == "-qf" && args[3] == "/usr/sbin/probed":
			return []byte("probed\n"), nil
		case name == "rpm" && args[0] == "-qf":
			return []byte("file " + args[3] + " is not owned by any package\n"), errors.New("exit status 1")
		case name == "rpm" && args[0] == "-qa":
			return []byte(fmt.Sprintf("%d probed 1.1-1.el9\n%d glibc 2.34-100.el9\n%d kernel 5.14-1\n",
				t0.Add(-20*24*time.Hour).Unix(), t0.Add(-3*time.Hour).Unix(), t0.Add(-30*24*time.Hour).Unix())), nil
		}
		return nil, errors.New("unexpected " + name)
	}
	got, gap := collectPackages(context.Background(), run, []string{"/usr/sbin/probed"}, t0)
	if gap != "" || len(got) != 2 || got[0].Name != "probed" || !got[0].Owner || got[1].Name != "glibc" || got[1].Source != "rpm" {
		t.Fatalf("%q %+v", gap, got)
	}
}

func TestWithoutAPackageManagerThePackageChangesAreANamedReason(t *testing.T) {
	run := func(_ context.Context, name string, args ...string) ([]byte, error) {
		return nil, errors.New("not found")
	}
	got, gap := collectPackages(context.Background(), run, nil, t0)
	if len(got) != 0 || !strings.Contains(gap, "neither dpkg-query nor rpm") {
		t.Fatalf("%q %+v", gap, got)
	}
}

func TestDpkgFindsTheOwnerUnderTheUsrMergedPathAndNamesAnOwnerTheLogNeverMentions(t *testing.T) {
	run := func(_ context.Context, name string, args ...string) ([]byte, error) {
		switch {
		case name == "dpkg-query" && args[0] == "--version":
			return []byte("Debian dpkg-query 1.22"), nil
		case name == "dpkg-query" && args[1] == "/usr/bin/sh":
			return []byte("dash: /usr/bin/sh\n"), nil
		case name == "dpkg-query":
			return []byte("dpkg-query: no path found matching pattern " + args[1] + "\n"), errors.New("exit status 1")
		case name == "readlink":
			return []byte("/usr/bin/dash\n"), nil
		case name == "cat" && args[0] == "/var/log/dpkg.log":
			return []byte("2026-10-10 08:00:00 startup archives unpack\n2026-10-16 08:00:01 install libfoo:amd64 <none> 1\n"), nil
		case name == "cat":
			return nil, errors.New("No such file")
		}
		return nil, errors.New("unexpected " + name)
	}
	got, gap := collectPackages(context.Background(), run, []string{"/bin/sh"}, t0)
	if gap != "" || len(got) != 2 || got[0].Name != "dash" || got[0].Action != "unchanged" || !got[0].Owner ||
		got[0].Since.IsZero() || got[1].Name != "libfoo" || got[1].Owner {
		t.Fatalf("%q %+v", gap, got)
	}
	d := diagnose(t, failed(func(s *SystemdSnapshot) { s.Packages = got }))
	for _, e := range d.Evidence {
		if e.ID == "pkg:dpkg.log:dash" {
			if e.Observed != nil || !strings.Contains(e.Fact, "records no change") {
				t.Fatalf("an unchanged owner is a fact without a time: %+v", e)
			}
			if p := d.Findings[0].Precedent; p == nil || p.EvidenceID != "pkg:dpkg.log:libfoo" {
				t.Fatalf("precedent %+v", p)
			}
			return
		}
	}
	t.Fatalf("the unchanged owner vanished: %+v", d.Evidence)
}

// The journal lines the baseline cross-check found unexplained by the first port (2026-10-17, package e2e pods).
func TestTheBaselineCasesGetTheirCauseFromTheJournal(t *testing.T) {
	for line, rule := range map[string]string{
		"FireHOL needs to be enabled in /etc/default/firehol in order to run.": "svc.config_incomplete",
		"ERROR: /etc/thinkfan.conf: No such file or directory":                 "svc.config_incomplete",
		"Can't read quorum.device.model cmap key.":                             "svc.peer_unreachable",
		"hdapsd: Could not find a suitable interface (hdaps not loaded)":       "svc.device_missing",
		"mbpfan: Could not find coretemp module":                               "svc.device_missing",
		// comitup: the classifier read "hardware" from the word NetworkManager; the line says a D-Bus SERVICE is missing
		"dbus.exceptions.DBusException: org.freedesktop.DBus.Error.ServiceUnknown: The name org.freedesktop.NetworkManager was not provided by any .service files": "svc.peer_unreachable",
	} {
		d := diagnose(t, snap(map[string]string{"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "1"},
			func(s *SystemdSnapshot) { s.Journal = []JournalLine{jl("c9", line)} }))
		if got := strings.Join(rules(d), " "); !strings.Contains(got, rule+"/Likely") {
			t.Errorf("%q: %s, want %s", line, got, rule)
		}
	}
}

func TestAnAutoRestartLoopIsAFailureNotAStart(t *testing.T) {
	d := diagnose(t, snap(map[string]string{"ActiveState": "activating", "SubState": "auto-restart", "Result": "exit-code",
		"ExecMainCode": "1", "ExecMainStatus": "1", "NRestarts": "4"}, nil))
	if d.Status != StatusFailed || len(d.Findings) == 0 || d.Findings[0].RuleID != "svc.exits_immediately" {
		t.Fatalf("%s %v", d.Status, rules(d))
	}
	running := diagnose(t, snap(map[string]string{"ActiveState": "activating", "SubState": "start"}, nil))
	if running.Status != StatusStarting || len(running.Findings) != 0 {
		t.Fatalf("a start in progress has no finding: %s %v", running.Status, rules(running))
	}
}

// --- B14: a start that does not end, read from /proc ---

func TestAStartThatDoesNotEndShowsWhereItsThreadsWait(t *testing.T) {
	since := t0.Add(-95 * time.Second)
	d := diagnose(t, snap(map[string]string{"ActiveState": "activating", "SubState": "start", "MainPID": "4242",
		"InactiveExitTimestamp": fmt.Sprintf("@%d", since.Unix())}, func(s *SystemdSnapshot) {
		s.Threads = []ProcThread{{TID: 4242, State: "S", Wchan: "hrtimer_nanosleep", Comm: "sleep"}}
	}))
	if d.Status != StatusStarting || len(d.Findings) != 1 || d.Findings[0].RuleID != "svc.timeout" || d.Findings[0].Certainty != Likely {
		t.Fatalf("%s %v", d.Status, rules(d))
	}
	if !strings.Contains(d.Findings[0].Claim, "activating for 95 s") || !strings.Contains(d.Findings[0].Claim, "hrtimer_nanosleep") {
		t.Fatalf("claim: %s", d.Findings[0].Claim)
	}
	young := diagnose(t, snap(map[string]string{"ActiveState": "activating", "SubState": "start", "MainPID": "4242",
		"InactiveExitTimestamp": fmt.Sprintf("@%d", t0.Add(-5*time.Second).Unix())}, nil))
	if len(young.Findings) != 0 {
		t.Fatalf("a start of 5 s is just starting: %v", rules(young))
	}
}

func TestThreadsAreReadFromProc(t *testing.T) {
	run := func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "sh" && strings.Contains(args[1], "/proc/4242/task/") {
			return []byte("4242 S hrtimer_nanosleep sleep\n4243 D io_schedule my worker\n"), nil
		}
		return nil, errors.New("unexpected")
	}
	th, gap := collectThreads(context.Background(), run, "4242")
	if gap != "" || len(th) != 2 || th[1].State != "D" || th[1].Wchan != "io_schedule" || th[1].Comm != "my worker" {
		t.Fatalf("%q %+v", gap, th)
	}
	if _, gap := collectThreads(context.Background(), run, "4242; rm -rf /"); !strings.Contains(gap, "not a number") {
		t.Fatalf("a MainPID that is not a number is refused: %q", gap)
	}
}
