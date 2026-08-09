package authz

// Kind identifies what sort of principal an Identity represents.
type Kind string

const (
	// KindUser is a human authenticated via PAM.
	KindUser Kind = "user"
	// KindToken is the machine/AI principal behind the daemon's bearer
	// token. v1 has exactly one such principal (see TokenIdentity).
	KindToken Kind = "token"
)

// TokenPrincipalName is the fixed principal name for the single bearer
// token v1 supports. A future multi-token RBAC scheme (see docs/plan.md
// roadmap) would replace this with a per-token identifier.
const TokenPrincipalName = "service-token"

// Identity is the authenticated caller behind a tool call: either a PAM
// user (with its group memberships, for ACL matching) or the fixed token
// principal.
type Identity struct {
	Kind   Kind
	Name   string
	Groups []string
}

// TokenIdentity is the Identity for any caller authenticated via the
// daemon's shared bearer token.
var TokenIdentity = Identity{Kind: KindToken, Name: TokenPrincipalName}
