package modules

import (
	"context"
	"testing"
)

func TestDebconf_SetsWhenValueDiffers(t *testing.T) {
	var stdinCalls []string
	d := &Debconf{
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return []byte("* postfix/main_mailer_type: No configuration\n"), nil
		},
		RunnerStdin: func(ctx context.Context, stdin, name string, args ...string) ([]byte, error) {
			stdinCalls = append(stdinCalls, name+" "+joinArgs(args)+" <<< "+stdin)
			return nil, nil
		},
	}
	res, err := d.Run(context.Background(), map[string]any{
		"name": "postfix", "question": "postfix/main_mailer_type", "value": "Internet Site",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when value differs")
	}
	found := false
	for _, c := range stdinCalls {
		if c == "debconf-set-selections  <<< postfix postfix/main_mailer_type string Internet Site\n" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a debconf-set-selections call, got %v", stdinCalls)
	}
}

func TestDebconf_IdempotentWhenValueMatches(t *testing.T) {
	d := &Debconf{
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return []byte("* postfix/main_mailer_type: Internet Site\n"), nil
		},
		RunnerStdin: func(ctx context.Context, stdin, name string, args ...string) ([]byte, error) {
			t.Fatalf("unexpected mutating call: %s %v <<< %s", name, args, stdin)
			return nil, nil
		},
	}
	res, err := d.Run(context.Background(), map[string]any{
		"name": "postfix", "question": "postfix/main_mailer_type", "value": "Internet Site",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when value already matches")
	}
}

func TestDebconf_UnknownPackageTreatedAsUnset(t *testing.T) {
	var stdinCalled bool
	d := &Debconf{
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return nil, exitStatus(1)
		},
		RunnerStdin: func(ctx context.Context, stdin, name string, args ...string) ([]byte, error) {
			stdinCalled = true
			return nil, nil
		},
	}
	res, err := d.Run(context.Background(), map[string]any{
		"name": "newpkg", "question": "newpkg/q", "value": "x",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true for a package debconf has no record of")
	}
	if !stdinCalled {
		t.Error("expected debconf-set-selections to be called")
	}
}

func TestDebconf_UnseenClearsFlagWhenCurrentlySeen(t *testing.T) {
	var stdinCalls []string
	d := &Debconf{
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return []byte("* postfix/main_mailer_type: Internet Site\n"), nil
		},
		RunnerStdin: func(ctx context.Context, stdin, name string, args ...string) ([]byte, error) {
			stdinCalls = append(stdinCalls, name+" "+joinArgs(args)+" <<< "+stdin)
			return nil, nil
		},
	}
	res, err := d.Run(context.Background(), map[string]any{
		"name": "postfix", "question": "postfix/main_mailer_type", "value": "Internet Site", "unseen": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when unseen requested and question is currently seen")
	}
	found := false
	for _, c := range stdinCalls {
		if c == "debconf-communicate postfix <<< fset postfix/main_mailer_type seen false\n" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a debconf-communicate fset call, got %v", stdinCalls)
	}
}

func TestDebconf_DryRunDoesNotMutate(t *testing.T) {
	called := false
	d := &Debconf{
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return []byte(""), nil
		},
		RunnerStdin: func(ctx context.Context, stdin, name string, args ...string) ([]byte, error) {
			called = true
			return nil, nil
		},
	}
	res, err := d.Run(context.Background(), map[string]any{
		"name": "postfix", "question": "postfix/main_mailer_type", "value": "Internet Site", "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected dry_run to never call debconf-set-selections")
	}
}

func TestDebconf_InvalidVtypeRejected(t *testing.T) {
	d := NewDebconf()
	_, err := d.Run(context.Background(), map[string]any{
		"name": "postfix", "question": "q", "value": "x", "vtype": "bogus",
	}, false)
	if err == nil {
		t.Fatal("expected error for an invalid vtype")
	}
}
