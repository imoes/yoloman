package starmod

import (
	"testing"
)

// A module that exercises every member of the predeclared `regex` module and
// returns the results in the contract's data dict.
const regexModuleSrc = `
def main(ctx, params):
    s = params["s"]
    return {"changed": False, "msg": "ok", "data": {
        "test_start": regex.test("^ng", s),
        "test_mid": regex.test("in", s),
        "test_no": regex.test("^zzz", s),
        "match_start": regex.match("ng", s),
        "match_notstart": regex.match("inx", s),
        "search_hit": regex.search("n.i", s),
        "search_miss": regex.search("[0-9]+", s),
        "findall": regex.findall("[a-z]+", "a1bb2ccc"),
        "sub": regex.sub("[0-9]+", "_", "a1b22c"),
        "escape": regex.escape("a.b*c"),
    }}
`

func TestExecute_RegexModule(t *testing.T) {
	res, err := Execute("regex.star", []byte(regexModuleSrc), map[string]any{"s": "nginx"}, stubCaps{}, Options{})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	data, _ := res.Data.(map[string]any)

	checks := map[string]any{
		"test_start":     true,
		"test_mid":       true, // "in" appears anywhere (search semantics)
		"test_no":        false,
		"match_start":    true,  // "ng" matches at position 0
		"match_notstart": false, // "inx" is present but not at the start
		"search_hit":     "ngi", // "n.i" -> "ngi"
		"search_miss":    nil,   // no digits -> None
		"sub":            "a_b_c",
		"escape":         `a\.b\*c`,
	}
	for k, want := range checks {
		if got := data[k]; got != want {
			t.Errorf("%s = %#v, want %#v", k, got, want)
		}
	}
	// findall returns a list ["a","bb","ccc"]
	fa, ok := data["findall"].([]any)
	if !ok || len(fa) != 3 || fa[0] != "a" || fa[1] != "bb" || fa[2] != "ccc" {
		t.Errorf("findall = %#v, want [a bb ccc]", data["findall"])
	}
}

func TestRegex_BadPatternFailsLoudly(t *testing.T) {
	src := `
def main(ctx, params):
    return {"changed": False, "msg": "x", "data": {"r": regex.test("(", "abc")}}
`
	if _, err := Execute("bad.star", []byte(src), map[string]any{}, stubCaps{}, Options{}); err == nil {
		t.Fatal("an invalid regex pattern must fail the execution, not silently not-match")
	}
}
