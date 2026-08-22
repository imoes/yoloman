package authz

import (
	"fmt"
	"testing"
)

// stubBackend records whether the password was ever checked — the point of asking the group question first is
// that a non-member's password is NOT handed to a helper, so "was it called" is the assertion that matters.
type stubBackend struct {
	password string
	avail    bool
	called   bool
}

func (s *stubBackend) Available() bool { return s.avail }

func (s *stubBackend) Authenticate(username, password string) (Identity, error) {
	s.called = true
	if password != s.password {
		return Identity{}, fmt.Errorf("authentication failed")
	}
	return Identity{Kind: KindUser, Name: username}, nil
}

func TestGroupRequiredRefusesANonMemberWithoutCheckingThePassword(t *testing.T) {
	backend := &stubBackend{password: "geheim123", avail: true}
	login := &GroupRequired{Inner: backend, Group: "yoloadmin", LookupGroups: groups("users", "sudo")}
	// The password is RIGHT. Authorisation is a separate question: every local account with a password —
	// backup users, service accounts, a personal login — would otherwise manage the host.
	if _, err := login.Authenticate("tester", "geheim123"); err == nil {
		t.Fatal("a correct password without the group must not log in")
	}
	if backend.called {
		t.Error("the password was checked for a non-member — the group must be asked first, so this endpoint " +
			"cannot be used to probe passwords of accounts that could not log in anyway")
	}
}

func TestGroupRequiredAdmitsAMemberAndFillsTheGroups(t *testing.T) {
	backend := &stubBackend{password: "geheim123", avail: true}
	login := &GroupRequired{Inner: backend, Group: "yoloadmin", LookupGroups: groups("tester", "yoloadmin")}
	id, err := login.Authenticate("tester", "geheim123")
	if err != nil {
		t.Fatalf("member with the right password: %v", err)
	}
	// The backend returned no groups; the wrapper already resolved them, so the identity must not lose them.
	if len(id.Groups) != 2 {
		t.Errorf("groups = %v, want the membership list the group check already resolved", id.Groups)
	}
}

func TestGroupRequiredStillRejectsAMembersWrongPassword(t *testing.T) {
	backend := &stubBackend{password: "geheim123", avail: true}
	login := &GroupRequired{Inner: backend, Group: "yoloadmin", LookupGroups: groups("yoloadmin")}
	if _, err := login.Authenticate("tester", "falsch"); err == nil {
		t.Fatal("membership is not a password")
	}
}

func TestGroupRequiredCannotMakeAnUnavailableBackendUsable(t *testing.T) {
	login := &GroupRequired{Inner: &stubBackend{avail: false}, Group: "yoloadmin"}
	// A narrowing rule can only ever subtract. If this reported true, the UI would offer a login form backed
	// by nothing.
	if login.Available() {
		t.Error("Available() must follow the backend")
	}
}

func uid(n string) func(string) (string, error) {
	return func(string) (string, error) { return n, nil }
}

func TestGroupRequiredAdmitsTheSuperuserWithoutTheGroup(t *testing.T) {
	backend := &stubBackend{password: "geheim123", avail: true}
	login := &GroupRequired{Inner: backend, Group: "yoloadmin",
		LookupGroups: groups("root"), LookupUID: uid("0")}
	// The postinst creates yoloadmin EMPTY, so without this the agent's own web UI is unreachable on a fresh
	// install and after every upgrade — locked out of the interface whose whole purpose is being the way in.
	id, err := login.Authenticate("root", "geheim123")
	if err != nil {
		t.Fatalf("root with the right password: %v", err)
	}
	if id.Name != "root" {
		t.Errorf("identity = %+v, want root", id)
	}
}

func TestGroupRequiredStillWantsTheSuperusersPassword(t *testing.T) {
	backend := &stubBackend{password: "geheim123", avail: true}
	login := &GroupRequired{Inner: backend, Group: "yoloadmin", LookupUID: uid("0")}
	// The exemption widens who may be ASKED, not what counts as an answer.
	if _, err := login.Authenticate("root", "falsch"); err == nil {
		t.Fatal("uid 0 is not a password")
	}
}

func TestGroupRequiredExemptsUIDZeroNotTheNameRoot(t *testing.T) {
	backend := &stubBackend{password: "geheim123", avail: true}
	// An ordinary account somebody named "root" (uid 1001) must NOT inherit the exemption — a name is not an
	// identity, and the reverse case is real too: a host may call uid 0 "toor".
	login := &GroupRequired{Inner: backend, Group: "yoloadmin",
		LookupGroups: groups("users"), LookupUID: uid("1001")}
	if _, err := login.Authenticate("root", "geheim123"); err == nil {
		t.Fatal("the exemption must follow uid 0, not the string \"root\"")
	}
	login = &GroupRequired{Inner: backend, Group: "yoloadmin",
		LookupGroups: groups("users"), LookupUID: uid("0")}
	if _, err := login.Authenticate("toor", "geheim123"); err != nil {
		t.Fatalf("uid 0 under another name must still be exempt: %v", err)
	}
}

func TestGroupRequiredTreatsAFailedUIDLookupAsNotExempt(t *testing.T) {
	backend := &stubBackend{password: "geheim123", avail: true}
	login := &GroupRequired{Inner: backend, Group: "yoloadmin", LookupGroups: groups("users"),
		LookupUID: func(string) (string, error) { return "", fmt.Errorf("no such user") }}
	// An unknown user is not uid 0. Reading a failed lookup as "cannot rule it out, let them in" would turn
	// every typo into a superuser exemption.
	if _, err := login.Authenticate("ghost", "geheim123"); err == nil {
		t.Fatal("a failed uid lookup must not exempt anyone")
	}
}
