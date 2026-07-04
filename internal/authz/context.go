package authz

import "context"

type identityCtxKey struct{}

// WithIdentity returns a copy of ctx carrying identity, retrievable via
// IdentityFromContext. Used by the bearer-auth middleware (see
// cmd/agentic-mcpd/http.go's withBearerAuth) so that MCP tool-call handlers
// — which only receive a context.Context, not the originating *http.Request
// — can still resolve which caller/token is behind the call, enabling
// per-token ACL scoping instead of every MCP caller resolving to the same
// fixed principal.
func WithIdentity(ctx context.Context, identity Identity) context.Context {
	return context.WithValue(ctx, identityCtxKey{}, identity)
}

// IdentityFromContext returns the Identity attached via WithIdentity, or
// the zero Identity if none was attached.
func IdentityFromContext(ctx context.Context) Identity {
	identity, _ := ctx.Value(identityCtxKey{}).(Identity)
	return identity
}
