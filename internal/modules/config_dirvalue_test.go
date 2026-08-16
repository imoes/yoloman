package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// dirvalue: a directory where each file is one setting. Debian's pure-ftpd is why it exists —
// /etc/pure-ftpd/pure-ftpd.conf is shipped but the service never reads it; pure-ftpd-wrapper does
// opendir('/etc/pure-ftpd/conf') and turns each file into a flag. An editor aimed at the .conf
// would appear to work and change nothing.

func dirValueRun(t *testing.T, params map[string]any, dryRun bool) Result {
	t.Helper()
	res, err := NewConfig().Run(context.Background(), params, dryRun)
	if err != nil {
		t.Fatalf("config dirvalue: %v", err)
	}
	return res
}

func seedConfDir(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestDirValueReadsEachFileAsASetting(t *testing.T) {
	dir := seedConfDir(t, map[string]string{
		"NoAnonymous":    "yes\n",
		"MinUID":         "1000\n",
		"TLSCipherSuite": "HIGH\n",
	})
	res := dirValueRun(t, map[string]any{"path": dir, "format": "dirvalue"}, false)
	cfg := res.Data.(map[string]any)["config"].(map[string]any)
	if cfg["NoAnonymous"] != "yes" || cfg["MinUID"] != "1000" || cfg["TLSCipherSuite"] != "HIGH" {
		t.Fatalf("values not read as filename→contents: %#v", cfg)
	}
	if res.Changed {
		t.Fatal("a read must never report a change")
	}
}

func TestDirValueMergeLeavesOtherSettingsAlone(t *testing.T) {
	// The whole point of merge: pure-ftpd's directory holds settings this caller has never heard
	// of, and they must survive — the same guarantee the byte codecs give for foreign keys.
	dir := seedConfDir(t, map[string]string{"NoAnonymous": "yes\n", "MinUID": "1000\n"})
	res := dirValueRun(t, map[string]any{
		"path": dir, "format": "dirvalue", "values": map[string]any{"MaxClientsNumber": 50},
	}, false)
	if !res.Changed {
		t.Fatal("adding a setting must report changed")
	}
	got, _ := os.ReadFile(filepath.Join(dir, "MaxClientsNumber"))
	if string(got) != "50\n" {
		t.Fatalf("value not written with a trailing newline: %q", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "MinUID")); err != nil {
		t.Fatalf("merge deleted an untouched setting: %v", err)
	}
}

func TestDirValueNullDeletesTheSetting(t *testing.T) {
	// Same convention as the ini codec's per-key delete, so nothing has to be learned twice.
	dir := seedConfDir(t, map[string]string{"NoAnonymous": "yes\n", "MinUID": "1000\n"})
	dirValueRun(t, map[string]any{
		"path": dir, "format": "dirvalue", "values": map[string]any{"NoAnonymous": nil},
	}, false)
	if _, err := os.Stat(filepath.Join(dir, "NoAnonymous")); !os.IsNotExist(err) {
		t.Fatalf("null did not delete the file: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "MinUID")); err != nil {
		t.Fatalf("deleting one setting removed another: %v", err)
	}
}

func TestDirValueExactRemovesWhatIsNotDeclared(t *testing.T) {
	dir := seedConfDir(t, map[string]string{"NoAnonymous": "yes\n", "MinUID": "1000\n"})
	dirValueRun(t, map[string]any{
		"path": dir, "format": "dirvalue", "manage": "exact",
		"values": map[string]any{"NoAnonymous": "yes"},
	}, false)
	if _, err := os.Stat(filepath.Join(dir, "MinUID")); !os.IsNotExist(err) {
		t.Fatalf("manage=exact left an undeclared setting behind: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "NoAnonymous")); err != nil {
		t.Fatalf("manage=exact removed a declared setting: %v", err)
	}
}

func TestDirValueIsIdempotent(t *testing.T) {
	dir := seedConfDir(t, map[string]string{"MinUID": "1000\n"})
	params := map[string]any{"path": dir, "format": "dirvalue", "values": map[string]any{"MinUID": "1000"}}
	if res := dirValueRun(t, params, false); res.Changed {
		t.Fatal("writing the value the file already has must not report a change")
	}
}

func TestDirValueDryRunWritesNothingButReportsTheChange(t *testing.T) {
	dir := seedConfDir(t, map[string]string{"MinUID": "1000\n"})
	res := dirValueRun(t, map[string]any{
		"path": dir, "format": "dirvalue", "values": map[string]any{"MinUID": "2000", "NoAnonymous": "yes"},
	}, true)
	if !res.Changed {
		t.Fatal("dry run must still report that something would change")
	}
	got, _ := os.ReadFile(filepath.Join(dir, "MinUID"))
	if string(got) != "1000\n" {
		t.Fatalf("dry run modified the host: %q", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "NoAnonymous")); !os.IsNotExist(err) {
		t.Fatal("dry run created a file")
	}
}

func TestDirValueMissingDirectoryReadsEmptyAndCanBeCreated(t *testing.T) {
	// "Package not installed yet" is a legitimate starting state for desired state, exactly as a
	// missing file is for the byte codecs — it must not be an error.
	dir := filepath.Join(t.TempDir(), "conf")
	res := dirValueRun(t, map[string]any{"path": dir, "format": "dirvalue"}, false)
	if len(res.Data.(map[string]any)["config"].(map[string]any)) != 0 {
		t.Fatal("a missing directory should read as empty")
	}
	dirValueRun(t, map[string]any{
		"path": dir, "format": "dirvalue", "values": map[string]any{"MinUID": "1000"},
	}, false)
	got, err := os.ReadFile(filepath.Join(dir, "MinUID"))
	if err != nil || string(got) != "1000\n" {
		t.Fatalf("directory was not created and populated: %v %q", err, got)
	}
}

func TestDirValueRefusesAKeyThatEscapesTheDirectory(t *testing.T) {
	// The key becomes a path segment, so this must be REFUSED rather than sanitised — a caller
	// that silently gets a different name than it asked for is the worse failure.
	dir := seedConfDir(t, nil)
	for _, bad := range []string{"../escape", "sub/dir", "..", ""} {
		_, err := NewConfig().Run(context.Background(), map[string]any{
			"path": dir, "format": "dirvalue", "values": map[string]any{bad: "x"},
		}, false)
		if err == nil {
			t.Fatalf("key %q was accepted", bad)
		}
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "escape")); !os.IsNotExist(err) {
		t.Fatal("a refused key still wrote outside the directory")
	}
}

func TestDirValueIgnoresNestedDirectories(t *testing.T) {
	// pure-ftpd has conf/ beside auth/ and db/; a subdirectory is not a setting.
	dir := seedConfDir(t, map[string]string{"MinUID": "1000\n"})
	if err := os.Mkdir(filepath.Join(dir, "db"), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := dirValueRun(t, map[string]any{"path": dir, "format": "dirvalue"}, false).Data.(map[string]any)["config"].(map[string]any)
	if _, present := cfg["db"]; present {
		t.Fatal("a subdirectory was reported as a setting")
	}
	if len(cfg) != 1 {
		t.Fatalf("expected exactly the one setting, got %#v", cfg)
	}
}
