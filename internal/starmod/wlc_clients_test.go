package starmod

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// wlc_clients.star, the one HAND-WRITTEN check in the translated catalogue — the batch could not produce
// parsable Starlark for it. Hand-written code needs the tests the batch's validator would otherwise have
// been, so these run the shipped file against canned snmpwalk output for both device families Checkmk
// supports.

// snmpCaps answers each snmpwalk with the output recorded for its OID, and rc=1 for anything unrecorded —
// which is how "this device does not have that table" is expressed to the module.
type snmpCaps struct{ byOID map[string]string }

func (c snmpCaps) CheckMode() bool { return false }

func (c snmpCaps) Run(argv []string, _ bool, _ []int) (RunResult, error) {
	oid := argv[len(argv)-1]
	if out, ok := c.byOID[oid]; ok {
		return RunResult{RC: 0, Stdout: out}, nil
	}
	return RunResult{RC: 1}, nil
}

func (c snmpCaps) FileRead(string) (string, error)                { return "", nil }
func (c snmpCaps) FileWrite(string, string, string) (bool, error) { return false, nil }
func (c snmpCaps) FileExists(string) (bool, error)                { return false, nil }
func (c snmpCaps) Stat(string) (map[string]any, error)            { return nil, nil }
func (c snmpCaps) Facts() (map[string]any, error)                 { return map[string]any{}, nil }
func (c snmpCaps) Probe(string, map[string]any) (map[string]any, error) {
	return map[string]any{"error": ""}, nil
}

const (
	airespaceOID = ".1.3.6.1.4.1.14179.2.1.1.1"
	clients9800  = ".1.3.6.1.4.1.14179.2.1.1.1.38"
	ssid9800     = ".1.3.6.1.4.1.9.9.512.1.1.1.1.4"
)

// A classic controller: two SSIDs, the first served by two interfaces. Column 2 is the SSID, 42 the
// interface, 38 the client count — the shape snmpwalk -Oqn prints, quotes included for string columns.
const airespaceWalk = `.1.3.6.1.4.1.14179.2.1.1.1.2.1 "corp"
.1.3.6.1.4.1.14179.2.1.1.1.2.2 "guest"
.1.3.6.1.4.1.14179.2.1.1.1.42.1 "mgmt"
.1.3.6.1.4.1.14179.2.1.1.1.42.2 "guest-vlan"
.1.3.6.1.4.1.14179.2.1.1.1.38.1 17
.1.3.6.1.4.1.14179.2.1.1.1.38.2 4
`

func loadWlc(t *testing.T) []byte {
	t.Helper()
	src, err := os.ReadFile("../../configs/checks.d/wlc_clients.star")
	if err != nil {
		t.Fatalf("read wlc_clients.star: %v", err)
	}
	return src
}

func runWlc(t *testing.T, caps snmpCaps, params map[string]any) map[string]any {
	t.Helper()
	res, err := Execute("wlc_clients.star", loadWlc(t), params, caps, Options{})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	data, ok := res.Data.(map[string]any)
	if !ok {
		t.Fatalf("data is %T, want map", res.Data)
	}
	return data
}

func airespace() snmpCaps {
	return snmpCaps{byOID: map[string]string{airespaceOID: airespaceWalk}}
}

func TestWlcClients_DiscoversSummaryFirstThenEverySSID(t *testing.T) {
	data := runWlc(t, airespace(), map[string]any{"_discover": true})
	items, ok := data["discovery"].([]any)
	if !ok {
		t.Fatalf("discovery is %T, want list", data["discovery"])
	}
	if len(items) != 3 {
		t.Fatalf("discovered %d services, want 3 (Summary + two SSIDs)", len(items))
	}
	// Summary FIRST: it is the one service that survives an SSID list changing with every campaign.
	if first := items[0].(map[string]any)["item"]; first != "Summary" {
		t.Errorf("first item = %v, want Summary", first)
	}
	names := map[string]bool{}
	for _, it := range items {
		names[it.(map[string]any)["item"].(string)] = true
	}
	if !names["corp"] || !names["guest"] {
		t.Errorf("discovered %v, want corp and guest", names)
	}
}

func TestWlcClients_SummaryIsTheTotalOverEverySSID(t *testing.T) {
	data := runWlc(t, airespace(), map[string]any{"item": "Summary"})
	wantState(t, data, "OK")
	wantMetric(t, data, "connections", 21) // 17 + 4
}

func TestWlcClients_AnSSIDReportsItsInterfacesInTheDetails(t *testing.T) {
	// This is the branch the batch kept failing on: Checkmk builds it with a comprehension over dict items,
	// which Starlark has no equivalent for.
	data := runWlc(t, airespace(), map[string]any{"item": "corp"})
	wantMetric(t, data, "connections", 17)
	if details, _ := data["details"].(string); !strings.Contains(details, "mgmt: 17") {
		t.Errorf("details = %q, want the interface breakdown", details)
	}
}

func TestWlcClients_UpperLevelsAsAListAndAsAString(t *testing.T) {
	for _, levels := range []any{[]any{10, 20}, "10,20"} {
		data := runWlc(t, airespace(), map[string]any{"item": "corp", "levels": levels})
		wantState(t, data, "WARN") // 17 >= 10, < 20
	}
	data := runWlc(t, airespace(), map[string]any{"item": "corp", "levels": []any{5, 15}})
	wantState(t, data, "CRIT") // 17 >= 15
}

func TestWlcClients_LowerLevelsCatchTheEmptySSID(t *testing.T) {
	// A guest network nobody is on is the interesting case, and it is the reason levels_lower exists.
	data := runWlc(t, airespace(), map[string]any{"item": "guest", "levels_lower": []any{5, 2}})
	wantState(t, data, "WARN") // 4 < 5, not < 2
	data = runWlc(t, airespace(), map[string]any{"item": "guest", "levels_lower": []any{10, 5}})
	wantState(t, data, "CRIT") // 4 < 5
}

func TestWlcClients_AVanishedSSIDIsUnknownNotZero(t *testing.T) {
	// The service was discovered, so the operator needs "this SSID is gone" rather than a zero that reads
	// like an idle network.
	data := runWlc(t, airespace(), map[string]any{"item": "conference"})
	wantState(t, data, "UNKNOWN")
	if metrics, _ := data["metrics"].(map[string]any); len(metrics) != 0 {
		t.Errorf("metrics = %v, want none for a missing SSID", metrics)
	}
}

func TestWlcClients_Catalyst9800ZipsItsTwoTablesByPosition(t *testing.T) {
	// The 9800 keeps SSIDs and client counts in two differently-indexed tables and returns them in the same
	// order — Checkmk's own parser zips them, so this one does too.
	caps := snmpCaps{byOID: map[string]string{
		ssid9800: ".1.3.6.1.4.1.9.9.512.1.1.1.1.4.1 \"office\"\n.1.3.6.1.4.1.9.9.512.1.1.1.1.4.2 \"iot\"\n",
		clients9800: ".1.3.6.1.4.1.14179.2.1.1.1.38.1 30\n" +
			".1.3.6.1.4.1.14179.2.1.1.1.38.2 2\n",
	}}
	data := runWlc(t, caps, map[string]any{"item": "Summary"})
	wantMetric(t, data, "connections", 32)

	data = runWlc(t, caps, map[string]any{"item": "iot"})
	wantMetric(t, data, "connections", 2)
}

func TestWlcClients_NoControllerDiscoversNothing(t *testing.T) {
	// Detection is BY DATA rather than by a list of product OIDs, so "not a WLAN controller" has to come out
	// as an empty discovery and not as an error.
	data := runWlc(t, snmpCaps{byOID: map[string]string{}}, map[string]any{"_discover": true})
	items, _ := data["discovery"].([]any)
	if len(items) != 0 {
		t.Errorf("discovered %d services on a device with no client table, want 0", len(items))
	}
}

func TestWlcClients_NoControllerIsUnknownWhenChecked(t *testing.T) {
	data := runWlc(t, snmpCaps{byOID: map[string]string{}}, map[string]any{"item": "Summary"})
	wantState(t, data, "UNKNOWN")
}

func TestWlcClients_ItNeverMutates(t *testing.T) {
	// The whole catalogue is read-only; a check that could write would be a different kind of object.
	rep := Validate("wlc_clients.star", loadWlc(t), Options{ParamsJSON: []byte(`{"item":"Summary"}`)})
	if !rep.OK || !rep.StubOK {
		t.Fatalf("validation failed: %+v", rep.Errors)
	}
	for _, call := range rep.Calls {
		if strings.Contains(call, "mutates=true") {
			t.Errorf("a read-only check recorded a mutating call: %s", call)
		}
	}
}

// THE DIALECT TRAP THAT MADE THIS TEST FILE WORTH WRITING.
//
// A Starlark string is not iterable. `for c in s[i:]` raises "string value is not iterable" at RUNTIME, on
// the very line that parses a number out of device output — and the stub validator only sees it when its
// empty-output run happens to reach that line, which for a check gated on `if res.rc != 0: return` it does
// not. Eight shipped checks carried it; a ninth would have if this one had not been hand-written and tested
// against real output. The guard is here rather than in a linter because it costs nothing and reads as what
// it is.
func TestNoCheckIteratesAStarlarkString(t *testing.T) {
	files, err := filepath.Glob("../../configs/checks.d/*.star")
	if err != nil || len(files) == 0 {
		t.Fatalf("glob checks.d: %v (%d files)", err, len(files))
	}
	// `for <var> in <name>[...]:` where the body compares <var> to a character literal — the shape that is a
	// string walk rather than a list walk.
	loop := regexp.MustCompile(`for\s+(\w+)\s+in\s+(\w+)\[[^\]]*\]\s*:`)
	for _, file := range files {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("read %s: %v", file, err)
		}
		for _, m := range loop.FindAllSubmatchIndex(src, -1) {
			variable := string(src[m[2]:m[3]])
			end := m[1] + 240
			if end > len(src) {
				end = len(src)
			}
			body := string(src[m[1]:end])
			if regexp.MustCompile(`\b` + regexp.QuoteMeta(variable) + `\s*(==|>=|<=|>|<)\s*"`).MatchString(body) {
				t.Errorf("%s iterates a string (%s) — use `for i in range(len(s))` and index it",
					filepath.Base(file), string(src[m[0]:m[1]]))
			}
		}
	}
}
