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
//
// THE SUPERUSER IS EXEMPT FROM THE GROUP, ALWAYS. The postinst creates yoloadmin EMPTY, so on a fresh install
// and on every upgrade of an existing host the group admits nobody; without an exemption the agent's own web
// UI would be unreachable until someone with shell access ran gpasswd — and the whole point of that UI is
// being the way in. The group rule exists to stop OTHER local accounts (backup users, service accounts with a
// password) from administering the host; it was never meant to keep out the account that already owns every
// file on it. Root's password is still required, and pam_unix refuses a locked or passwordless root by
// itself, so this widens who may be ASKED, not what counts as an answer.
//
// Exempt means UID 0, not the name "root": a host may call it toor, and a plain name comparison would both
// miss that and admit an ordinary account somebody named root.

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
	// LookupUID resolves a username to its numeric uid, for the superuser exemption above; overridable for
	// tests. Nil uses the real system database. A lookup that FAILS is not an exemption — an unknown user is
	// simply not uid 0.
	LookupUID func(username string) (string, error)
}

// SuperuserExempt reports whether username is uid 0 and therefore not subject to the group requirement.
func (g *GroupRequired) SuperuserExempt(username string) bool {
	lookup := g.LookupUID
	if lookup == nil {
		lookup = systemUIDForUser
	}
	uid, err := lookup(username)
	return err == nil && uid == "0"
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
	if g.Group == "" || g.SuperuserExempt(username) {
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
	return &GroupRequired{Inner: inner, Group: group,
		LookupGroups: systemGroupsForUser, LookupUID: systemUIDForUser}
}
