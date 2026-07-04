package modules

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
)

// fakeCrontab simulates `crontab -l -u <user>` / `crontab -u <user> <file>`
// for a single in-memory crontab, recording mutating calls.
type fakeCrontab struct {
	content string
	hasAny  bool
	calls   []string
}

func (f *fakeCrontab) runner() CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		f.calls = append(f.calls, name+" "+joinArgs(args))
		if name != "crontab" {
			return nil, nil
		}
		if len(args) >= 2 && args[0] == "-l" {
			if !f.hasAny {
				return nil, fmt.Errorf("crontab: no crontab for testuser")
			}
			return []byte(f.content), nil
		}
		// crontab -u <user> <file>
		path := args[len(args)-1]
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		f.content = string(data)
		f.hasAny = true
		return nil, nil
	}
}

func TestCron_CreatesNewEntryWhenNoCrontabExists(t *testing.T) {
	fake := &fakeCrontab{}
	c := &Cron{Runner: fake.runner()}
	res, err := c.Run(context.Background(), map[string]any{
		"name": "backup", "job": "/usr/local/bin/backup.sh", "hour": "2", "minute": "0",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating a new entry")
	}
	if !strings.Contains(fake.content, "#Ansible: backup") || !strings.Contains(fake.content, "0 2 * * * /usr/local/bin/backup.sh") {
		t.Errorf("unexpected crontab content: %q", fake.content)
	}
}

func TestCron_IdempotentWhenEntryMatches(t *testing.T) {
	fake := &fakeCrontab{
		content: "#Ansible: backup\n0 2 * * * /usr/local/bin/backup.sh\n",
		hasAny:  true,
	}
	c := &Cron{Runner: fake.runner()}
	res, err := c.Run(context.Background(), map[string]any{
		"name": "backup", "job": "/usr/local/bin/backup.sh", "hour": "2", "minute": "0",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when entry already matches")
	}
}

func TestCron_UpdatesScheduleForExistingEntry(t *testing.T) {
	fake := &fakeCrontab{
		content: "#Ansible: backup\n0 2 * * * /usr/local/bin/backup.sh\n",
		hasAny:  true,
	}
	c := &Cron{Runner: fake.runner()}
	res, err := c.Run(context.Background(), map[string]any{
		"name": "backup", "job": "/usr/local/bin/backup.sh", "hour": "3", "minute": "0",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when schedule differs")
	}
	if !strings.Contains(fake.content, "0 3 * * * /usr/local/bin/backup.sh") {
		t.Errorf("expected updated schedule, got %q", fake.content)
	}
	if strings.Count(fake.content, "#Ansible: backup") != 1 {
		t.Errorf("expected exactly one marker (replace in place, not duplicate), got %q", fake.content)
	}
}

func TestCron_PreservesUnrelatedEntries(t *testing.T) {
	fake := &fakeCrontab{
		content: "0 1 * * * /some/other/job\n#Ansible: backup\n0 2 * * * /usr/local/bin/backup.sh\n",
		hasAny:  true,
	}
	c := &Cron{Runner: fake.runner()}
	if _, err := c.Run(context.Background(), map[string]any{
		"name": "backup", "job": "/usr/local/bin/backup.sh", "hour": "5", "minute": "0",
	}, false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(fake.content, "/some/other/job") {
		t.Errorf("expected unrelated entry preserved, got %q", fake.content)
	}
}

func TestCron_SpecialTime(t *testing.T) {
	fake := &fakeCrontab{}
	c := &Cron{Runner: fake.runner()}
	_, err := c.Run(context.Background(), map[string]any{
		"name": "onboot", "job": "/usr/local/bin/onboot.sh", "special_time": "reboot",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(fake.content, "@reboot /usr/local/bin/onboot.sh") {
		t.Errorf("expected @reboot schedule, got %q", fake.content)
	}
}

func TestCron_AbsentRemovesEntry(t *testing.T) {
	fake := &fakeCrontab{
		content: "#Ansible: backup\n0 2 * * * /usr/local/bin/backup.sh\n",
		hasAny:  true,
	}
	c := &Cron{Runner: fake.runner()}
	res, err := c.Run(context.Background(), map[string]any{"name": "backup", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing existing entry")
	}
	if strings.Contains(fake.content, "backup") {
		t.Errorf("expected entry removed, got %q", fake.content)
	}
}

func TestCron_AbsentIdempotentWhenMissing(t *testing.T) {
	fake := &fakeCrontab{}
	c := &Cron{Runner: fake.runner()}
	res, err := c.Run(context.Background(), map[string]any{"name": "ghost", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing an entry that doesn't exist")
	}
}

func TestCron_MissingJobForPresentErrors(t *testing.T) {
	fake := &fakeCrontab{}
	c := &Cron{Runner: fake.runner()}
	_, err := c.Run(context.Background(), map[string]any{"name": "backup"}, false)
	if err == nil {
		t.Fatal("expected error when job is missing for state=present")
	}
}

func TestCron_DryRunDoesNotWrite(t *testing.T) {
	fake := &fakeCrontab{}
	c := &Cron{Runner: fake.runner()}
	res, err := c.Run(context.Background(), map[string]any{
		"name": "backup", "job": "/x.sh", "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if fake.hasAny {
		t.Error("expected dry_run to not actually install a crontab")
	}
}
