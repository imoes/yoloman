package diagnosis

import (
	"fmt"
	"sort"
)

// Validate is the document check of bossman/bossman/services/diagnosis_contract.py, in Go: everything the JSON
// schema cannot express. Each violation is a sentence; an empty result means the document holds.
func Validate(d *Diagnosis, cat Catalogue) []string {
	var out []string
	if d.Schema != SchemaID {
		out = append(out, fmt.Sprintf("schema is %q, want %q", d.Schema, SchemaID))
	}
	ev := map[string]Evidence{}
	for _, e := range d.Evidence {
		if _, dup := ev[e.ID]; dup {
			out = append(out, fmt.Sprintf("evidence id %s is not unique", e.ID))
		}
		ev[e.ID] = e
	}
	for i, f := range d.Findings {
		where := fmt.Sprintf("findings/%d (%s)", i, f.RuleID)
		rule, ok := cat[f.RuleID]
		if !ok {
			out = append(out, where+": rule is not in configs/diagnosis_rules.json")
			continue
		}
		if !rule.appliesTo(d.Platform) {
			out = append(out, where+": rule does not apply to platform "+d.Platform)
		}
		if certaintyRank[f.Certainty] > certaintyRank[rule.Certainty] {
			out = append(out, fmt.Sprintf("%s: certainty %s exceeds the rule's maximum %s", where, f.Certainty, rule.Certainty))
		}
		if len(f.EvidenceIDs) == 0 {
			out = append(out, where+": a claim without evidence is not a finding")
		}
		for _, id := range f.EvidenceIDs {
			if _, ok := ev[id]; !ok {
				out = append(out, where+": cites evidence that is not in the diagnosis: "+id)
			}
		}
		if f.Certainty == Unknown && (f.Gap == nil || *f.Gap == "") {
			out = append(out, where+": Unknown must name what could not be measured")
		}
		if p := f.Precedent; p != nil {
			if _, ok := ev[p.EvidenceID]; !ok {
				out = append(out, where+": precedent cites evidence that is not in the diagnosis: "+p.EvidenceID)
			}
			if len(f.EvidenceIDs) == 1 && f.EvidenceIDs[0] == p.EvidenceID {
				out = append(out, where+": the only evidence is the precedent — a preceding change is a correlation, not a cause")
			}
		}
		if r := f.Remedy; r != nil && !rule.offers(r.Target.Kind) {
			out = append(out, fmt.Sprintf("%s: remedy kind %s is not one the rule offers", where, r.Target.Kind))
		}
	}
	switch d.Status {
	case StatusStopped, StatusFailed, StatusNotFound, StatusUnknown, StatusBehind:
		if len(d.Findings) == 0 {
			out = append(out, "status is "+d.Status+" but there is no finding — svc.unexplained / upd.unexplained (Unknown, with the gap) is the finding for 'no rule matched'")
		}
	case StatusRunning, StatusStarting, StatusUpToDate:
	default:
		out = append(out, fmt.Sprintf("status %q is not a contract status", d.Status))
	}
	// timeline = exactly the evidence with an observed time, in time order, each at its evidence's time
	var timed, listed []string
	for _, e := range d.Evidence {
		if e.Observed != nil {
			timed = append(timed, e.ID)
		}
	}
	for i, t := range d.Timeline {
		listed = append(listed, t.EvidenceID)
		if i > 0 && t.Observed.Before(d.Timeline[i-1].Observed) {
			out = append(out, "timeline is not in time order")
		}
		if e, ok := ev[t.EvidenceID]; ok && e.Observed != nil && !e.Observed.Equal(t.Observed) {
			out = append(out, "timeline entry "+t.EvidenceID+" has another time than its evidence")
		}
	}
	sort.Strings(timed)
	sort.Strings(listed)
	if fmt.Sprint(timed) != fmt.Sprint(listed) {
		out = append(out, "timeline must list exactly the evidence that has an observed time")
	}
	return out
}
