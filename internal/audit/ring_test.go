package audit

import (
	"context"
	"errors"
	"testing"
	"time"
)

func push(t *testing.T, module, outcome string) Record {
	t.Helper()
	return Push(Record{Module: module, Outcome: outcome, StartedAt: time.Now().UTC(),
		Params:   map[string]any{"name": "x", "password": "hunter2"},
		Evidence: map[string]any{"exit_code": 0}})
}

func TestRing_CursorAndFilters(t *testing.T) {
	ResetRingForTests()
	push(t, "apt", OutcomeChanged)
	push(t, "service", OutcomeRefused)
	third := push(t, "apt", OutcomeUnchanged)

	if page := ReadPage(nil, "", "", 0); page.Count != 3 {
		t.Fatalf("want 3 records, got %d", page.Count)
	}
	if page := ReadPage(nil, "apt", "", 0); page.Count != 2 {
		t.Fatalf("module filter: want 2, got %d", page.Count)
	}
	if page := ReadPage(nil, "apt", OutcomeChanged, 0); page.Count != 1 {
		t.Fatalf("ANDed filters: want 1, got %d", page.Count)
	}
	cursor := int64(2)
	page := ReadPage(&cursor, "", "", 0)
	if page.Count != 1 || page.Records[0].Seq != third.Seq {
		t.Fatalf("cursor: want only seq %d, got %+v", third.Seq, page.Records)
	}
	if page.BootID != BootID() || page.BootID == "" {
		t.Fatalf("a page must name the process it came from, got %q", page.BootID)
	}
}

func TestRing_RedactsSecretsButKeepsTheKey(t *testing.T) {
	ResetRingForTests()
	rec := push(t, "apt", OutcomeChanged)
	if rec.Params["password"] == "hunter2" {
		t.Fatal("the password was written into the operation log")
	}
	// "A password was passed" is part of what happened; the value never is.
	if _, ok := rec.Params["password"]; !ok {
		t.Fatal("the parameter name must survive redaction")
	}
	if rec.Params["name"] != "x" {
		t.Fatalf("a non-secret parameter must pass through, got %v", rec.Params["name"])
	}
}

func TestRing_DroppedIsReportedRatherThanSilent(t *testing.T) {
	ResetRingForTests()
	for range RingCapacity + 5 {
		push(t, "apt", OutcomeUnchanged)
	}
	page := ReadPage(nil, "", "", RingCapacity)
	if page.Count != RingCapacity {
		t.Fatalf("want a full ring, got %d", page.Count)
	}
	if page.Dropped != 5 {
		t.Fatalf("a collector that fell behind must learn by how much: want 5, got %d", page.Dropped)
	}
	if page.OldestSeq != 6 || page.NewestSeq != int64(RingCapacity+5) {
		t.Fatalf("the ring's range is wrong: %d..%d", page.OldestSeq, page.NewestSeq)
	}
}

func TestClassifyOutcome_EachCaseIsItsOwn(t *testing.T) {
	cases := []struct {
		name    string
		dryRun  bool
		changed bool
		err     error
		want    string
	}{
		{"a write that changed the host", false, true, nil, OutcomeChanged},
		{"already as asked", false, false, nil, OutcomeUnchanged},
		// A dry run is a preview: filing it as "unchanged" is how a plan gets mistaken for a no-op.
		{"a preview", true, false, nil, OutcomePlanned},
		// The module said no — a fact about the host, answered with 422, not our crash.
		{"the target refused", false, false, errors.New("Storage Services cannot be removed"), OutcomeRefused},
		// MAY HAVE COMPLETED. Measured on Windows: a feature install outlasted the caller and finished.
		{"the caller stopped waiting", false, false, context.DeadlineExceeded, OutcomeTimedOut},
		{"cancelled", false, false, context.Canceled, OutcomeTimedOut},
	}
	for _, tc := range cases {
		if got := ClassifyOutcome(tc.dryRun, tc.changed, tc.err); got != tc.want {
			t.Errorf("%s: want %q, got %q", tc.name, tc.want, got)
		}
	}
}

func TestLogResult_RecordsEvenWithoutAJournalWriter(t *testing.T) {
	ResetRingForTests()
	var logger *Logger // nil: auditing to the journal is off
	rec := logger.LogResult("CN=bossman", "apt", true, false, true, "installed", map[string]any{"exit_code": 0},
		map[string]any{"name": "nginx"}, time.Now().Add(-50*time.Millisecond), nil)
	if rec.Outcome != OutcomeChanged || rec.Seq != 1 {
		t.Fatalf("want the first record as changed, got %+v", rec)
	}
	// The ring belongs to the process, not to the journal writer: an agent with auditing off must not
	// become a host that cannot say what it did.
	if ReadPage(nil, "", "", 0).Count != 1 {
		t.Fatal("a nil Logger must still fill the ring")
	}
	if rec.DurationMS <= 0 {
		t.Fatalf("duration must be measured, got %v", rec.DurationMS)
	}
}
