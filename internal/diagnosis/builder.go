package diagnosis

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// Builder assembles a Diagnosis and refuses anything the contract forbids — at the moment it is added, so a rule
// that tries to claim without evidence fails in its own test, not later in Bossman.
type Builder struct {
	d       Diagnosis
	cat     Catalogue
	ids     map[string]int
	refused []string
	changes []change
}

// PrecedentWindow bounds how far back a change may lie and still be offered as a finding's precedent. An older change
// stays on the timeline; it is not offered, because after a week nearly everything on a host has changed once and the
// nearest change no longer says anything about this failure.
const PrecedentWindow = 7 * 24 * time.Hour

// change is a candidate precedent: a recorded evidence that is a change, and when it happened.
type change struct {
	id, what string
	at       time.Time
	hostWide bool
}

// NewBuilder starts a diagnosis of target on host. id must be unique per run (callers pass a UUID).
func NewBuilder(id, host, platform string, target Target, collectedAt time.Time) (*Builder, error) {
	c, err := LoadCatalogue()
	if err != nil {
		return nil, err
	}
	if platform != "windows" && platform != "linux" {
		return nil, fmt.Errorf("diagnosis: unknown platform %q", platform)
	}
	return &Builder{
		d: Diagnosis{Schema: SchemaID, DiagnosisID: id, Host: host, Platform: platform, Target: target,
			CollectedAt: collectedAt.UTC().Truncate(time.Second), Evidence: []Evidence{}, Findings: []Finding{},
			Timeline: []TimelineEntry{}, Gaps: []Gap{}},
		cat: c, ids: map[string]int{},
	}, nil
}

// Evidence records one measurement and returns its id. A second evidence with the same id is refused (ids are
// stable names of a measurement — two different readings cannot share one).
func (b *Builder) Evidence(e Evidence) string {
	if e.ID == "" || !strings.Contains(e.ID, ":") || e.Source == "" || e.Fact == "" {
		b.refused = append(b.refused, fmt.Sprintf("evidence %q: id (source:locator), source and fact are required", e.ID))
		return e.ID
	}
	if _, dup := b.ids[e.ID]; dup {
		b.refused = append(b.refused, fmt.Sprintf("evidence %q recorded twice", e.ID))
		return e.ID
	}
	if e.Observed != nil {
		t := e.Observed.UTC().Truncate(time.Second)
		e.Observed = &t
	}
	b.ids[e.ID] = len(b.d.Evidence)
	b.d.Evidence = append(b.d.Evidence, e)
	return e.ID
}

// Has reports whether an evidence id was recorded.
func (b *Builder) Has(id string) bool { _, ok := b.ids[id]; return ok }

// Find adds a finding, or refuses it with the reason.
func (b *Builder) Find(f Finding) error {
	if err := b.check(f); err != nil {
		b.refused = append(b.refused, err.Error())
		return err
	}
	if f.Precedent != nil {
		p := *f.Precedent
		p.Observed = p.Observed.UTC().Truncate(time.Second)
		f.Precedent = &p
	}
	b.d.Findings = append(b.d.Findings, f)
	return nil
}

// Unexplained adds svc.unexplained: the target is not running and no rule explained it. The gap says what could not
// be measured; the evidence ids are what WAS read.
func (b *Builder) Unexplained(evidenceIDs []string, gap string) error {
	return b.Find(Finding{RuleID: "svc.unexplained", Certainty: Unknown, EvidenceIDs: evidenceIDs, Gap: Str(gap),
		Claim: fmt.Sprintf("%s is not running and no rule explains why.", b.d.Target.Name)})
}

// Change offers a recorded evidence as a candidate precedent: what changed, and when. hostWide marks a change of the
// host (a package, an update) rather than of the target itself or the units/services it depends on (its unit file,
// its program, its service key).
func (b *Builder) Change(evidenceID, what string, at time.Time, hostWide bool) {
	if !b.Has(evidenceID) {
		b.refused = append(b.refused, fmt.Sprintf("change %q: evidence was not recorded", evidenceID))
		return
	}
	b.changes = append(b.changes, change{id: evidenceID, what: what, at: at.UTC().Truncate(time.Second), hostWide: hostWide})
}

// Precede gives every finding that has none the most recent change at or before failedAt within PrecedentWindow — a
// change of the target when there is one, otherwise a change of the host. Nothing is attached when nothing changed in
// that window: no precedent is a statement too ("nothing changed in the 7 days before"), not a gap.
func (b *Builder) Precede(failedAt time.Time) {
	failedAt = failedAt.UTC().Truncate(time.Second)
	pick := func(hostWide bool) *change {
		var best *change
		for i := range b.changes {
			c := &b.changes[i]
			if c.hostWide != hostWide || c.at.After(failedAt) || failedAt.Sub(c.at) > PrecedentWindow {
				continue
			}
			if best == nil || c.at.After(best.at) {
				best = c
			}
		}
		return best
	}
	c := pick(false)
	if c == nil {
		c = pick(true)
	}
	if c == nil {
		return
	}
	for i := range b.d.Findings {
		f := &b.d.Findings[i]
		if f.Precedent != nil || (len(f.EvidenceIDs) == 1 && f.EvidenceIDs[0] == c.id) {
			continue
		}
		f.Precedent = &Precedent{EvidenceID: c.id, Change: c.what, Observed: c.at, GapSeconds: int64(failedAt.Sub(c.at) / time.Second)}
	}
}

// Gap records something the agent could not observe at all.
func (b *Builder) Gap(what, why string) { b.d.Gaps = append(b.d.Gaps, Gap{What: what, Why: why}) }

func (b *Builder) check(f Finding) error {
	rule, ok := b.cat[f.RuleID]
	switch {
	case !ok:
		return fmt.Errorf("finding %s: rule is not in the catalogue", f.RuleID)
	case !rule.appliesTo(b.d.Platform):
		return fmt.Errorf("finding %s: rule does not apply to platform %s", f.RuleID, b.d.Platform)
	case f.Claim == "":
		return fmt.Errorf("finding %s: a finding states its claim", f.RuleID)
	case len(f.EvidenceIDs) == 0:
		return fmt.Errorf("finding %s: a claim without evidence is not a finding", f.RuleID)
	}
	if _, known := certaintyRank[f.Certainty]; !known {
		return fmt.Errorf("finding %s: unknown certainty %q", f.RuleID, f.Certainty)
	}
	if certaintyRank[f.Certainty] > certaintyRank[rule.Certainty] {
		return fmt.Errorf("finding %s: certainty %s exceeds the rule's maximum %s", f.RuleID, f.Certainty, rule.Certainty)
	}
	if f.Certainty == Unknown && (f.Gap == nil || *f.Gap == "") {
		return fmt.Errorf("finding %s: Unknown must name what could not be measured", f.RuleID)
	}
	for _, id := range f.EvidenceIDs {
		if !b.Has(id) {
			return fmt.Errorf("finding %s: cites evidence that was not recorded: %s", f.RuleID, id)
		}
	}
	if p := f.Precedent; p != nil {
		if !b.Has(p.EvidenceID) {
			return fmt.Errorf("finding %s: precedent cites evidence that was not recorded: %s", f.RuleID, p.EvidenceID)
		}
		if len(f.EvidenceIDs) == 1 && f.EvidenceIDs[0] == p.EvidenceID {
			return fmt.Errorf("finding %s: the only evidence is the precedent — a preceding change is a correlation, not a cause", f.RuleID)
		}
	}
	if r := f.Remedy; r != nil && !rule.offers(r.Target.Kind) {
		return fmt.Errorf("finding %s: remedy kind %s is not one the rule offers", f.RuleID, r.Target.Kind)
	}
	return nil
}

// ErrRefused is returned by Build when anything was refused on the way — the document would not hold.
var ErrRefused = errors.New("diagnosis: contract violations")

// Build orders the findings by the catalogue, derives timeline and summary, and checks the whole document.
func (b *Builder) Build(status string) (*Diagnosis, error) {
	b.d.Status = status
	sort.SliceStable(b.d.Findings, func(i, j int) bool {
		return b.cat[b.d.Findings[i].RuleID].Order < b.cat[b.d.Findings[j].RuleID].Order
	})
	b.d.Timeline = timeline(b.d.Evidence)
	switch {
	case len(b.d.Findings) > 0:
		b.d.Summary = b.d.Findings[0].Claim
	case status == StatusRunning:
		b.d.Summary = fmt.Sprintf("%s is running.", b.d.Target.Name)
	default:
		b.d.Summary = fmt.Sprintf("%s is %s.", b.d.Target.Name, status)
	}
	problems := append([]string{}, b.refused...)
	problems = append(problems, Validate(&b.d, b.cat)...)
	if len(problems) > 0 {
		return &b.d, fmt.Errorf("%w: %s", ErrRefused, strings.Join(problems, "; "))
	}
	return &b.d, nil
}

// timeline lists every evidence with an observed time, ascending; equal times keep the order they were recorded.
func timeline(ev []Evidence) []TimelineEntry {
	out := []TimelineEntry{}
	for _, e := range ev {
		if e.Observed != nil {
			out = append(out, TimelineEntry{Observed: *e.Observed, EvidenceID: e.ID})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Observed.Before(out[j].Observed) })
	return out
}
