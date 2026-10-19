package diagnosis

import (
	"fmt"
	"time"
)

// Incident kinds — the shared vocabulary with the Windows agent (AgenticMcp.Agent.Diagnosis/Incident.cs). Linux uses
// oom-kill and fatal-signal, read from the agent's eBPF collector; the Windows-only kinds are listed for parity.
const (
	IncidentProcessExit = "process-exit"
	IncidentImageCrash  = "image-crash"
	IncidentException   = "exception"
	IncidentOOMKill     = "oom-kill"
	IncidentFatalSignal = "fatal-signal"
)

// Incident is one recorded PAST event the diagnosis looks back on (plan docs/etw-ringbuffer-plan.md): a service that
// was OOM-killed or hit a fatal signal before now, so a transient failure stays explainable after the fact. Metadata
// only — pid, comm, time, the signal — never any payload. On Linux the agent's eBPF collector is the ring (it already
// keeps recent oom:mark_victim and signal:signal_generate events); Source is "ebpf" and is also the evidence-id
// prefix. An incident is always Likely, never Proven: it describes a past invocation, not the present state.
type Incident struct {
	Kind   string    `json:"kind"`
	At     time.Time `json:"at"`
	PID    int       `json:"pid"`
	Image  string    `json:"image"` // the kernel comm / executable name of the process
	Detail string    `json:"detail,omitempty"`
	Source string    `json:"source"` // "ebpf" on Linux
}

// EvidenceID is stable for the same event: <source>:<kind>:<pid>:<unix-ms>.
func (i Incident) EvidenceID() string {
	return fmt.Sprintf("%s:%s:%d:%d", i.Source, i.Kind, i.PID, i.At.UTC().UnixMilli())
}

func (i Incident) iso() string { return i.At.UTC().Format("2006-01-02T15:04:05Z") }

func (i Incident) fact() string {
	who := fmt.Sprintf("process %d (%s)", i.PID, i.Image)
	switch i.Kind {
	case IncidentOOMKill:
		return who + " was killed by the out-of-memory killer at " + i.iso() + "."
	case IncidentFatalSignal:
		sig := "a fatal signal"
		if i.Detail != "" {
			sig = "signal " + i.Detail
		}
		return who + " was killed by " + sig + " at " + i.iso() + "."
	case IncidentProcessExit:
		return who + " exited abnormally at " + i.iso() + "."
	default:
		return who + ": " + i.Kind + " at " + i.iso() + "."
	}
}

// toEvidence turns the incident into an Evidence record for the diagnosis document.
func (i Incident) toEvidence() Evidence {
	t := i.At.UTC()
	raw := map[string]any{"kind": i.Kind, "pid": i.PID, "image": i.Image, "at": i.iso()}
	if i.Detail != "" {
		raw["detail"] = i.Detail
	}
	return Evidence{ID: i.EvidenceID(), Source: "ebpf-incident-ring", Observed: &t, Fact: i.fact(), Raw: raw}
}
