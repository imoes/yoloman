// Package authz provides PAM-based human login, session management, and
// ACL enforcement (per-tool enable/disable, per-principal allow rules) in
// front of the module/task/pipeline dispatch shared with MCP and REST.
package authz

import (
	"fmt"
	"os/user"

	"github.com/msteinert/pam/v2"
)

// PAMAuthenticator authenticates username/password pairs against a named
// PAM service (see /etc/pam.d/<service>), then resolves the authenticated
// user's group memberships for ACL matching.
type PAMAuthenticator struct {
	// Service is the PAM service name (a file under /etc/pam.d/, or under
	// ConfDir if set).
	Service string
	// ConfDir, if non-empty, points PAM at a directory of service files
	// instead of the system /etc/pam.d — used by tests to authenticate
	// against a throwaway service without touching system configuration.
	ConfDir string
	// LookupGroups resolves a username to its group names. Defaults to
	// the real os/user-based lookup; overridable for tests.
	LookupGroups func(username string) ([]string, error)
}

// NewPAMAuthenticator returns a PAMAuthenticator for the real system PAM
// stack under /etc/pam.d/<service>.
func NewPAMAuthenticator(service string) *PAMAuthenticator {
	return &PAMAuthenticator{Service: service, LookupGroups: systemGroupsForUser}
}

// Authenticate verifies username/password via PAM (authenticate + account
// validation, e.g. rejecting expired/locked accounts) and returns the
// user's Identity on success.
func (p *PAMAuthenticator) Authenticate(username, password string) (Identity, error) {
	conv := func(s pam.Style, msg string) (string, error) {
		switch s {
		case pam.PromptEchoOff, pam.PromptEchoOn:
			return password, nil
		case pam.ErrorMsg, pam.TextInfo:
			return "", nil
		default:
			return "", fmt.Errorf("unsupported PAM conversation style %v", s)
		}
	}

	var tx *pam.Transaction
	var err error
	if p.ConfDir != "" {
		tx, err = pam.StartConfDir(p.Service, username, pam.ConversationFunc(conv), p.ConfDir)
	} else {
		tx, err = pam.StartFunc(p.Service, username, conv)
	}
	if err != nil {
		return Identity{}, fmt.Errorf("starting PAM transaction: %w", err)
	}
	defer tx.End()

	if err := tx.Authenticate(0); err != nil {
		return Identity{}, fmt.Errorf("authentication failed: %w", err)
	}
	if err := tx.AcctMgmt(0); err != nil {
		return Identity{}, fmt.Errorf("account validation failed: %w", err)
	}

	lookupGroups := p.LookupGroups
	if lookupGroups == nil {
		lookupGroups = systemGroupsForUser
	}
	groups, err := lookupGroups(username)
	if err != nil {
		return Identity{}, fmt.Errorf("resolving groups for %q: %w", username, err)
	}

	return Identity{Kind: KindUser, Name: username, Groups: groups}, nil
}

// systemGroupsForUser resolves username's group names via the real system
// user/group database.
func systemGroupsForUser(username string) ([]string, error) {
	u, err := user.Lookup(username)
	if err != nil {
		return nil, err
	}
	gids, err := u.GroupIds()
	if err != nil {
		return nil, err
	}
	groups := make([]string, 0, len(gids))
	for _, gid := range gids {
		g, err := user.LookupGroupId(gid)
		if err != nil {
			continue // skip unresolvable gids rather than failing the whole lookup
		}
		groups = append(groups, g.Name)
	}
	return groups, nil
}
