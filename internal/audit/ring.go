package audit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"strings"
	"sync"
	"time"
)

// newID returns a random 16-byte hex id. crypto/rand rather than a uuid
// dependency: the id only has to be unique and stable, and the agent's
// dependency list is a thing worth keeping short.
func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Cannot happen on any supported platform; a time-derived id is still
		// unique enough to point at one record and better than an empty one.
		return hex.EncodeToString([]byte(time.Now().UTC().Format(time.RFC3339Nano)))
	}
	return hex.EncodeToString(b[:])
}

// WHAT THIS HOST DID, kept so it can be asked afterwards.
//
// The journal line the Logger already writes is the right thing for a human with
// `journalctl`, and the wrong thing for two other readers: Bossman, which needs to
// collect it fleet-wide with a cursor, and an AI asked "did that install work",
// which needs the evidence and not a one-line summary. Hence this ring: the same
// calls, in memory, addressable.
//
// THE WIRE SHAPE IS THE C# AGENT'S, field for field (AgenticMcp.Agent.Core/
// OperationLog.cs). One collector reads both agents; a field spelled differently
// here is a field Bossman silently stops reading for half the fleet.
const RingCapacity = 1000

// Outcomes. Exhaustive, and each one is a different thing that happened —
// collapsing any two makes a real question unanswerable ("how many operations
// failed" cannot be answered if a host's refusal and our own crash share a name).
const (
	OutcomeChanged   = "changed"        // the host is different now
	OutcomeUnchanged = "unchanged"      // it was already as asked — the idempotence claim
	OutcomePlanned   = "planned"        // a dry run: a preview, nothing was done
	OutcomeRefused   = "refused"        // the TARGET said no; its words are in Error
	OutcomeError     = "error"          // this agent broke — a fact about us
	OutcomeTimedOut  = "timed-out"      // the caller stopped waiting; MAY HAVE COMPLETED
	OutcomeUnknown   = "unknown-module" // a call for a tool this host does not have
)

// Record is one operation. JSON names match the C# agent exactly.
type Record struct {
	Seq        int64          `json:"seq"`
	ID         string         `json:"id"`
	Module     string         `json:"module"`
	Outcome    string         `json:"outcome"`
	DryRun     bool           `json:"dry_run"`
	Params     map[string]any `json:"params,omitempty"`
	Identity   string         `json:"identity,omitempty"`
	StartedAt  time.Time      `json:"started_at"`
	DurationMS float64        `json:"duration_ms"`
	Changed    *bool          `json:"changed,omitempty"`
	Message    string         `json:"message,omitempty"`
	// The module's own Data block, verbatim: exit codes, before/after state, the
	// plan it produced for itself. A verdict without it is an opinion.
	Evidence any    `json:"evidence,omitempty"`
	Error    string `json:"error,omitempty"`
}

// Page is what GET /api/v1/audit answers.
type Page struct {
	// This agent PROCESS. Sequence numbers restart with it, so a cursor only means
	// something against the boot it was taken from — without this a collector
	// cannot tell a restart from "nothing new" and either skips or repeats a whole
	// boot's worth of records.
	BootID    string `json:"boot_id"`
	OldestSeq int64  `json:"oldest_seq"`
	NewestSeq int64  `json:"newest_seq"`
	// How many records the ring discarded since this process started. NOTHING
	// VANISHES SILENTLY: a collector that fell behind learns that it did.
	Dropped  int64    `json:"dropped"`
	Capacity int      `json:"capacity"`
	Count    int      `json:"count"`
	Records  []Record `json:"records"`
}

var (
	ringMu  sync.Mutex
	ring    []Record
	ringSeq int64
	dropped int64
	bootID  = newID()
)

// BootID identifies this agent process.
func BootID() string { return bootID }

// Push appends one record to the ring and returns it with its sequence number.
// Parameters are redacted with the same rule the journal line uses — a log that
// records a password once has already leaked it.
func Push(rec Record) Record {
	rec.Params = redactParams(rec.Params)
	if rec.ID == "" {
		rec.ID = newID()
	}
	ringMu.Lock()
	defer ringMu.Unlock()
	ringSeq++
	rec.Seq = ringSeq
	ring = append(ring, rec)
	if len(ring) > RingCapacity {
		drop := len(ring) - RingCapacity
		ring = ring[drop:]
		dropped += int64(drop)
	}
	return rec
}

// ReadPage returns the records after sinceSeq (nil = from the oldest held),
// optionally filtered by module and outcome. Filters are ANDed.
func ReadPage(sinceSeq *int64, module, outcome string, limit int) Page {
	if limit <= 0 || limit > RingCapacity {
		limit = 200
	}
	ringMu.Lock()
	defer ringMu.Unlock()

	page := Page{BootID: bootID, Dropped: dropped, Capacity: RingCapacity, Records: []Record{}}
	if len(ring) > 0 {
		// The RING's range, not the page's: a collector needs to know what the agent
		// still holds to tell "nothing new" from "I asked for records already gone".
		page.OldestSeq = ring[0].Seq
		page.NewestSeq = ring[len(ring)-1].Seq
	}
	for _, rec := range ring {
		if sinceSeq != nil && rec.Seq <= *sinceSeq {
			continue
		}
		if module != "" && !strings.EqualFold(rec.Module, module) {
			continue
		}
		if outcome != "" && !strings.EqualFold(rec.Outcome, outcome) {
			continue
		}
		page.Records = append(page.Records, rec)
		if len(page.Records) >= limit {
			break
		}
	}
	page.Count = len(page.Records)
	return page
}

// ResetRingForTests forgets everything. Not reachable over HTTP: an operation log
// an operator can clear is an operation log an operator can hide behind.
func ResetRingForTests() {
	ringMu.Lock()
	defer ringMu.Unlock()
	ring = nil
	ringSeq = 0
	dropped = 0
}

// ClassifyOutcome turns what a dispatch knows into one of the named outcomes.
//
// The mapping is deliberate on two points. A module error becomes REFUSED rather
// than `error`, because rest.go answers a module error with 422 — the target or
// the parameters said no, which is a fact about the host, and the host's own words
// travel in Error. And a cancelled/deadline-exceeded context becomes TIMED-OUT
// rather than a failure, because the operation MAY HAVE COMPLETED (measured on the
// Windows side: a feature install outlasted the caller and finished anyway).
func ClassifyOutcome(dryRun, changed bool, err error) string {
	switch {
	case err != nil && (errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)):
		return OutcomeTimedOut
	case err != nil:
		return OutcomeRefused
	case dryRun:
		return OutcomePlanned
	case changed:
		return OutcomeChanged
	default:
		return OutcomeUnchanged
	}
}
