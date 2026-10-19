package modules

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/diagnosis"
)

// UpdateDiagnose explains why a Linux host is behind on updates — deterministically, as a Diagnosis document (the
// shared contract configs/schemas/diagnosis.schema.json, target kind "updates"; the Windows agent's module of the same
// name returns the same shape). Read-only: it reads the package manager's state (apt/dnf) and changes nothing.
type UpdateDiagnose struct {
	Runner CommandRunner
	Stat   func(string) (os.FileInfo, error)
	Now    func() time.Time
	Host   func() (string, error)
}

// NewUpdateDiagnose returns the module backed by the real apt/dnf.
func NewUpdateDiagnose() *UpdateDiagnose {
	return &UpdateDiagnose{Runner: defaultCommandRunner, Stat: os.Stat, Now: time.Now, Host: os.Hostname}
}

func (m *UpdateDiagnose) Name() string { return "update_diagnose" }

func (m *UpdateDiagnose) Description() string {
	return "" +
		"Explain why a host is behind on updates. Returns a Diagnosis (the same contract as service_diagnose, target " +
		"kind \"updates\"): EVIDENCE from the package manager (apt/dnf) — upgradable packages with the security count, " +
		"held packages, a pending reboot, an interrupted dpkg, an unreachable repository — FINDINGS (a rule from " +
		"configs/diagnosis_rules.json: upd.behind, upd.up_to_date, upd.reboot_pending, upd.held, upd.dpkg_interrupted, " +
		"upd.repo_unreachable), a timeline and named gaps. Deterministic and read-only: no model, nothing changed; it " +
		"runs only simulated/listing commands (apt-get -s upgrade, dnf list --upgrades, apt-mark showhold, dpkg --audit).\n\n" +
		"Parameters: include_snapshot (also return the snapshot the rules saw).\n\n" +
		"Cross-tool equivalents:\n- Ansible: none — apt/dnf report counts, they do not explain being behind.\n" +
		"- Chef/Puppet/Salt: none."
}

func (m *UpdateDiagnose) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"include_snapshot": boolProp("Also return the snapshot the rules evaluated (the package-manager state).", false),
	})
}

func (m *UpdateDiagnose) Writes() bool { return false }

func (m *UpdateDiagnose) Run(ctx context.Context, params map[string]any, _ bool) (Result, error) {
	withSnap, err := boolParam(params, "include_snapshot", false)
	if err != nil {
		return Result{}, err
	}
	host, _ := m.Host()
	snap := diagnosis.CollectUpdates(ctx, diagnosis.Runner(m.Runner), m.Stat, host, m.Now())
	d, err := diagnosis.DiagnoseUpdates(snap, newDiagnosisID(), host)
	if err != nil {
		return Result{}, fmt.Errorf("update_diagnose: %w", err)
	}
	data := map[string]any{"diagnosis": d}
	if withSnap {
		data["snapshot"] = snap
	}
	return Result{Changed: false, Msg: d.Summary, Data: data, DataSource: map[string]int{"attempts": 1, "produced": 1}}, nil
}
