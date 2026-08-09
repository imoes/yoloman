package modules

import (
	"context"
	"strings"
	"testing"
)

type fakeDpkg struct {
	selections map[string]string
	stdinCalls []string
}

func (f *fakeDpkg) runner() CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name != "dpkg" || len(args) < 2 || args[0] != "--get-selections" {
			return nil, nil
		}
		pkg := args[1]
		sel, ok := f.selections[pkg]
		if !ok {
			return nil, exitStatus(1)
		}
		return []byte(pkg + "\t" + sel + "\n"), nil
	}
}

func (f *fakeDpkg) runnerStdin() CommandRunnerWithStdin {
	return func(ctx context.Context, stdin string, name string, args ...string) ([]byte, error) {
		f.stdinCalls = append(f.stdinCalls, stdin)
		fields := strings.Fields(strings.TrimSpace(stdin))
		if len(fields) == 2 {
			f.selections[fields[0]] = fields[1]
		}
		return nil, nil
	}
}

func TestDpkgSelections_SetsHoldWhenDifferent(t *testing.T) {
	fake := &fakeDpkg{selections: map[string]string{"curl": "install"}}
	d := &DpkgSelections{Runner: fake.runner(), RunnerStdin: fake.runnerStdin()}
	res, err := d.Run(context.Background(), map[string]any{"name": "curl", "selection": "hold"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true setting hold")
	}
	if fake.selections["curl"] != "hold" {
		t.Errorf("selection = %q, want hold", fake.selections["curl"])
	}
}

func TestDpkgSelections_IdempotentWhenAlreadySet(t *testing.T) {
	fake := &fakeDpkg{selections: map[string]string{"curl": "hold"}}
	d := &DpkgSelections{Runner: fake.runner(), RunnerStdin: fake.runnerStdin()}
	res, err := d.Run(context.Background(), map[string]any{"name": "curl", "selection": "hold"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when selection already matches")
	}
	if len(fake.stdinCalls) != 0 {
		t.Error("expected no dpkg --set-selections call")
	}
}

func TestDpkgSelections_UnknownPackageTreatedAsUnset(t *testing.T) {
	fake := &fakeDpkg{selections: map[string]string{}}
	d := &DpkgSelections{Runner: fake.runner(), RunnerStdin: fake.runnerStdin()}
	res, err := d.Run(context.Background(), map[string]any{"name": "ghost-pkg", "selection": "hold"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true for a package with no recorded selection")
	}
}

func TestDpkgSelections_DryRunDoesNotApply(t *testing.T) {
	fake := &fakeDpkg{selections: map[string]string{"curl": "install"}}
	d := &DpkgSelections{Runner: fake.runner(), RunnerStdin: fake.runnerStdin()}
	res, err := d.Run(context.Background(), map[string]any{"name": "curl", "selection": "hold", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if fake.selections["curl"] != "install" {
		t.Error("expected dry_run to not actually change the selection")
	}
}

func TestDpkgSelections_InvalidSelectionRejected(t *testing.T) {
	fake := &fakeDpkg{selections: map[string]string{}}
	d := &DpkgSelections{Runner: fake.runner(), RunnerStdin: fake.runnerStdin()}
	_, err := d.Run(context.Background(), map[string]any{"name": "curl", "selection": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for an invalid selection value")
	}
}
