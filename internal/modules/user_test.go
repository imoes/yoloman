package modules

import (
	"context"
	"strings"
	"testing"
)

// fakeUsers simulates getent passwd / id -Gn / useradd / usermod / userdel
// for a small fixed set of users, recording mutating calls.
type fakeUsers struct {
	users     map[string]userEntry // name -> entry
	secondary map[string][]string  // name -> secondary group names
	calls     []string
}

func (f *fakeUsers) runner() CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		f.calls = append(f.calls, name+" "+joinArgs(args))
		switch name {
		case "getent":
			uname := args[1]
			e, ok := f.users[uname]
			if !ok {
				return nil, exitStatus(2)
			}
			return []byte(strings.Join([]string{uname, "x", e.uid, e.gid, e.comment, e.home, e.shell}, ":") + "\n"), nil
		case "id":
			uname := args[len(args)-1]
			return []byte(strings.Join(f.secondary[uname], " ") + "\n"), nil
		case "useradd":
			uname := args[len(args)-1]
			e := userEntry{uid: "5000", gid: "5000", home: "/home/" + uname, shell: "/bin/sh"}
			for i, a := range args {
				switch a {
				case "-u":
					e.uid = args[i+1]
				case "-g":
					e.gid = args[i+1]
				case "-s":
					e.shell = args[i+1]
				case "-d":
					e.home = args[i+1]
				case "-c":
					e.comment = args[i+1]
				case "-G":
					f.secondary[uname] = strings.Split(args[i+1], ",")
				}
			}
			f.users[uname] = e
		case "usermod":
			uname := args[len(args)-1]
			e := f.users[uname]
			appendMode := false
			for i, a := range args {
				switch a {
				case "-u":
					e.uid = args[i+1]
				case "-g":
					e.gid = args[i+1]
				case "-s":
					e.shell = args[i+1]
				case "-d":
					e.home = args[i+1]
				case "-c":
					e.comment = args[i+1]
				case "-a":
					appendMode = true
				case "-G":
					newGroups := strings.Split(args[i+1], ",")
					if appendMode {
						f.secondary[uname] = append(f.secondary[uname], newGroups...)
					} else {
						f.secondary[uname] = newGroups
					}
				}
			}
			f.users[uname] = e
		case "userdel":
			uname := args[len(args)-1]
			delete(f.users, uname)
			delete(f.secondary, uname)
		}
		return nil, nil
	}
}

func newFakeUsers() *fakeUsers {
	return &fakeUsers{users: map[string]userEntry{}, secondary: map[string][]string{}}
}

func TestUser_CreatesWhenMissing(t *testing.T) {
	fake := newFakeUsers()
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{"name": "deploy"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating a new user")
	}
	if _, ok := fake.users["deploy"]; !ok {
		t.Error("expected user to be created")
	}
}

func TestUser_CreatesWithAttributes(t *testing.T) {
	fake := newFakeUsers()
	u := &User{Runner: fake.runner()}
	_, err := u.Run(context.Background(), map[string]any{
		"name": "deploy", "uid": "1500", "shell": "/bin/bash", "comment": "Deploy User",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	e := fake.users["deploy"]
	if e.uid != "1500" || e.shell != "/bin/bash" || e.comment != "Deploy User" {
		t.Errorf("unexpected created user: %+v", e)
	}
}

func TestUser_IdempotentWhenAlreadyMatching(t *testing.T) {
	fake := newFakeUsers()
	fake.users["deploy"] = userEntry{uid: "1500", gid: "1500", shell: "/bin/bash", home: "/home/deploy"}
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{
		"name": "deploy", "uid": "1500", "shell": "/bin/bash",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when all given attributes already match")
	}
}

func TestUser_UpdatesChangedAttributes(t *testing.T) {
	fake := newFakeUsers()
	fake.users["deploy"] = userEntry{uid: "1500", gid: "1500", shell: "/bin/sh", home: "/home/deploy"}
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{"name": "deploy", "shell": "/bin/bash"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when shell differs")
	}
	if fake.users["deploy"].shell != "/bin/bash" {
		t.Errorf("shell = %q, want /bin/bash", fake.users["deploy"].shell)
	}
}

func TestUser_SecondaryGroupsReplaceMode(t *testing.T) {
	fake := newFakeUsers()
	fake.users["deploy"] = userEntry{uid: "1500"}
	fake.secondary["deploy"] = []string{"old1", "old2"}
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{
		"name": "deploy", "groups": []string{"new1", "new2"},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true replacing secondary groups")
	}
	if strings.Join(fake.secondary["deploy"], ",") != "new1,new2" {
		t.Errorf("secondary groups = %v, want [new1 new2]", fake.secondary["deploy"])
	}
}

func TestUser_SecondaryGroupsAppendMode(t *testing.T) {
	fake := newFakeUsers()
	fake.users["deploy"] = userEntry{uid: "1500"}
	fake.secondary["deploy"] = []string{"existing"}
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{
		"name": "deploy", "groups": []string{"extra"}, "append": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true appending a new secondary group")
	}
	joined := strings.Join(fake.secondary["deploy"], ",")
	if !strings.Contains(joined, "existing") || !strings.Contains(joined, "extra") {
		t.Errorf("expected both groups present, got %v", fake.secondary["deploy"])
	}
}

func TestUser_SecondaryGroupsAppendIdempotent(t *testing.T) {
	fake := newFakeUsers()
	fake.users["deploy"] = userEntry{uid: "1500"}
	fake.secondary["deploy"] = []string{"existing"}
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{
		"name": "deploy", "groups": []string{"existing"}, "append": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false appending a group that's already present")
	}
}

func TestUser_AbsentRemovesExisting(t *testing.T) {
	fake := newFakeUsers()
	fake.users["deploy"] = userEntry{uid: "1500"}
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{"name": "deploy", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing existing user")
	}
	if _, ok := fake.users["deploy"]; ok {
		t.Error("expected user to be removed")
	}
}

func TestUser_AbsentIdempotentWhenMissing(t *testing.T) {
	fake := newFakeUsers()
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{"name": "ghost", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing a user that doesn't exist")
	}
}

func TestUser_InvalidState(t *testing.T) {
	fake := newFakeUsers()
	u := &User{Runner: fake.runner()}
	_, err := u.Run(context.Background(), map[string]any{"name": "x", "state": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for invalid state")
	}
}

func TestUser_DryRunDoesNotMutate(t *testing.T) {
	fake := newFakeUsers()
	u := &User{Runner: fake.runner()}
	res, err := u.Run(context.Background(), map[string]any{"name": "deploy", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, ok := fake.users["deploy"]; ok {
		t.Error("expected dry_run to not actually create the user")
	}
}

func TestUser_CreationFailurePropagatesError(t *testing.T) {
	u := &User{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "getent" {
			return nil, exitStatus(2)
		}
		if name == "useradd" {
			return []byte("useradd: UID 1500 is not unique"), exitStatus(4)
		}
		return nil, nil
	}}
	_, err := u.Run(context.Background(), map[string]any{"name": "deploy", "uid": "1500"}, false)
	if err == nil {
		t.Fatal("expected error when useradd fails")
	}
}
