package runbook

import "testing"

func TestGonjaSubstituteNativeTypesAndFilters(t *testing.T) {
	ctx := map[string]any{"network": map[string]any{"method": "static", "dns": []any{"10.0.0.1", "1.1.1.1"}}}
	// whole {{ expr }} with a filter must return a NATIVE list, not a string
	v, err := substitute("{{ network.dns | default([]) }}", ctx)
	if err != nil {
		t.Fatalf("substitute dns: %v", err)
	}
	lst, ok := v.([]any)
	if !ok || len(lst) != 2 || lst[0] != "10.0.0.1" {
		t.Fatalf("dns did not resolve to a native list: %#v", v)
	}
	// default filter on a MISSING key → the default value (empty list), still native
	v2, err := substitute("{{ network.search | default([]) }}", ctx)
	if err != nil {
		t.Fatalf("substitute missing: %v", err)
	}
	if l2, ok := v2.([]any); !ok || len(l2) != 0 {
		t.Fatalf("missing|default([]) should be empty list, got %#v", v2)
	}
	// when: `is defined` test
	for expr, want := range map[string]bool{
		"network.method is defined":  true,
		"network.missing is defined": false,
		"network.method == 'static'": true,
	} {
		got, err := evalWhen(expr, ctx)
		if err != nil {
			t.Fatalf("when %q: %v", expr, err)
		}
		if got != want {
			t.Errorf("when %q = %v, want %v", expr, got, want)
		}
	}
	// embedded placeholder → string
	s, err := substitute("iface {{ network.method }} up", ctx)
	if err != nil || s != "iface static up" {
		t.Fatalf("embedded render: %v / %q", err, s)
	}
}
