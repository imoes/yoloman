package modules

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/diagnosis"
)

// ServiceDiagnose explains why a systemd unit does not run — deterministically, as a Diagnosis document (the shared
// contract configs/schemas/diagnosis.schema.json; the Windows agent's module of the same name emits the same shape).
// Read-only: it reads `systemctl show`, the unit's dependency chain, its account, its program and the journal of its
// current invocation, and changes nothing — remedies in the result are data for Bossman to propose, never run here.
type ServiceDiagnose struct {
	Runner CommandRunner
	Stat   func(string) (os.FileInfo, error)
	Now    func() time.Time
	Host   func() (string, error)
	// Incidents returns the agent's recent incident ring (OOM kills, fatal signals), newest first; nil = no history.
	// Injected by the server from the eBPF collector so the module stays independent and testable (plan E4).
	Incidents func() []diagnosis.Incident
}

// NewServiceDiagnose returns the module backed by the real systemctl/journalctl.
func NewServiceDiagnose() *ServiceDiagnose {
	return &ServiceDiagnose{Runner: defaultCommandRunner, Stat: os.Stat, Now: time.Now, Host: os.Hostname}
}

func (m *ServiceDiagnose) Name() string { return "service_diagnose" }

func (m *ServiceDiagnose) Description() string {
	return "" +
		"Explain why a service (systemd unit) does not run. Returns a Diagnosis: EVIDENCE (each measurement with a " +
		"stable id — systemd:show:<unit>, journal:<cursor>, file:stat:<path>, user:getent:<user>), FINDINGS (a rule " +
		"from configs/diagnosis_rules.json, a claim, a certainty Proven/Likely/Unknown, the evidence ids it rests " +
		"on), a timeline and named gaps. Deterministic and read-only: no model is involved and nothing is changed. A " +
		"unit that is not running always gets a finding — svc.unexplained (Unknown, naming what could not be " +
		"measured) when no rule matches. Rules: masked, unit missing, 203/EXEC program missing, 217/USER account " +
		"missing, state/credential directories, a failed required unit (the deepest failed link), timeout, crash, " +
		"OOM kill, start limit, unmet conditions, the program's own exit code, and causes read from the journal " +
		"(config invalid/incomplete, peer or network unreachable, needs initialisation, device missing, container " +
		"limit — these Likely).\n\n" +
		"Parameters: name (the unit, \"nginx\" or \"nginx.service\"), include_snapshot (also return the raw snapshot " +
		"the rules saw).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: none — `systemctl status`/`journalctl` via command and reading by hand.\n" +
		"- Chef/Puppet/Salt: none; their service resources report failure, not its cause.\n" +
		"- Terraform: not applicable."
}

func (m *ServiceDiagnose) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":             stringProp("The systemd unit to diagnose, e.g. \"nginx\" or \"nginx.service\"."),
		"include_snapshot": boolProp("Also return the snapshot the rules evaluated (systemctl properties, journal lines).", false),
	}, "name")
}

func (m *ServiceDiagnose) Writes() bool { return false }

func (m *ServiceDiagnose) Run(ctx context.Context, params map[string]any, _ bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	name = strings.TrimSpace(name)
	if name == "" || strings.ContainsAny(name, " /\\") {
		return Result{}, fmt.Errorf("service_diagnose: %q is not a unit name", name)
	}
	withSnap, err := boolParam(params, "include_snapshot", false)
	if err != nil {
		return Result{}, err
	}
	snap, err := diagnosis.CollectSystemd(ctx, diagnosis.Runner(m.Runner), m.Stat, name, m.Now())
	if err != nil {
		return Result{}, fmt.Errorf("service_diagnose: reading %s: %w", name, err)
	}
	// Past incidents for THIS unit's process, from the eBPF ring — matched by the kernel comm (the executable's base
	// name, truncated to 15 chars as the kernel reports it), since an OOM-killed process is gone and ran under its own pid.
	if m.Incidents != nil {
		snap.RecentIncidents = incidentsForUnit(snap.ExecPath, m.Incidents())
	}
	host, _ := m.Host()
	d, err := diagnosis.DiagnoseSystemd(snap, newDiagnosisID(), host)
	if err != nil {
		// A contract violation is a defect of a rule, never something to hand out as a diagnosis.
		return Result{}, fmt.Errorf("service_diagnose: %w", err)
	}
	data := map[string]any{"diagnosis": d}
	if withSnap {
		data["snapshot"] = snap
	}
	return Result{Changed: false, Msg: d.Summary, Data: data, DataSource: map[string]int{"attempts": 1, "produced": 1}}, nil
}

// incidentsForUnit picks the recent incidents whose process matches this unit's program, newest first, a few at most.
// The match is by the kernel comm — the executable's base name truncated to 15 chars (TASK_COMM_LEN-1), which is what
// oom:mark_victim and signal:signal_generate report. Nothing is written anywhere; this only reads the in-memory ring.
func incidentsForUnit(execPath string, all []diagnosis.Incident) []diagnosis.Incident {
	comm := execComm(execPath)
	if comm == "" {
		return nil
	}
	var out []diagnosis.Incident
	for _, inc := range all {
		if inc.Image == comm {
			out = append(out, inc)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) }) // newest first
	if len(out) > 10 {
		out = out[:10]
	}
	return out
}

// execComm is the executable's base name as the kernel reports `comm`: the file name, truncated to 15 characters.
func execComm(execPath string) string {
	base := filepath.Base(strings.TrimSpace(execPath))
	if base == "." || base == "/" || base == "" {
		return ""
	}
	if len(base) > 15 {
		base = base[:15]
	}
	return base
}

func newDiagnosisID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
