package authz

import (
	"testing"
	"time"
)

func TestSessionStore_CreateAndResolve(t *testing.T) {
	s := NewSessionStore(time.Hour)
	identity := Identity{Kind: KindUser, Name: "alice", Groups: []string{"wheel"}}

	token, err := s.Create(identity)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if token == "" {
		t.Fatal("expected non-empty token")
	}

	got, ok := s.Resolve(token)
	if !ok {
		t.Fatal("expected session to resolve")
	}
	if got.Name != "alice" {
		t.Errorf("resolved identity = %+v, want alice", got)
	}
}

func TestSessionStore_ResolveUnknownToken(t *testing.T) {
	s := NewSessionStore(time.Hour)
	if _, ok := s.Resolve("does-not-exist"); ok {
		t.Fatal("expected unknown token to not resolve")
	}
}

func TestSessionStore_Expiry(t *testing.T) {
	s := NewSessionStore(time.Minute)
	fakeNow := time.Now()
	s.now = func() time.Time { return fakeNow }

	token, err := s.Create(Identity{Kind: KindUser, Name: "bob"})
	if err != nil {
		t.Fatal(err)
	}

	fakeNow = fakeNow.Add(2 * time.Minute) // past the 1-minute TTL
	if _, ok := s.Resolve(token); ok {
		t.Fatal("expected expired session to not resolve")
	}
}

func TestSessionStore_Revoke(t *testing.T) {
	s := NewSessionStore(time.Hour)
	token, err := s.Create(Identity{Kind: KindUser, Name: "carol"})
	if err != nil {
		t.Fatal(err)
	}
	s.Revoke(token)
	if _, ok := s.Resolve(token); ok {
		t.Fatal("expected revoked session to not resolve")
	}
}

func TestSessionStore_DistinctTokensPerSession(t *testing.T) {
	s := NewSessionStore(time.Hour)
	t1, _ := s.Create(Identity{Kind: KindUser, Name: "a"})
	t2, _ := s.Create(Identity{Kind: KindUser, Name: "b"})
	if t1 == t2 {
		t.Fatal("expected distinct tokens for distinct sessions")
	}
}
