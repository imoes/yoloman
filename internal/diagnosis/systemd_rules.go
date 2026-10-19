package diagnosis

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// systemd's own exit statuses (systemd.exec(5) "Process Exit Codes") — a status in this range is systemd refusing to
// start the program, not the program's own error.
var systemdStatus = map[int]string{
	200: "CHDIR", 201: "NICE", 202: "FDS", 203: "EXEC", 204: "MEMORY", 205: "LIMITS", 206: "OOM_ADJUST",
	207: "SIGNAL_MASK", 208: "STDIN", 209: "STDOUT", 210: "CHROOT", 211: "IOPRIO", 212: "TIMERSLACK",
	213: "SECUREBITS", 214: "SETSCHEDULER", 215: "CPUAFFINITY", 216: "GROUP", 217: "USER", 218: "CAPABILITIES",
	219: "CGROUP", 220: "SETSID", 221: "CONFIRM", 222: "STDERR", 224: "PAM", 225: "NETWORK", 226: "NAMESPACE",
	227: "NO_NEW_PRIVILEGES", 228: "SECCOMP", 229: "SELINUX_CONTEXT", 230: "PERSONALITY", 231: "APPARMOR_PROFILE",
	232: "ADDRESS_FAMILIES", 233: "RUNTIME_DIRECTORY", 235: "CHOWN", 236: "SMACK_PROCESS_LABEL", 237: "KEYRING",
	238: "STATE_DIRECTORY", 239: "CACHE_DIRECTORY", 240: "LOGS_DIRECTORY", 241: "CONFIGURATION_DIRECTORY",
	242: "NUMA_POLICY", 243: "CREDENTIALS",
}

var crashSignals = map[int]string{11: "SIGSEGV", 6: "SIGABRT", 7: "SIGBUS", 4: "SIGILL", 8: "SIGFPE"}

// journalRule: a cause read from the invocation's journal text — Likely, never Proven (text is not a measurement of
// the cause). Ported from the package e2e classifier (tools/package_e2e_bossman.py SHIPPED_CAUSES); the causes that
// systemd states structurally (masked, 203, 217, crash, dependency) are rules on `systemctl show` instead.
type journalRule struct {
	rule, title string
	re          *regexp.Regexp
}

var journalRules = []journalRule{
	{"svc.container_limit", "the environment does not allow what it needs",
		regexp.MustCompile(`ConditionVirtualization=!container|Cannot daemonize|audit.*netlink|executable 'modprobe'|ip6?tables(-legacy)?-restore|Operation not permitted|swapon failed`)},
	{"svc.device_missing", "a device it needs is not present",
		regexp.MustCompile(`No such device|DEVICEOPENERROR|/dev/tty\S* .*(No such|not found)|Cannot get card index|audio device|coretemp|hdaps|[Mm]odem|wlan|wifi`)},
	{"svc.config_invalid", "the program refuses its configuration",
		regexp.MustCompile(`(?i)compiled without|error parsing .* at \d+|unknown (directive|option)|syntax error|invalid (option|directive|value)`)},
	{"svc.not_initialized", "it needs a one-time initialisation first",
		regexp.MustCompile(`--initdb|initialize the database|not initiali[sz]ed`)},
	{"svc.network_unavailable", "it cannot resolve or reach the network",
		regexp.MustCompile(`Name or service not known|Temporary failure in name resolution|Network is unreachable`)},
	{"svc.peer_unreachable", "it cannot reach a service it needs",
		regexp.MustCompile(`(?i:connection refused)|Can't connect to (local )?MySQL|could not connect to server|cmap key|/var/log/mail\.log|zmpkg\.pl|DBus\.Error\.ServiceUnknown`)},
	{"svc.config_incomplete", "its configuration lacks values the site must supply",
		// The rest of the package e2e classifier's needs-site-config (SHIPPED_CAUSES) — missing in the first port, found by
		// the baseline cross-check (firehol "needs to be enabled", thinkfan/krb5 "No such file or directory"). Its
		// "EXCEPTION" is left out: too unspecific to be a reason.
		regexp.MustCompile(`not specified|[Ff]atal configuration error|[Pp]lease (define|provide)|no configuration found|[Nn]ot configured|[Nn]o subnet|[Mm]issing .*(option|setting)|Error opening configuration file|default realm|No such file or directory|No rules directory|No entries found|needs to be enabled|no boot files`)},
}

var (
	permDeniedStateRe = regexp.MustCompile(`Permission denied.*/var/(lib|cache|log)/`)
	conditionRe       = regexp.MustCompile(`(?i)condition check|Assertion failed|unmet condition`)
	startLimitRe      = regexp.MustCompile(`Start request repeated too quickly`)
)

// DiagnoseSystemd applies the Linux rules to a snapshot.
func DiagnoseSystemd(snap SystemdSnapshot, id, host string) (*Diagnosis, error) {
	b, err := NewBuilder(id, host, "linux", Target{Kind: "service", Name: snap.Unit}, snap.CollectedAt)
	if err != nil {
		return nil, err
	}
	s := snap.Show
	status := systemdStatusOf(s)
	exitStatus, _ := strconv.Atoi(s["ExecMainStatus"])
	show := b.Evidence(Evidence{ID: "systemd:show:" + snap.Unit, Source: "systemctl show", Observed: endedAt(s, status),
		Fact: showFact(snap.Unit, s, exitStatus), Raw: s})
	execID, userID := "", ""
	if snap.ExecPath != "" && snap.ExecExists != nil {
		f := snap.ExecPath + " exists and is executable."
		switch {
		case !*snap.ExecExists:
			f = snap.ExecPath + " does not exist."
		case snap.ExecIsExec != nil && !*snap.ExecIsExec:
			f = snap.ExecPath + " exists but is not executable."
		}
		execID = b.Evidence(Evidence{ID: "file:stat:" + Key(snap.ExecPath), Source: "stat", Fact: f,
			Raw: map[string]any{"path": snap.ExecPath, "exists": *snap.ExecExists, "executable": snap.ExecIsExec}})
	}
	if snap.User != "" && snap.UserExists != nil {
		f := "The account " + snap.User + " exists."
		if !*snap.UserExists {
			f = "The account " + snap.User + " does not exist (getent passwd finds no entry)."
		}
		userID = b.Evidence(Evidence{ID: "user:getent:" + snap.User, Source: "getent passwd", Fact: f,
			Raw: map[string]any{"user": snap.User, "exists": *snap.UserExists}})
	}
	journal := make([]string, 0, len(snap.Journal))
	for _, l := range snap.Journal {
		t := l.Time
		var obs = &t
		if t.IsZero() {
			obs = nil
		}
		journal = append(journal, b.Evidence(Evidence{ID: "journal:" + l.Cursor, Source: "journalctl", Observed: obs,
			Fact: "journal: " + clip(l.Message, 300), Raw: map[string]any{"message": l.Message, "priority": l.Priority}}))
	}
	// Changes: each is evidence (it is on the timeline) and a candidate precedent (Precede picks at most one).
	for _, f := range snap.Files {
		t := f.Changed
		if t.IsZero() {
			t = f.MTime
		}
		id := b.Evidence(Evidence{ID: "file:changed:" + Key(f.Path), Source: "stat", Observed: &t,
			Fact: fmt.Sprintf("The %s %s last changed on this host at %s.", f.Role, f.Path, t.Format("2006-01-02T15:04:05Z")),
			Raw: map[string]any{"path": f.Path, "role": f.Role, "changed": t.Format("2006-01-02T15:04:05Z"),
				"mtime": f.MTime.Format("2006-01-02T15:04:05Z")}})
		b.Change(id, "the "+f.Role+" "+f.Path+" changed", t, false)
	}
	for _, c := range snap.Packages {
		if c.Action == "unchanged" {
			b.Evidence(Evidence{ID: "pkg:" + c.Source + ":" + Key(c.Name), Source: c.Source,
				Fact: fmt.Sprintf("%s owns the unit or its program; %s records no change of it since it begins (%s).",
					c.Name, c.Source, c.Since.Format("2006-01-02T15:04:05Z")),
				Raw: map[string]any{"name": c.Name, "action": c.Action, "owner": true, "since": c.Since.Format("2006-01-02T15:04:05Z")}})
			continue
		}
		t := c.At
		what := pkgChangeText(c)
		scope := "another package"
		if c.Owner {
			scope = "the package that owns the unit or its program"
		}
		id := b.Evidence(Evidence{ID: "pkg:" + c.Source + ":" + Key(c.Name), Source: c.Source, Observed: &t,
			Fact: fmt.Sprintf("%s: %s at %s (%s).", scope, what, t.Format("2006-01-02T15:04:05Z"), c.Source),
			Raw:  map[string]any{"name": c.Name, "action": c.Action, "from": c.From, "to": c.To, "owner": c.Owner, "line": c.Raw}})
		b.Change(id, what, t, !c.Owner)
	}
	switch {
	case snap.JournalErr != "":
		b.Gap("the unit's journal", "journalctl failed: "+clip(snap.JournalErr, 200))
	case len(snap.Journal) == 0 && status != StatusRunning && status != StatusStarting:
		// Nothing read is not "nothing happened": journalctl answers an unprivileged reader with no lines and rc 0
		// (measured 2026-10-17 on a workstation user outside systemd-journal), and a rotated journal looks the same.
		b.Gap("the unit's journal", "journalctl returned no entry for the current invocation — the journal rotated, "+
			"or the reading user may not see the system journal (not root, not in systemd-journal)")
	}
	// B14 — A START THAT DOES NOT END: activating for longer than 30 s, its threads' kernel wait channels as evidence.
	// Likely: systemd's own TimeoutStartSec decides when it gives up (then Result=timeout, Proven below).
	if status == StatusStarting {
		if since := unixTime(s["InactiveExitTimestamp"]); since != nil && snap.CollectedAt.Sub(*since) > 30*time.Second {
			ids := []string{show}
			waits := []string{}
			for _, th := range snap.Threads {
				ids = append(ids, b.Evidence(Evidence{ID: fmt.Sprintf("proc:%s:%d", s["MainPID"], th.TID), Source: "/proc task stat+wchan",
					Fact: fmt.Sprintf("Thread %d (%s) of process %s is %s%s.", th.TID, th.Comm, s["MainPID"], stateWord(th.State), wchanWords(th.Wchan)),
					Raw:  th}))
				if th.Wchan != "0" && th.Wchan != "" {
					waits = append(waits, th.Wchan)
				}
			}
			if snap.ThreadsErr != "" {
				b.Gap("what the threads of "+snap.Unit+" are doing", snap.ThreadsErr)
			}
			claim := fmt.Sprintf("%s hangs while starting: it has been activating for %d s", snap.Unit, int(snap.CollectedAt.Sub(*since).Seconds()))
			if len(waits) > 0 {
				claim += " and its threads wait in the kernel in " + strings.Join(uniq(waits), ", ")
			}
			if err := b.Find(Finding{RuleID: "svc.timeout", Certainty: Likely, EvidenceIDs: ids, Claim: claim + "."}); err != nil {
				return nil, err
			}
		}
	}
	if status == StatusRunning || status == StatusStarting {
		b.Precede(snap.CollectedAt)
		if err := addRecentIncidents(b, snap); err != nil {
			return nil, err
		}
		return b.Build(status)
	}
	if snap.PackagesErr != "" {
		b.Gap("package changes before the failure", snap.PackagesErr)
	}
	matched := len(systemdRules(b, snap, show, execID, userID, journal, exitStatus))
	if matched == 0 {
		read := append([]string{show}, journal...)
		gap := fmt.Sprintf("%s is %s with Result=%s and ExecMainStatus=%d; ", snap.Unit, s["ActiveState"],
			orDash(s["Result"]), exitStatus)
		if len(journal) == 0 {
			gap += "its journal holds no entry for the current invocation, so the program's own reason is not recorded."
		} else {
			gap += fmt.Sprintf("none of the %d journal entries of the invocation matches a known cause.", len(journal))
		}
		if err := b.Unexplained(read, gap); err != nil {
			return nil, err
		}
	}
	failedAt := snap.CollectedAt
	if t := endedAt(s, status); t != nil {
		failedAt = *t
	}
	b.Precede(failedAt)
	if err := addRecentIncidents(b, snap); err != nil {
		return nil, err
	}
	return b.Build(status)
}

// addRecentIncidents turns the unit's recent eBPF incidents (OOM kill, fatal signal) into evidence and one
// svc.recent_incident finding (Likely — a past invocation, never the present state). Called after Precede on both
// paths so a historical incident never attaches a precedent of its own; on the running path too, since a service that
// was OOM-killed and restarted is exactly what this explains.
func addRecentIncidents(b *Builder, snap SystemdSnapshot) error {
	if len(snap.RecentIncidents) == 0 {
		return nil
	}
	ids := make([]string, 0, len(snap.RecentIncidents))
	for _, inc := range snap.RecentIncidents {
		ev := inc.toEvidence()
		if b.Has(ev.ID) {
			ids = append(ids, ev.ID)
		} else {
			ids = append(ids, b.Evidence(ev))
		}
	}
	newest := snap.RecentIncidents[0]
	var claim string
	if len(snap.RecentIncidents) == 1 {
		claim = fmt.Sprintf("%s hit a recent incident before now: %s", snap.Unit, newest.fact())
	} else {
		claim = fmt.Sprintf("%s hit %d recent incidents before now; the most recent: %s",
			snap.Unit, len(snap.RecentIncidents), newest.fact())
	}
	return b.Find(Finding{RuleID: "svc.recent_incident", Certainty: Likely, EvidenceIDs: ids, Claim: claim})
}

// pkgChangeText says what happened to a package in dpkg's own words.
func pkgChangeText(c PackageChange) string {
	switch c.Action {
	case "upgrade":
		return fmt.Sprintf("%s was upgraded from %s to %s", c.Name, c.From, c.To)
	case "remove":
		return fmt.Sprintf("%s %s was removed", c.Name, c.From)
	default:
		return fmt.Sprintf("%s %s was installed", c.Name, c.To)
	}
}

// systemdRules adds every matching finding and returns their rule ids.
func systemdRules(b *Builder, snap SystemdSnapshot, show, execID, userID string, journal []string, exitStatus int) []string {
	s, u := snap.Show, snap.Unit
	var hit []string
	add := func(f Finding) {
		if b.Find(f) == nil {
			hit = append(hit, f.RuleID)
		}
	}
	result := s["Result"]
	if s["LoadState"] == "not-found" {
		add(Finding{RuleID: "svc.not_installed", Certainty: Proven, EvidenceIDs: []string{show},
			Claim: u + " cannot start because no unit file defines it (LoadState=not-found)."})
		return hit
	}
	if s["LoadState"] == "masked" || s["UnitFileState"] == "masked" {
		add(Finding{RuleID: "svc.disabled", Certainty: Proven, EvidenceIDs: []string{show},
			Claim: u + " cannot start because it is masked.",
			Remedy: &Remedy{Action: "set", Target: RemedyTarget{Kind: "systemd_unit", ID: u, Attribute: Str("masked")},
				Before: true, After: false, Rollback: Rollback{Action: "set", Value: true},
				Verify: Verify{RuleAbsent: "svc.disabled", Expect: map[string]any{"load_state": "loaded"}}}})
	}
	if exitStatus == 203 {
		f := Finding{RuleID: "svc.image_missing", EvidenceIDs: []string{show}}
		if execID != "" {
			f.EvidenceIDs = append(f.EvidenceIDs, execID)
		}
		f.EvidenceIDs = append(f.EvidenceIDs, matching(snap, journal, regexp.MustCompile(`(?i)executable|exec|No such file`))...)
		switch {
		case snap.ExecExists != nil && !*snap.ExecExists:
			f.Certainty = Proven
			f.Claim = fmt.Sprintf("%s does not start because the program it runs, %s, does not exist.", u, snap.ExecPath)
		default:
			f.Certainty = Likely
			f.Claim = fmt.Sprintf("%s does not start because systemd could not execute %s (status 203/EXEC) although it exists — not executable, or a wrong interpreter.", u, orDash(snap.ExecPath))
		}
		add(f)
	}
	if exitStatus == 217 || (snap.UserExists != nil && !*snap.UserExists) {
		ids := []string{show}
		if userID != "" {
			ids = append(ids, userID)
		}
		add(Finding{RuleID: "svc.account_missing", Certainty: Proven, EvidenceIDs: ids,
			Claim: fmt.Sprintf("%s does not start because its account %s does not exist.", u, orDash(snap.User)),
			Remedy: &Remedy{Action: "create", Target: RemedyTarget{Kind: "service_account", ID: snap.User},
				Before: map[string]any{"exists": false}, After: map[string]any{"exists": true},
				Rollback: Rollback{Action: "delete", Value: snap.User},
				Verify:   Verify{RuleAbsent: "svc.account_missing", Expect: map[string]any{"status": "running"}}}})
	}
	if exitStatus == 243 || exitStatus == 238 || exitStatus == 239 || exitStatus == 240 || exitStatus == 241 {
		add(Finding{RuleID: "svc.access_denied", Certainty: Proven, EvidenceIDs: append([]string{show}, matching(snap, journal, regexp.MustCompile(`(?i)denied|permission|directory`))...),
			Claim: fmt.Sprintf("%s does not start because systemd could not set up %s for it (status %d/%s).", u, strings.ToLower(strings.ReplaceAll(systemdStatus[exitStatus], "_", " ")), exitStatus, systemdStatus[exitStatus])})
	} else if ids := matching(snap, journal, permDeniedStateRe); len(ids) > 0 {
		add(Finding{RuleID: "svc.access_denied", Certainty: Likely, EvidenceIDs: append([]string{show}, ids...),
			Claim: u + " does not start because its account may not write its state directory (the journal reports Permission denied under /var)."})
	}
	if dep, ok := firstFailedDep(snap.Deps); ok || result == "dependency" {
		ids := []string{show}
		claim := u + " does not start because a unit it requires failed first."
		if ok {
			ids = append(ids, b.Evidence(Evidence{ID: "systemd:show:" + dep.Unit, Source: "systemctl show",
				Observed: endedAt(dep.Show, systemdStatusOf(dep.Show)), Raw: dep.Show,
				Fact: showFact(dep.Unit, dep.Show, atoi(dep.Show["ExecMainStatus"]))}))
			chain := ""
			if len(dep.Via) > 1 {
				chain = " (required via " + strings.Join(append(dep.Via[1:], dep.Unit), " → ") + ")"
			}
			claim = fmt.Sprintf("%s does not start because the unit it requires, %s%s, is %s.", u, dep.Unit, chain, depState(dep.Show))
		}
		ids = append(ids, matching(snap, journal, regexp.MustCompile(`Dependency failed`))...)
		add(Finding{RuleID: "svc.dependency_failed", Certainty: Proven, EvidenceIDs: ids, Claim: claim})
	}
	switch result {
	case "timeout":
		add(Finding{RuleID: "svc.timeout", Certainty: Proven, EvidenceIDs: []string{show},
			Claim: u + " did not report as started in time (Result=timeout)."})
	case "core-dump", "signal":
		sig := crashSignals[exitStatus]
		if result == "core-dump" || sig != "" {
			ids := []string{show}
			claim := fmt.Sprintf("%s crashed (Result=%s, signal %d%s).", u, result, exitStatus, ifNotEmpty(" "+sig, sig))
			// B14: WHERE it crashed, from the kernel's fault line and the module's symbols — no core dump.
			if cf := snap.Crash; cf != nil {
				if cf.Function != "" {
					sid := b.Evidence(Evidence{ID: "ksym:" + cf.Module + ":" + strconv.FormatUint(cf.Address, 16), Source: "kernel fault line + ELF symbols",
						Fact: fmt.Sprintf("%s faulted at %s+0x%x (ip 0x%x in %s, %s).", cf.Comm, cf.Function, cf.Displacement, cf.IP, cf.Module, cf.SymbolSource)})
					ids = append(ids, sid)
					where := cf.Kind
					if cf.FaultAddr != nil {
						where = fmt.Sprintf("%s at 0x%x", cf.Kind, *cf.FaultAddr)
					}
					claim = fmt.Sprintf("%s crashed: %s in %s (Result=%s).", u, where, cf.Function, result)
				} else if cf.Gap != "" {
					b.Gap("the function in which "+u+" crashed", cf.Gap)
				}
			}
			add(Finding{RuleID: "svc.crash", Certainty: Proven, EvidenceIDs: ids, Claim: claim})
		}
	case "oom-kill":
		add(Finding{RuleID: "svc.oom_killed", Certainty: Proven, EvidenceIDs: []string{show},
			Claim: u + " was killed by the kernel for lack of memory (Result=oom-kill)."})
	}
	// systemd 257 keeps Result=exit-code when the start limit refuses a restart and says so only in its own journal
	// message "Start request repeated too quickly" (measured 2026-10-17, Debian trixie) — that message is systemd's,
	// not the daemon's, so it is as direct as the Result field.
	if limit := matching(snap, journal, startLimitRe); result == "start-limit-hit" || len(limit) > 0 {
		add(Finding{RuleID: "svc.start_limit", Certainty: Proven, EvidenceIDs: append([]string{show}, limit...),
			Claim: fmt.Sprintf("systemd stopped restarting %s after too many failed starts (%s restarts).", u, orDash(s["NRestarts"]))})
	}
	// Only an EVALUATED condition: a unit that never ran (or was garbage-collected after a clean run) reports
	// ConditionResult=no with an empty ConditionTimestamp — measured 2026-10-17 on a finished oneshot and a masked unit.
	// ...and a skipped unit is garbage-collected right after, its condition properties reset too — what remains is
	// systemd's own journal message ("…was skipped because of an unmet condition check (ConditionPathExists=…)",
	// measured 2026-10-17 on Debian and AlmaLinux), as direct as the property.
	condLines := matching(snap, journal, conditionRe)
	if (s["ConditionResult"] == "no" && s["ConditionTimestamp"] != "") || (s["AssertResult"] == "no" && s["AssertTimestamp"] != "") ||
		(len(condLines) > 0 && s["ActiveState"] != "active") {
		add(Finding{RuleID: "svc.condition_failed", Certainty: Proven, EvidenceIDs: append([]string{show}, condLines...),
			Claim: u + " did not start because a start condition of the unit is not met."})
	}
	if result == "exit-code" && exitStatus != 0 && systemdStatus[exitStatus] == "" {
		add(Finding{RuleID: "svc.exits_immediately", Certainty: Proven, EvidenceIDs: []string{show},
			Claim: fmt.Sprintf("%s started and exited at once with its own error code %d.", u, exitStatus)})
	}
	for _, jr := range journalRules {
		if ids := matching(snap, journal, jr.re); len(ids) > 0 {
			add(Finding{RuleID: jr.rule, Certainty: Likely, EvidenceIDs: ids,
				Claim: fmt.Sprintf("%s fails because %s (read from its journal).", u, jr.title)})
		}
	}
	if len(hit) == 0 && (result == "success" || result == "") && s["ActiveState"] == "inactive" {
		claim := u + " is stopped and its last run ended without error."
		if s["Type"] == "oneshot" {
			claim = u + " is a oneshot unit that ran and finished without error — not running is its normal state."
		}
		add(Finding{RuleID: "svc.stopped_cleanly", Certainty: Proven, EvidenceIDs: []string{show}, Claim: claim})
	}
	return hit
}

func systemdStatusOf(s map[string]string) string {
	if s["LoadState"] == "not-found" {
		return StatusNotFound
	}
	switch s["ActiveState"] {
	case "active", "reloading":
		return StatusRunning
	case "activating":
		// "activating (auto-restart)" is not a start in progress: the program FAILED and systemd waits RestartSec
		// before the next attempt. Read as starting it got no finding at all — bacula-director, comitup and miredo
		// in the baseline cross-check (2026-10-17). It is a failure, with the last exit status as its evidence.
		if s["SubState"] == "auto-restart" {
			return StatusFailed
		}
		return StatusStarting
	case "failed":
		return StatusFailed
	case "inactive", "deactivating":
		return StatusStopped
	}
	return StatusUnknown
}

// endedAt is when the unit stopped — the time of the failure — or nil for a running unit.
func endedAt(s map[string]string, status string) *time.Time {
	if status == StatusRunning || status == StatusStarting {
		return nil
	}
	if t := unixTime(s["ExecMainExitTimestamp"]); t != nil {
		return t
	}
	return unixTime(s["InactiveEnterTimestamp"])
}

func showFact(unit string, s map[string]string, exitStatus int) string {
	f := fmt.Sprintf("%s is %s", unit, orDash(s["ActiveState"]))
	if sub := s["SubState"]; sub != "" && sub != s["ActiveState"] {
		f += " (" + sub + ")"
	}
	if s["LoadState"] != "" && s["LoadState"] != "loaded" {
		f += ", LoadState=" + s["LoadState"]
	}
	if r := s["Result"]; r != "" {
		f += ", Result=" + r
	}
	if exitStatus != 0 {
		f += ", ExecMainStatus=" + strconv.Itoa(exitStatus)
		if n := systemdStatus[exitStatus]; n != "" {
			f += " (" + n + ")"
		}
	}
	return f + "."
}

// firstFailedDep is the root of a failed dependency chain: the DEEPEST failed unit on it (a fails because b fails
// because c is masked — the finding points at c).
func firstFailedDep(deps []SystemdDep) (SystemdDep, bool) {
	var failed []SystemdDep
	for _, d := range deps {
		if depBroken(d.Show) {
			failed = append(failed, d)
		}
	}
	if len(failed) == 0 {
		return SystemdDep{}, false
	}
	sort.SliceStable(failed, func(i, j int) bool { return failed[i].Depth > failed[j].Depth })
	return failed[0], true
}

func depBroken(s map[string]string) bool {
	return s["ActiveState"] == "failed" || s["LoadState"] == "not-found" || s["LoadState"] == "masked"
}

func depState(s map[string]string) string {
	switch {
	case s["LoadState"] == "not-found":
		return "not installed"
	case s["LoadState"] == "masked":
		return "masked"
	}
	return "failed" + ifNotEmpty(" (Result="+s["Result"]+")", s["Result"])
}

// matching returns the journal evidence ids whose message matches re.
func matching(snap SystemdSnapshot, ids []string, re *regexp.Regexp) []string {
	var out []string
	for i, l := range snap.Journal {
		if i < len(ids) && re.MatchString(l.Message) {
			out = append(out, ids[i])
		}
	}
	return out
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func ifNotEmpty(s, cond string) string {
	if cond == "" {
		return ""
	}
	return s
}

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }

func stateWord(s string) string {
	switch s {
	case "R":
		return "running on a CPU"
	case "S":
		return "sleeping (interruptible wait)"
	case "D":
		return "in an uninterruptible wait (usually I/O)"
	case "T", "t":
		return "stopped"
	case "Z":
		return "a zombie"
	case "I":
		return "idle"
	}
	return "in state " + s
}

func wchanWords(w string) string {
	if w == "" || w == "0" {
		return ""
	}
	return " in the kernel function " + w
}

func uniq(xs []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, x := range xs {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	return out
}
