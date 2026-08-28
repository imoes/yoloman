package authz

import (
	"os"
	"path/filepath"
	"testing"
)

// fakeHelper writes a script that mimics unix_chkpwd's measured contract: read stdin, succeed only when the
// bytes are `want` followed by a NUL. A newline-terminated password must FAIL, because the real helper
// rejects it (measured on debian:12) and a test that accepted both would hide a protocol change.
func fakeHelper(t *testing.T, want string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "unix_chkpwd")
	script := "#!/bin/sh\nread_input=$(cat | tr -d '\\0')\n" +
		"if [ \"$read_input\" = \"" + want + "\" ]; then exit 0; else exit 7; fi\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake helper: %v", err)
	}
	return path
}

func groups(names ...string) func(string) ([]string, error) {
	return func(string) ([]string, error) { return names, nil }
}

func TestChkpwdAcceptsTheRightPasswordAndCarriesTheGroups(t *testing.T) {
	auth := &ChkpwdAuthenticator{Helper: fakeHelper(t, "geheim123"), LookupGroups: groups("tester", "yoloadmin")}
	id, err := auth.Authenticate("tester", "geheim123")
	if err != nil {
		t.Fatalf("right password: %v", err)
	}
	if id.Kind != KindUser || id.Name != "tester" {
		t.Errorf("identity = %+v, want a user named tester", id)
	}
	// The groups travel with the identity because the ACL matches on them; an identity without them would
	// authenticate and then be authorised against nothing.
	if len(id.Groups) != 2 {
		t.Errorf("groups = %v, want the membership list carried through", id.Groups)
	}
}

func TestChkpwdRejectsTheWrongPassword(t *testing.T) {
	auth := &ChkpwdAuthenticator{Helper: fakeHelper(t, "geheim123"), LookupGroups: groups("yoloadmin")}
	if _, err := auth.Authenticate("tester", "falsch"); err == nil {
		t.Fatal("the wrong password must not log in")
	}
}

func TestChkpwdRefusesWhenTheHelperIsMissing(t *testing.T) {
	auth := &ChkpwdAuthenticator{Helper: filepath.Join(t.TempDir(), "does-not-exist"), LookupGroups: groups("yoloadmin")}
	// A host without libpam-modules has no local login, and Available() says so BEFORE a form is offered —
	// a login that always fails is worse than one that is honestly absent.
	if auth.Available() {
		t.Error("Available() must be false when the helper is not there")
	}
	if _, err := auth.Authenticate("tester", "geheim123"); err == nil {
		t.Fatal("no helper must not mean a free pass")
	}
}

func TestChkpwdRefusesEmptyCredentials(t *testing.T) {
	auth := &ChkpwdAuthenticator{Helper: fakeHelper(t, "")}
	// `nullok` is passed to the helper (pam_unix's own default for a blank shadow entry), so the empty
	// password is refused HERE rather than being handed to a helper that might accept it.
	if _, err := auth.Authenticate("tester", ""); err == nil {
		t.Fatal("an empty password must be refused before the helper is called")
	}
}
