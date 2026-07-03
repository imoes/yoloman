package authz

import (
	"os"
	"path/filepath"
	"testing"
)

// writeTestPAMService creates a throwaway PAM service file under a temp
// ConfDir so tests can exercise the real PAM machinery (via
// pam.StartConfDir) without touching /etc/pam.d or needing real system
// credentials — pam_permit.so/pam_deny.so are stock PAM modules that always
// succeed/fail.
func writeTestPAMService(t *testing.T, name, content string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestPAMAuthenticator_SuccessGrantsIdentity(t *testing.T) {
	confDir := writeTestPAMService(t, "agentic-test-permit", "auth required pam_permit.so\naccount required pam_permit.so\n")
	auth := &PAMAuthenticator{
		Service: "agentic-test-permit",
		ConfDir: confDir,
		LookupGroups: func(username string) ([]string, error) {
			return []string{"testgroup"}, nil
		},
	}

	identity, err := auth.Authenticate("someuser", "anypassword")
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	if identity.Kind != KindUser || identity.Name != "someuser" {
		t.Errorf("unexpected identity: %+v", identity)
	}
	if len(identity.Groups) != 1 || identity.Groups[0] != "testgroup" {
		t.Errorf("unexpected groups: %v", identity.Groups)
	}
}

func TestPAMAuthenticator_DenyFailsAuthentication(t *testing.T) {
	confDir := writeTestPAMService(t, "agentic-test-deny", "auth required pam_deny.so\naccount required pam_deny.so\n")
	auth := &PAMAuthenticator{
		Service:      "agentic-test-deny",
		ConfDir:      confDir,
		LookupGroups: func(string) ([]string, error) { return nil, nil },
	}

	if _, err := auth.Authenticate("someuser", "anypassword"); err == nil {
		t.Fatal("expected authentication to fail against pam_deny.so")
	}
}

func TestPAMAuthenticator_GroupLookupFailurePropagates(t *testing.T) {
	confDir := writeTestPAMService(t, "agentic-test-permit2", "auth required pam_permit.so\naccount required pam_permit.so\n")
	wantErr := os.ErrNotExist
	auth := &PAMAuthenticator{
		Service: "agentic-test-permit2",
		ConfDir: confDir,
		LookupGroups: func(string) ([]string, error) {
			return nil, wantErr
		},
	}

	if _, err := auth.Authenticate("someuser", "anypassword"); err == nil {
		t.Fatal("expected group lookup failure to propagate as an error")
	}
}
