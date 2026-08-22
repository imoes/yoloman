package authz

// Human login for the STATIC build, via PAM's own password helper.
//
// THE PROBLEM THIS SOLVES. pam.go links libpam and is compiled only with CGO; the packaged binary is
// deliberately CGO-free and fully static, so it gets pam_stub.go and /api/v1/auth/login refuses. That is
// fine for a node agent (bearer token + mTLS) and wrong for a STANDALONE host, where the agent's own web UI
// is the only way in and a human has to sign in.
//
// unix_chkpwd is the way in without giving up the static binary. It is pam_unix's own verification helper,
// shipped by libpam-modules on Debian and pam on EL (measured: present in debian:12 and almalinux:9), and it
// is setuid/setgid precisely so a process can ask "is this the user's password?" without reading
// /etc/shadow itself. So this is not a re-implementation of PAM's crypt handling — it is PAM's, called as a
// program instead of a library.
//
// THE PROTOCOL, measured rather than assumed (debian:12, a user with a known password):
//
//	printf 'geheim123\0' | unix_chkpwd tester nullok   -> exit 0
//	printf 'geheim123\n' | unix_chkpwd tester nullok   -> exit 7   <- the NUL matters
//	printf 'falsch\0'    | unix_chkpwd tester nullok   -> exit 7
//
// WHAT IT DOES NOT DO, and the difference is worth stating: unix_chkpwd checks the local shadow database.
// A real PAM stack can also authenticate against LDAP/SSSD/Kerberos, and those users cannot log in this way.
// The CGO build with real PAM still can, and that is the escape hatch — this is the static build's answer,
// not a replacement.
//
// A GROUP IS ALSO REQUIRED, but not here. A correct password alone is not authorisation — every login must
// also be a member of yoloadmin (created by the package's postinst), or every local account with a password
// would manage the host. That rule is the same for real PAM, so it lives once, in login.go's GroupRequired,
// which wraps this.

import (
	"fmt"
	"os/exec"
)

// chkpwdCandidates are where the helper lives. Debian puts it in /usr/sbin and symlinks /sbin; EL only in
// /usr/sbin. Probed in order at authentication time rather than cached, so a host that gains the package
// later does not need the daemon restarted.
var chkpwdCandidates = []string{"/usr/sbin/unix_chkpwd", "/sbin/unix_chkpwd"}

// ChkpwdAuthenticator verifies a local account's password through pam_unix's unix_chkpwd helper.
type ChkpwdAuthenticator struct {
	// LookupGroups resolves the authenticated user's group names for ACL matching; overridable for tests.
	LookupGroups func(username string) ([]string, error)
	// Helper overrides the unix_chkpwd path (tests point this at a fake).
	Helper string
}

// NewChkpwdAuthenticator returns an authenticator for this host's local accounts. The group argument is
// accepted so the call site reads the same as NewPAMAuthenticator's; the requirement itself is applied by
// GroupRequired, which wraps this.
func NewChkpwdAuthenticator(_group string) *ChkpwdAuthenticator {
	return &ChkpwdAuthenticator{LookupGroups: systemGroupsForUser}
}

// Available reports whether the helper exists on this host — the honest precondition for offering a login
// form at all, so the UI can say "no local login on this host" instead of failing every attempt.
func (c *ChkpwdAuthenticator) Available() bool {
	return c.helper() != ""
}

// helper returns the path of an executable helper, or "" if there is none. An override is verified like a
// candidate rather than trusted: a configured path that does not exist would otherwise make Available() claim
// a login that fails on every attempt, which is the one answer worse than "no local login on this host".
func (c *ChkpwdAuthenticator) helper() string {
	candidates := chkpwdCandidates
	if c.Helper != "" {
		candidates = []string{c.Helper}
	}
	for _, path := range candidates {
		if _, err := exec.LookPath(path); err == nil {
			return path
		}
	}
	return ""
}

// Authenticate verifies the password with unix_chkpwd and resolves the user's groups for ACL matching.
func (c *ChkpwdAuthenticator) Authenticate(username, password string) (Identity, error) {
	if username == "" || password == "" {
		return Identity{}, fmt.Errorf("username and password are required")
	}
	helper := c.helper()
	if helper == "" {
		return Identity{}, fmt.Errorf("unix_chkpwd is not installed — no local login on this host")
	}

	lookup := c.LookupGroups
	if lookup == nil {
		lookup = systemGroupsForUser
	}
	groups, err := lookup(username)
	if err != nil {
		return Identity{}, fmt.Errorf("resolving groups for %q: %w", username, err)
	}

	cmd := exec.Command(helper, username, "nullok")
	// The NUL terminator is the protocol — a newline is rejected (measured). The password never appears in
	// argv, where `ps` would show it.
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return Identity{}, fmt.Errorf("unix_chkpwd: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return Identity{}, fmt.Errorf("unix_chkpwd: %w", err)
	}
	_, writeErr := stdin.Write(append([]byte(password), 0))
	closeErr := stdin.Close()
	waitErr := cmd.Wait()
	if writeErr != nil || closeErr != nil {
		return Identity{}, fmt.Errorf("unix_chkpwd: writing the password: %v/%v", writeErr, closeErr)
	}
	if waitErr != nil {
		return Identity{}, fmt.Errorf("authentication failed for %q", username)
	}
	return Identity{Kind: KindUser, Name: username, Groups: groups}, nil
}
