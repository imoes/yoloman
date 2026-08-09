package modules

import (
	"context"
	"testing"
)

func TestPing_ReturnsPong(t *testing.T) {
	p := NewPing()
	res, err := p.Run(context.Background(), map[string]any{}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false")
	}
	if res.Data.(map[string]any)["ping"] != "pong" {
		t.Errorf("expected ping=pong, got %v", res.Data)
	}
}

func TestPing_IsReadOnly(t *testing.T) {
	if NewPing().Writes() {
		t.Error("expected ping to be read-only")
	}
}
