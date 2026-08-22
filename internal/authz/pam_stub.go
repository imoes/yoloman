//go:build !cgo

// Package authz provides PAM-based human login, session management, and
// ACL enforcement (per-tool enable/disable, per-principal allow rules) in
// front of the module/task/pipeline dispatch shared with MCP and REST.
//
// This stub is compiled in the default CGO-free build (the deployment
// binary is fully static — no libpam/libc runtime dependency, "just runs").
// PAM login is unavailable here: Authenticate always errors, so the agent's
// /api/v1/auth/login endpoint refuses. This is intentional — node agents
// authenticate by bearer token + mTLS, not by interactive PAM login. Build
// with CGO (pam.go) to enable real PAM login.
package authz

import "fmt"

// PAMAuthenticator mirrors the CGO implementation's shape so callers
// (cmd/agentic-mcpd, internal/server) compile unchanged; without CGO it
// simply can't authenticate.
type PAMAuthenticator struct {
	Service      string
	ConfDir      string
	LookupGroups func(username string) ([]string, error)
}

// NewPAMAuthenticator returns a stub authenticator (CGO-free build).
func NewPAMAuthenticator(service string) *PAMAuthenticator {
	return &PAMAuthenticator{Service: service}
}

// Authenticate always fails in the CGO-free build — PAM login is not built
// in. Token/mTLS auth is unaffected.
func (p *PAMAuthenticator) Authenticate(username, password string) (Identity, error) {
	return Identity{}, fmt.Errorf("PAM login is not available in this build (built without CGO); use token/mTLS auth")
}

// Available reports that this build has no PAM at all, so no login can be offered through it.
func (p *PAMAuthenticator) Available() bool { return false }
