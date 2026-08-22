package authz

import (
	"os"
	"testing"
)

// The real thing, on a real host: unix_chkpwd against a real /etc/shadow entry and a real group.
//
// The other chkpwd tests use a fake helper, which proves the protocol I MEASURED but not the protocol the
// installed helper actually speaks. This one runs only where a throwaway account exists, because it needs a
// password in the shadow database:
//
//	AUTHZ_REAL_USER=tester AUTHZ_REAL_PASSWORD=geheim123 AUTHZ_REAL_GROUP=yoloadmin go test ./internal/authz/
//
// scripts/test-standalone-login.sh sets that up in a debian:12 and an almalinux:9 container and runs it.
func TestChkpwdAgainstTheRealHelper(t *testing.T) {
	user, password := os.Getenv("AUTHZ_REAL_USER"), os.Getenv("AUTHZ_REAL_PASSWORD")
	if user == "" || password == "" {
		t.Skip("set AUTHZ_REAL_USER and AUTHZ_REAL_PASSWORD to test against this host's shadow database")
	}
	login := NewPasswordLogin("agentic-mcp", os.Getenv("AUTHZ_REAL_GROUP"))
	if login == nil {
		t.Fatal("no password backend on this host, yet the test was asked to use the real one")
	}
	if !login.Available() {
		t.Fatal("Available() = false with a backend present")
	}
	id, err := login.Authenticate(user, password)
	if err != nil {
		t.Fatalf("real login for %q: %v", user, err)
	}
	if id.Name != user || id.Kind != KindUser {
		t.Errorf("identity = %+v, want a user named %q", id, user)
	}
	if len(id.Groups) == 0 {
		t.Error("no groups resolved — the ACL would match against nothing")
	}
	if _, err := login.Authenticate(user, password+"x"); err == nil {
		t.Error("the wrong password logged in against the real helper")
	}
	if other := os.Getenv("AUTHZ_REAL_NONMEMBER"); other != "" {
		// Same password, no membership: the group must be what refuses, on a real host.
		if _, err := login.Authenticate(other, password); err == nil {
			t.Errorf("non-member %q logged in", other)
		}
	}
}
