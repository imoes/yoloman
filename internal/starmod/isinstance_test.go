package starmod

import (
	"testing"

	"go.starlark.net/starlark"
)

// A tiny module that exercises the isinstance shim on both branches and the
// tuple form, returning a contract-shaped result.
const isinstanceModule = `
def main(ctx, params):
    v = params["v"]
    is_str = isinstance(v, str)
    is_num = isinstance(v, (int, float))
    return {"changed": False, "msg": "ok", "data": {"is_str": is_str, "is_num": is_num}}
`

func TestExecute_IsInstanceShim(t *testing.T) {
	caps := stubCaps{} // read-only stub backend; module does no I/O
	cases := []struct {
		v                any
		wantStr, wantNum bool
	}{
		{"hello", true, false},
		{float64(7), false, true}, // JSON integer -> Starlark int
		{3.5, false, true},        // JSON float -> Starlark float
		{true, false, true},       // bool counts as int (Python semantics)
	}
	for _, c := range cases {
		res, err := Execute("isinstance.star", []byte(isinstanceModule), map[string]any{"v": c.v}, caps, Options{})
		if err != nil {
			t.Fatalf("Execute(%v): %v", c.v, err)
		}
		data, _ := res.Data.(map[string]any)
		if data["is_str"] != c.wantStr || data["is_num"] != c.wantNum {
			t.Errorf("v=%v: is_str=%v is_num=%v, want %v/%v", c.v, data["is_str"], data["is_num"], c.wantStr, c.wantNum)
		}
	}
}

func TestIsInstanceMatch_UnsupportedAndTuple(t *testing.T) {
	// A non-type second arg is a clear error, not a silent false.
	if _, err := isInstanceMatch(starlark.String("x"), starlark.MakeInt(1)); err == nil {
		t.Error("expected error for non-type classinfo")
	}
	// Tuple membership.
	tup := starlark.Tuple{starlark.Universe["int"], starlark.Universe["float"]}
	m, err := isInstanceMatch(starlark.MakeInt(1), tup)
	if err != nil || !m {
		t.Errorf("int in (int,float): m=%v err=%v", m, err)
	}
}
