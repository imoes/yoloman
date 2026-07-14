package modules

import (
	"context"
	"testing"
)

func TestDebugReturnsMsg(t *testing.T) {
	res, err := NewDebug().Run(context.Background(), map[string]any{"msg": "hello nginx"}, false)
	if err != nil {
		t.Fatalf("debug: %v", err)
	}
	if res.Changed {
		t.Error("debug must never report changed")
	}
	if res.Msg != "hello nginx" {
		t.Errorf("debug msg = %q, want %q", res.Msg, "hello nginx")
	}
}

func TestSetFactReturnsAnsibleFacts(t *testing.T) {
	res, err := NewSetFact().Run(context.Background(), map[string]any{"web_pkg": "nginx", "count": 4, "cacheable": true}, false)
	if err != nil {
		t.Fatalf("set_fact: %v", err)
	}
	if res.Changed {
		t.Error("set_fact must not report host change")
	}
	data, ok := res.Data.(map[string]any)
	if !ok {
		t.Fatalf("set_fact data type = %T", res.Data)
	}
	facts, ok := data["ansible_facts"].(map[string]any)
	if !ok {
		t.Fatalf("set_fact ansible_facts missing/typed wrong: %v", data)
	}
	if facts["web_pkg"] != "nginx" || facts["count"] != 4 {
		t.Errorf("facts = %v, want web_pkg=nginx count=4", facts)
	}
	if _, present := facts["cacheable"]; present {
		t.Error("cacheable must not be published as a fact")
	}
}
