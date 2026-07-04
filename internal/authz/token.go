package authz

import "crypto/subtle"

// TokenEntry is one named bearer token beyond the primary/legacy token —
// see docs/plan.md's per-token RBAC design ("v3"): each entry gets its own
// Identity (Kind: KindToken, Name: entry.Name), so ACL rules can grant
// different tool scopes to different machine callers instead of every
// bearer token resolving to the same fixed "service-token" principal.
type TokenEntry struct {
	Name  string
	Token string
}

// ResolveBearerToken compares presented against legacyToken (mapping to
// TokenIdentity on a match, for backward compatibility with pre-v3
// single-token configs) and then against each of extra's entries (mapping
// to a per-entry Identity named after that entry). Every comparison is
// constant-time; returns ok=false if presented is empty or matches nothing.
func ResolveBearerToken(presented, legacyToken string, extra []TokenEntry) (Identity, bool) {
	if presented == "" {
		return Identity{}, false
	}
	if legacyToken != "" && subtle.ConstantTimeCompare([]byte(presented), []byte(legacyToken)) == 1 {
		return TokenIdentity, true
	}
	for _, e := range extra {
		if e.Token == "" {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(presented), []byte(e.Token)) == 1 {
			return Identity{Kind: KindToken, Name: e.Name}, true
		}
	}
	return Identity{}, false
}
