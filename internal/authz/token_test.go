package authz

import (
	"reflect"
	"testing"
)

func TestResolveBearerToken_MatchesLegacyToken(t *testing.T) {
	identity, ok := ResolveBearerToken("legacy-secret", "legacy-secret", nil)
	if !ok {
		t.Fatal("expected a match against the legacy token")
	}
	if !reflect.DeepEqual(identity, TokenIdentity) {
		t.Errorf("identity = %+v, want TokenIdentity", identity)
	}
}

func TestResolveBearerToken_MatchesNamedEntry(t *testing.T) {
	extra := []TokenEntry{
		{Name: "bossman", Token: "bossman-secret"},
		{Name: "ci-pipeline", Token: "ci-secret"},
	}
	identity, ok := ResolveBearerToken("ci-secret", "legacy-secret", extra)
	if !ok {
		t.Fatal("expected a match against a named token entry")
	}
	want := Identity{Kind: KindToken, Name: "ci-pipeline"}
	if !reflect.DeepEqual(identity, want) {
		t.Errorf("identity = %+v, want %+v", identity, want)
	}
}

func TestResolveBearerToken_NoMatch(t *testing.T) {
	extra := []TokenEntry{{Name: "bossman", Token: "bossman-secret"}}
	_, ok := ResolveBearerToken("wrong", "legacy-secret", extra)
	if ok {
		t.Fatal("expected no match for an unrecognized token")
	}
}

func TestResolveBearerToken_EmptyPresentedNeverMatches(t *testing.T) {
	_, ok := ResolveBearerToken("", "legacy-secret", nil)
	if ok {
		t.Fatal("expected an empty presented token to never match, even against an empty legacy token")
	}
}

func TestResolveBearerToken_EmptyLegacyTokenNeverMatchesEmptyPresented(t *testing.T) {
	_, ok := ResolveBearerToken("", "", nil)
	if ok {
		t.Fatal("expected no match when both presented and legacy are empty")
	}
}

func TestResolveBearerToken_SkipsEntriesWithEmptyToken(t *testing.T) {
	extra := []TokenEntry{{Name: "broken", Token: ""}}
	_, ok := ResolveBearerToken("", "", extra)
	if ok {
		t.Fatal("expected an entry with an empty token to never match")
	}
}

func TestIdentityFromContext_RoundTrip(t *testing.T) {
	want := Identity{Kind: KindToken, Name: "bossman"}
	ctx := WithIdentity(t.Context(), want)
	got := IdentityFromContext(ctx)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("IdentityFromContext = %+v, want %+v", got, want)
	}
}

func TestIdentityFromContext_ZeroValueWhenUnset(t *testing.T) {
	got := IdentityFromContext(t.Context())
	if !reflect.DeepEqual(got, Identity{}) {
		t.Errorf("IdentityFromContext = %+v, want zero value", got)
	}
}
