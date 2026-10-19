package diagnosis

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

// UpdateSnapshot is what the update rules look at on Linux, collected once from the package manager (read-only). The
// rules (DiagnoseUpdates) are a pure function over it, tested on hand-built snapshots; CollectUpdates fills it by
// running apt/dnf through the agent's Runner and is exercised live in a pod. Mirrors the Windows UpdateSnapshot.
type UpdateSnapshot struct {
	Host            string          `json:"host"`
	Family          string          `json:"family"` // debian | redhat
	Manager         string          `json:"manager"`
	Upgradable      []UpgradablePkg `json:"upgradable"`
	SecurityCount   int             `json:"security_count"`
	Held            []string        `json:"held"`
	RebootRequired  bool            `json:"reboot_required"`
	RebootReason    string          `json:"reboot_reason"`
	DpkgInterrupted bool            `json:"dpkg_interrupted"`
	RepoErrors      []string        `json:"repo_errors"`
	ManagerError    string          `json:"manager_error"`
	// SnapshotTarget is whether / sits on a snapshot-capable volume — the rollback point for an update remedy
	// (plan U4). When kind is "none" an update install has no way back, so no reversible remedy is offered.
	SnapshotTarget SnapshotTarget `json:"snapshot_target"`
	CollectedAt    time.Time      `json:"collected_at"`
}

// SnapshotTarget is the volume a pre-update snapshot would be taken of, the rollback point for an update remedy.
type SnapshotTarget struct {
	Kind   string `json:"kind"`             // lvm | zfs | none
	ID     string `json:"id,omitempty"`     // vg/lv (lvm) or dataset (zfs)
	Layout string `json:"layout,omitempty"` // lvm only: thin | thick
	Reason string `json:"reason,omitempty"` // why none
}

// UpgradablePkg is one package with an available newer version.
type UpgradablePkg struct {
	Name     string `json:"name"`
	Security bool   `json:"security"`
}

// DiagnoseUpdates applies the upd.* rules to a Linux update snapshot and returns a Diagnosis (target kind "updates").
func DiagnoseUpdates(snap UpdateSnapshot, id, host string) (*Diagnosis, error) {
	b, err := NewBuilder(id, host, "linux", Target{Kind: "updates", Name: snap.Host}, snap.CollectedAt)
	if err != nil {
		return nil, err
	}

	stateFact := fmt.Sprintf("%s reports %d upgradable package(s)", snap.Manager, len(snap.Upgradable))
	if snap.SecurityCount > 0 {
		stateFact += fmt.Sprintf(", %d from the security suite", snap.SecurityCount)
	}
	stateFact += "."
	stateID := b.Evidence(Evidence{ID: "upd:state:" + Key(snap.Host), Source: snap.Manager, Fact: stateFact,
		Raw: map[string]any{"upgradable": len(snap.Upgradable), "security": snap.SecurityCount, "family": snap.Family}})

	findings := 0

	// A previous package operation left dpkg half-done: nothing installs until it is configured.
	if snap.DpkgInterrupted {
		did := b.Evidence(Evidence{ID: "upd:dpkg:" + Key(snap.Host), Source: "dpkg --audit",
			Fact: "dpkg reports packages in an interrupted state; `dpkg --configure -a` is needed before any update.",
			Raw: map[string]any{"dpkg_interrupted": true}})
		if b.Find(Finding{RuleID: "upd.dpkg_interrupted", Certainty: Proven, EvidenceIDs: []string{did},
			Claim: fmt.Sprintf("A previous package operation on %s was interrupted; dpkg must be configured (`dpkg --configure -a`) before updates can proceed.", snap.Host)}) == nil {
			findings++
		}
	}

	// A pending reboot blocks the update from completing.
	if snap.RebootRequired {
		rid := b.Evidence(Evidence{ID: "upd:reboot:" + Key(snap.Host), Source: "stat /run/reboot-required",
			Fact: "A reboot is pending (" + orText(snap.RebootReason, "/run/reboot-required exists") + ").",
			Raw: map[string]any{"reboot_required": true, "reason": snap.RebootReason}})
		if b.Find(Finding{RuleID: "upd.reboot_pending", Certainty: Proven, EvidenceIDs: []string{rid},
			Claim: fmt.Sprintf("A reboot is pending on %s, needed to finish applied updates.", snap.Host)}) == nil {
			findings++
		}
	}

	// A repository that could not be reached (Likely — the mirror could be momentarily down).
	if len(snap.RepoErrors) > 0 {
		eid := b.Evidence(Evidence{ID: "upd:repo:" + Key(snap.Host), Source: snap.Manager,
			Fact: "A package repository was unreachable: " + strings.Join(snap.RepoErrors, "; "),
			Raw: map[string]any{"repo_errors": snap.RepoErrors}})
		if b.Find(Finding{RuleID: "upd.repo_unreachable", Certainty: Likely, EvidenceIDs: []string{eid},
			Claim: fmt.Sprintf("%s could not reach a package repository on the last update, so the pending list may be incomplete.", snap.Host)}) == nil {
			findings++
		}
	}

	// Packages held back on purpose.
	if len(snap.Held) > 0 {
		hid := b.Evidence(Evidence{ID: "upd:held:" + Key(snap.Host), Source: snap.Manager,
			Fact: fmt.Sprintf("%d package(s) are held back: %s.", len(snap.Held), strings.Join(snap.Held, ", ")),
			Raw: map[string]any{"held": snap.Held}})
		if b.Find(Finding{RuleID: "upd.held", Certainty: Proven, EvidenceIDs: []string{hid},
			Claim: fmt.Sprintf("%d package(s) on %s are held back and will not upgrade: %s.", len(snap.Held), snap.Host, strings.Join(snap.Held, ", "))}) == nil {
			findings++
		}
	}

	// The state: behind or up-to-date.
	if len(snap.Upgradable) > 0 {
		claim := fmt.Sprintf("%s is behind on updates: %d upgradable", snap.Host, len(snap.Upgradable))
		if snap.SecurityCount > 0 {
			claim += fmt.Sprintf(", %d from the security suite", snap.SecurityCount)
		}
		f := Finding{RuleID: "upd.behind", Certainty: Proven, EvidenceIDs: []string{stateID}, Claim: claim + "."}
		// A remedy only when there is a real rollback point — a snapshot of the root volume. Otherwise the fix is
		// irreversible, so no reversible remedy is offered; the gap names why and points at the usual tooling.
		if snap.SnapshotTarget.Kind == "lvm" || snap.SnapshotTarget.Kind == "zfs" {
			f.Remedy = updateRemedy(snap.SnapshotTarget, snap.Manager)
		} else {
			b.Gap("a rollback point for the update",
				orText(snap.SnapshotTarget.Reason, "/ is not on a snapshot-capable volume")+
					" — install via a patch ring or apt/dnf after taking your own backup")
		}
		if b.Find(f) == nil {
			findings++
		}
	} else if snap.ManagerError == "" && len(snap.Held) == 0 {
		if b.Find(Finding{RuleID: "upd.up_to_date", Certainty: Proven, EvidenceIDs: []string{stateID},
			Claim: fmt.Sprintf("%s has no pending updates.", snap.Host)}) == nil {
			findings++
		}
	}

	clean := len(snap.Upgradable) == 0 && !snap.RebootRequired && !snap.DpkgInterrupted &&
		len(snap.Held) == 0 && len(snap.RepoErrors) == 0 && snap.ManagerError == ""
	status := StatusUpToDate
	if !clean {
		status = StatusBehind
	}

	if !clean && findings == 0 {
		gap := snap.ManagerError
		if gap == "" {
			gap = "the package manager's state could not be classified"
		}
		if err := b.Find(Finding{RuleID: "upd.unexplained", Certainty: Unknown, EvidenceIDs: []string{stateID},
			Gap: &gap, Claim: fmt.Sprintf("The update state of %s could not be explained from what the package manager returned.", snap.Host)}); err != nil {
			return nil, err
		}
	}
	if snap.ManagerError != "" {
		b.Gap("a complete package-manager read", snap.ManagerError)
	}

	return b.Build(status)
}

// updateRemedy proposes installing the pending updates with a snapshot of the root volume as the rollback point (plan
// U4). It is a PROPOSAL and an exported playbook for a person — the snapshot is taken first, the updates installed, and
// the rollback restores the snapshot; never auto-run. Only called when the volume is LVM or ZFS.
func updateRemedy(st SnapshotTarget, manager string) *Remedy {
	const tag = "preupdate"
	var snapCmd, restoreCmd, snapName string
	switch st.Kind {
	case "lvm":
		vg, lv := splitVGLV(st.ID)
		snapName = lv + "-" + tag
		snapCmd = fmt.Sprintf("lvcreate --snapshot --name %s %s/%s", snapName, vg, lv)
		restoreCmd = fmt.Sprintf("lvconvert --merge %s/%s && reboot", vg, snapName)
	case "zfs":
		snapName = st.ID + "@" + tag
		snapCmd = fmt.Sprintf("zfs snapshot %s", snapName)
		restoreCmd = fmt.Sprintf("zfs rollback %s", snapName)
	}
	installCmd := "apt-get -y dist-upgrade"
	if manager == "dnf" {
		installCmd = "dnf -y upgrade"
	}
	return &Remedy{
		Action: "install",
		Target: RemedyTarget{Kind: "package", ID: "pending updates"},
		Before: map[string]any{"snapshot_command": snapCmd, "volume": st.ID, "kind": st.Kind,
			"note": "take the snapshot before installing, so it can be rolled back to"},
		After:    map[string]any{"installed": "the pending updates", "install_command": installCmd},
		Rollback: Rollback{Action: "restore", Value: map[string]any{"snapshot": snapName, "command": restoreCmd}},
		Verify:   Verify{RuleAbsent: "upd.behind", Expect: map[string]any{"status": "up-to-date"}},
	}
}

// splitVGLV splits "vg/lv" into its parts.
func splitVGLV(id string) (string, string) {
	if i := strings.IndexByte(id, '/'); i >= 0 {
		return id[:i], id[i+1:]
	}
	return id, id
}

func orText(s, fallback string) string {
	if strings.TrimSpace(s) == "" {
		return fallback
	}
	return s
}

// CollectUpdates reads the package-manager state read-only (apt on debian, dnf on redhat). Best-effort: a command that
// fails leaves its part empty or recorded as a gap, never an error for the whole snapshot.
func CollectUpdates(ctx context.Context, run Runner, stat func(string) (os.FileInfo, error), host string, now time.Time) UpdateSnapshot {
	snap := UpdateSnapshot{Host: host, CollectedAt: now}
	if _, err := stat("/etc/debian_version"); err == nil {
		snap.Family, snap.Manager = "debian", "apt"
		collectApt(ctx, run, stat, &snap)
	} else if _, err := stat("/etc/redhat-release"); err == nil {
		snap.Family, snap.Manager = "redhat", "dnf"
		collectDnf(ctx, run, stat, &snap)
	} else {
		snap.ManagerError = "no supported package manager found (/etc/debian_version, /etc/redhat-release)"
	}
	if _, err := stat("/run/reboot-required"); err == nil {
		snap.RebootRequired = true
		snap.RebootReason = "/run/reboot-required exists"
	}
	if snap.Family != "" {
		snap.SnapshotTarget = detectSnapshotTarget(ctx, run)
	}
	return snap
}

// detectSnapshotTarget reads (read-only) whether / is on an LVM logical volume or a ZFS dataset — the volume a
// pre-update snapshot would be taken of, so the update remedy has a real rollback point (plan U4a). Neither → "none"
// with the reason, and the remedy layer offers no reversible fix rather than a fake rollback.
func detectSnapshotTarget(ctx context.Context, run Runner) SnapshotTarget {
	out, err := run(ctx, "findmnt", "-n", "-o", "SOURCE,FSTYPE", "/")
	fields := strings.Fields(string(out))
	if len(fields) < 2 {
		reason := "could not read the root mount (findmnt)"
		if err != nil {
			reason += ": " + clip(err.Error(), 120)
		}
		return SnapshotTarget{Kind: "none", Reason: reason}
	}
	source, fstype := fields[0], fields[1]
	if fstype == "zfs" {
		return SnapshotTarget{Kind: "zfs", ID: source} // findmnt gives the dataset as the source
	}
	if lv, _ := run(ctx, "lvs", "--noheadings", "-o", "vg_name,lv_name,lv_layout", source); len(strings.TrimSpace(string(lv))) > 0 {
		f := strings.Fields(string(lv))
		if len(f) >= 2 {
			layout := "thick"
			if len(f) >= 3 && strings.Contains(f[2], "thin") {
				layout = "thin"
			}
			return SnapshotTarget{Kind: "lvm", ID: f[0] + "/" + f[1], Layout: layout}
		}
	}
	return SnapshotTarget{Kind: "none",
		Reason: fmt.Sprintf("/ is on %s (%s), not a snapshot-capable volume (LVM or ZFS)", source, fstype)}
}

func collectApt(ctx context.Context, run Runner, stat func(string) (os.FileInfo, error), snap *UpdateSnapshot) {
	// `apt-get -s upgrade` lists the planned installs as "Inst <name> ... (<ver> <origins> ...)"; a security update's
	// origins contain "Security". Simulation only — it changes nothing.
	out, err := run(ctx, "apt-get", "-s", "-o", "Debug::NoLocking=true", "upgrade")
	if err != nil && len(out) == 0 {
		snap.ManagerError = "apt-get -s upgrade failed: " + clip(err.Error(), 160)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.HasPrefix(line, "Inst ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		sec := strings.Contains(line, "Security")
		snap.Upgradable = append(snap.Upgradable, UpgradablePkg{Name: fields[1], Security: sec})
		if sec {
			snap.SecurityCount++
		}
	}
	// repos unreachable show up in `apt-get update` stderr; we do not run update (it writes caches), so only read a
	// failing simulation error above. Held packages:
	if hold, _ := run(ctx, "apt-mark", "showhold"); len(strings.TrimSpace(string(hold))) > 0 {
		for _, h := range strings.Fields(string(hold)) {
			snap.Held = append(snap.Held, h)
		}
	}
	// dpkg interrupted / half-configured:
	if audit, _ := run(ctx, "dpkg", "--audit"); len(strings.TrimSpace(string(audit))) > 0 {
		snap.DpkgInterrupted = true
	}
}

func collectDnf(ctx context.Context, run Runner, stat func(string) (os.FileInfo, error), snap *UpdateSnapshot) {
	// `dnf -q list --upgrades` exits 0 and lists "name.arch  version  repo" under a header; avoid check-update's exit 100.
	out, _ := run(ctx, "dnf", "-q", "list", "--upgrades")
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "Available") || strings.HasPrefix(line, "Last metadata") || strings.HasPrefix(line, "Obsoleting") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.Contains(fields[0], ".") {
			snap.Upgradable = append(snap.Upgradable, UpgradablePkg{Name: fields[0]})
		}
	}
	// Security count from updateinfo (best-effort; the plugin is usually present on RHEL-likes).
	if sec, _ := run(ctx, "dnf", "-q", "updateinfo", "list", "security"); len(sec) > 0 {
		n := 0
		for _, line := range strings.Split(string(sec), "\n") {
			if strings.Contains(line, "/Sec.") || strings.Contains(strings.ToLower(line), "security") && strings.Contains(line, " ") {
				n++
			}
		}
		snap.SecurityCount = n
	}
	// versionlock (held) — the plugin may be absent; ignore its error.
	if vl, _ := run(ctx, "dnf", "-q", "versionlock", "list"); len(strings.TrimSpace(string(vl))) > 0 {
		for _, line := range strings.Split(string(vl), "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "Last metadata") && !strings.HasPrefix(line, "#") {
				snap.Held = append(snap.Held, line)
			}
		}
	}
}
