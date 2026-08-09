package modules

import (
	"context"
	"strings"
	"testing"
)

// fakeIptables simulates `iptables -C/-A/-I/-D`, tracking which exact rule
// argv strings are currently "present", recording mutating calls.
type fakeIptables struct {
	rules map[string]bool // joined rule args -> present
	calls []string
}

func ruleKey(args []string) string { return strings.Join(args, " ") }

func (f *fakeIptables) runner() CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		f.calls = append(f.calls, name+" "+joinArgs(args))
		// args[0..1] = "-t" "<table>"; args[2] = "-C"/"-A"/"-I"/"-D"; args[3] = chain; rest = rule match args
		flag := args[2]
		chain := args[3]
		rule := ruleKey(append([]string{chain}, args[4:]...))
		switch flag {
		case "-C":
			if f.rules[rule] {
				return nil, nil
			}
			return nil, exitStatus(1)
		case "-A", "-I":
			f.rules[rule] = true
		case "-D":
			delete(f.rules, rule)
		}
		return nil, nil
	}
}

func TestIptables_AddsRuleWhenAbsent(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	res, err := i.Run(context.Background(), map[string]any{
		"chain": "INPUT", "protocol": "tcp", "destination_port": "80", "jump": "ACCEPT",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true adding a new rule")
	}
	if len(fake.rules) != 1 {
		t.Errorf("expected 1 rule tracked, got %d", len(fake.rules))
	}
}

func TestIptables_IdempotentWhenAlreadyPresent(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	args := map[string]any{"chain": "INPUT", "protocol": "tcp", "destination_port": "80", "jump": "ACCEPT"}
	if _, err := i.Run(context.Background(), args, false); err != nil {
		t.Fatal(err)
	}
	res, err := i.Run(context.Background(), args, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when rule already exists")
	}
}

func TestIptables_InsertUsesDashI(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	if _, err := i.Run(context.Background(), map[string]any{
		"chain": "INPUT", "jump": "DROP", "action": "insert",
	}, false); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range fake.calls {
		if strings.Contains(c, "-I INPUT") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected an -I INPUT call, got %v", fake.calls)
	}
}

func TestIptables_AbsentRemovesExisting(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	args := map[string]any{"chain": "INPUT", "protocol": "tcp", "destination_port": "22", "jump": "ACCEPT"}
	if _, err := i.Run(context.Background(), args, false); err != nil {
		t.Fatal(err)
	}
	res, err := i.Run(context.Background(), map[string]any{
		"chain": "INPUT", "protocol": "tcp", "destination_port": "22", "jump": "ACCEPT", "state": "absent",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing an existing rule")
	}
	if len(fake.rules) != 0 {
		t.Error("expected rule to be removed")
	}
}

func TestIptables_AbsentIdempotentWhenMissing(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	res, err := i.Run(context.Background(), map[string]any{
		"chain": "INPUT", "protocol": "tcp", "destination_port": "9999", "jump": "DROP", "state": "absent",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing a rule that doesn't exist")
	}
}

func TestIptables_MissingJumpForPresentErrors(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	_, err := i.Run(context.Background(), map[string]any{"chain": "INPUT"}, false)
	if err == nil {
		t.Fatal("expected error when jump is missing for state=present")
	}
}

func TestIptables_InvalidStateRejected(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	_, err := i.Run(context.Background(), map[string]any{"chain": "INPUT", "jump": "ACCEPT", "state": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for invalid state")
	}
}

func TestIptables_InvalidActionRejected(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	_, err := i.Run(context.Background(), map[string]any{"chain": "INPUT", "jump": "ACCEPT", "action": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for invalid action")
	}
}

func TestIptables_CheckFailurePropagatesError(t *testing.T) {
	i := &Iptables{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte("iptables: command not found"), exitStatus(127)
	}}
	_, err := i.Run(context.Background(), map[string]any{"chain": "INPUT", "jump": "ACCEPT"}, false)
	if err == nil {
		t.Fatal("expected error when the check itself fails (not just returns 'not found')")
	}
}

func TestIptables_ApplyFailurePropagatesError(t *testing.T) {
	i := &Iptables{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if len(args) > 2 && args[2] == "-C" {
			return nil, exitStatus(1) // not present
		}
		return []byte("iptables: Bad argument"), exitStatus(2)
	}}
	_, err := i.Run(context.Background(), map[string]any{"chain": "INPUT", "jump": "ACCEPT"}, false)
	if err == nil {
		t.Fatal("expected error when adding the rule fails")
	}
}

func TestIptables_DryRunDoesNotMutate(t *testing.T) {
	fake := &fakeIptables{rules: map[string]bool{}}
	i := &Iptables{Runner: fake.runner()}
	res, err := i.Run(context.Background(), map[string]any{
		"chain": "INPUT", "jump": "ACCEPT", "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if len(fake.rules) != 0 {
		t.Error("expected dry_run to not actually add the rule")
	}
}
