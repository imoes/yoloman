package modules

import (
	"context"
	"testing"
)

// fakeGroups simulates getent group / groupadd / groupmod / groupdel for a
// small fixed set of groups, recording mutating calls.
type fakeGroups struct {
	groups map[string]string // name -> gid
	calls  []string
}

func (f *fakeGroups) runner() CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		f.calls = append(f.calls, name+" "+joinArgs(args))
		switch name {
		case "getent":
			// args: "group", <name>
			gname := args[1]
			gid, ok := f.groups[gname]
			if !ok {
				return nil, exitStatus(2)
			}
			return []byte(gname + ":x:" + gid + ":\n"), nil
		case "groupadd":
			gname := args[len(args)-1]
			gid := "5000"
			for i, a := range args {
				if a == "-g" && i+1 < len(args) {
					gid = args[i+1]
				}
			}
			f.groups[gname] = gid
		case "groupmod":
			gname := args[len(args)-1]
			for i, a := range args {
				if a == "-g" && i+1 < len(args) {
					f.groups[gname] = args[i+1]
				}
			}
		case "groupdel":
			gname := args[len(args)-1]
			delete(f.groups, gname)
		}
		return nil, nil
	}
}

func TestGroup_CreatesWhenMissing(t *testing.T) {
	fake := &fakeGroups{groups: map[string]string{}}
	g := &Group{Runner: fake.runner()}
	res, err := g.Run(context.Background(), map[string]any{"name": "deploy"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating a new group")
	}
	if _, ok := fake.groups["deploy"]; !ok {
		t.Error("expected group to be created")
	}
}

func TestGroup_CreatesWithSpecificGID(t *testing.T) {
	fake := &fakeGroups{groups: map[string]string{}}
	g := &Group{Runner: fake.runner()}
	if _, err := g.Run(context.Background(), map[string]any{"name": "deploy", "gid": "1500"}, false); err != nil {
		t.Fatal(err)
	}
	if fake.groups["deploy"] != "1500" {
		t.Errorf("gid = %q, want 1500", fake.groups["deploy"])
	}
}

func TestGroup_IdempotentWhenAlreadyPresent(t *testing.T) {
	fake := &fakeGroups{groups: map[string]string{"deploy": "1500"}}
	g := &Group{Runner: fake.runner()}
	res, err := g.Run(context.Background(), map[string]any{"name": "deploy", "gid": "1500"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when group already matches")
	}
}

func TestGroup_ChangesGIDWhenDifferent(t *testing.T) {
	fake := &fakeGroups{groups: map[string]string{"deploy": "1500"}}
	g := &Group{Runner: fake.runner()}
	res, err := g.Run(context.Background(), map[string]any{"name": "deploy", "gid": "1600"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when gid differs")
	}
	if fake.groups["deploy"] != "1600" {
		t.Errorf("gid = %q, want 1600", fake.groups["deploy"])
	}
}

func TestGroup_AbsentRemovesExisting(t *testing.T) {
	fake := &fakeGroups{groups: map[string]string{"deploy": "1500"}}
	g := &Group{Runner: fake.runner()}
	res, err := g.Run(context.Background(), map[string]any{"name": "deploy", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing existing group")
	}
	if _, ok := fake.groups["deploy"]; ok {
		t.Error("expected group to be removed")
	}
}

func TestGroup_AbsentIdempotentWhenMissing(t *testing.T) {
	fake := &fakeGroups{groups: map[string]string{}}
	g := &Group{Runner: fake.runner()}
	res, err := g.Run(context.Background(), map[string]any{"name": "ghost", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing a group that doesn't exist")
	}
}

func TestGroup_InvalidState(t *testing.T) {
	fake := &fakeGroups{groups: map[string]string{}}
	g := &Group{Runner: fake.runner()}
	_, err := g.Run(context.Background(), map[string]any{"name": "x", "state": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for invalid state")
	}
}

func TestGroup_DryRunDoesNotMutate(t *testing.T) {
	fake := &fakeGroups{groups: map[string]string{}}
	g := &Group{Runner: fake.runner()}
	res, err := g.Run(context.Background(), map[string]any{"name": "deploy", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, ok := fake.groups["deploy"]; ok {
		t.Error("expected dry_run to not actually create the group")
	}
}

func TestGroup_CreationFailurePropagatesError(t *testing.T) {
	g := &Group{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "getent" {
			return nil, exitStatus(2)
		}
		if name == "groupadd" {
			return []byte("groupadd: GID '1500' already exists"), exitStatus(4)
		}
		return nil, nil
	}}
	_, err := g.Run(context.Background(), map[string]any{"name": "deploy", "gid": "1500"}, false)
	if err == nil {
		t.Fatal("expected error when groupadd fails")
	}
}
