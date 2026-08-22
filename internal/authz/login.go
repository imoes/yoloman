package authz

// Interactive human login: ONE interface, ONE group rule, two ways to check a password.
//
// There are two password backends and they are not interchangeable by choice — the build decides. pam.go
// links libpam and exists only under CGO; the packaged binary is static, so it gets pam_stub.go and has no
// PAM at all. chkpwd.go closes that hole by calling pam_unix's own setuid helper. A standalone host must
// offer its operator a login in EITHER build, so the caller must not care which one it got.
//
// AND THE GROUP RULE LIVES HERE, exactly once. Requiring membership in yoloadmin is the same rule for both
// backends; implementing it in each would be two places to change and two chances to disagree. GroupRequired
// wraps a backend and asks the group question FIRST, so an account that could not log in anyway is never
// used to probe passwords.

import (
	"fmt"
	"slices"
)

// PasswordAuthenticator is what an interactive login needs: verify a username/password pair, and say up front
// whether it can do so at all on this host. Available() is not a nicety — a login form that fails every
// attempt is worse than one the UI honestly does not offer.
type PasswordAuthenticator interface {
	Authenticate(username, password string) (Identity, error)
	Available() bool
}

// DefaultLoginGroup is the group whose members may log in to a standalone agent. The package's postinst
// creates it (empty), so the decision "who administers this host" is made by adding a user to it — a normal
// system operation, auditable with `getent group`, and not a second user database inside the agent.
const DefaultLoginGroup = "yoloadmin"

// GroupRequired admits only members of Group, whatever backend checks the password.
type GroupRequired struct {
	// Inner verifies the password.
	Inner PasswordAuthenticator
	// Group must contain the user. Empty means no group requirement, which is never the packaged default.
	Group string
	// LookupGroups resolves a username to its group names; overridable for tests.
	LookupGroups func(username string) ([]string, error)
}

// Available reports the backend's own availability — the group rule cannot make a login possible, only
// narrower.
func (g *GroupRequired) Available() bool {
	return g.Inner != nil && g.Inner.Available()
}

// Authenticate refuses a non-member before the password is checked, then delegates.
func (g *GroupRequired) Authenticate(username, password string) (Identity, error) {
	if g.Inner == nil {
		return Identity{}, fmt.Errorf("no password backend configured")
	}
	if g.Group == "" {
		return g.Inner.Authenticate(username, password)
	}
	lookup := g.LookupGroups
	if lookup == nil {
		lookup = systemGroupsForUser
	}
	groups, err := lookup(username)
	if err != nil {
		return Identity{}, fmt.Errorf("resolving groups for %q: %w", username, err)
	}
	if !slices.Contains(groups, g.Group) {
		return Identity{}, fmt.Errorf("user %q is not in group %q", username, g.Group)
	}
	id, err := g.Inner.Authenticate(username, password)
	if err != nil {
		return Identity{}, err
	}
	if len(id.Groups) == 0 {
		id.Groups = groups // the backend did not resolve them; we already have the answer
	}
	return id, nil
}

// NewPasswordLogin returns the login backend this host and this build can actually use, narrowed to group,
// or nil when there is none. Real PAM wins when it is compiled in, because it can also authenticate LDAP/
// SSSD/Kerberos users that unix_chkpwd (local shadow only) cannot.
func NewPasswordLogin(service, group string) PasswordAuthenticator {
	var inner PasswordAuthenticator
	if p := NewPAMAuthenticator(service); p.Available() {
		inner = p
	} else if c := NewChkpwdAuthenticator(group); c.Available() {
		inner = c
	} else {
		return nil // stated as absent rather than as a login that always fails
	}
	return &GroupRequired{Inner: inner, Group: group, LookupGroups: systemGroupsForUser}
}
