package modules

import (
	"context"
	"fmt"
	"os"
	"strings"
)

// cronMarkerPrefix identifies a cron entry this module manages, so it can
// find and replace/remove its own entries without touching lines it didn't
// create — mirroring Ansible's own "#Ansible: <name>" convention.
const cronMarkerPrefix = "#Ansible: "

// Cron ensures a named crontab entry is present or absent, mirroring
// ansible.builtin.cron. It is idempotent: entries are identified by a
// marker comment (not their content), so changing an entry's schedule or
// command replaces the same entry rather than adding a duplicate.
type Cron struct {
	Runner CommandRunner
}

// NewCron returns a Cron module backed by the real crontab binary.
func NewCron() *Cron { return &Cron{Runner: defaultCommandRunner} }

func (c *Cron) Name() string { return "cron" }

func (c *Cron) Description() string {
	return "" +
		"Ensure a crontab entry is present or absent for a given user, identified by a named " +
		"marker comment rather than its content — so changing the schedule or command later " +
		"replaces the same entry instead of adding a duplicate. Idempotent — a repeat call with " +
		"the same parameters reports changed=false. Time fields default to \"*\" (every " +
		"minute/hour/day/month/weekday) unless given; alternatively set `special_time` (e.g. " +
		"\"reboot\", \"daily\") instead of the five numeric fields. Supports check_mode via " +
		"dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.cron. Same name/job/user/minute/hour/day/weekday/month/" +
		"special_time/state semantics (a focused subset — Ansible also supports env vars and " +
		"cron.d files, not implemented here; entries always go into the user's own crontab).\n" +
		"- Chef: the `cron`/`cron_d` resources.\n" +
		"- Puppet: the `cron` type.\n" +
		"- Salt: the `cron.present`/`cron.absent` states.\n" +
		"- Terraform: not applicable — Terraform does not manage host-level scheduled tasks."
}

func (c *Cron) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":         stringProp("Unique identifier for this entry, used as its marker comment — required to find/replace/remove it later."),
		"job":          stringProp(`The command to run, e.g. "/usr/local/bin/backup.sh". Required for state=present.`),
		"user":         stringProp(`Which user's crontab to edit. Default "root".`),
		"minute":       stringProp(`Cron minute field. Default "*".`),
		"hour":         stringProp(`Cron hour field. Default "*".`),
		"day":          stringProp(`Cron day-of-month field. Default "*".`),
		"weekday":      stringProp(`Cron day-of-week field. Default "*".`),
		"month":        stringProp(`Cron month field. Default "*".`),
		"special_time": stringEnumProp("Optional named schedule instead of the five numeric fields.", "reboot", "yearly", "annually", "monthly", "weekly", "daily", "hourly"),
		"state":        stringEnumProp(`Whether the entry should be present or absent. Default "present".`, "present", "absent"),
		"dry_run":      boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name")
}

func (c *Cron) Writes() bool { return true }

func (c *Cron) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	job, err := stringParam(params, "job", false, "")
	if err != nil {
		return Result{}, err
	}
	user, err := stringParam(params, "user", false, "root")
	if err != nil {
		return Result{}, err
	}
	minute, err := stringParam(params, "minute", false, "*")
	if err != nil {
		return Result{}, err
	}
	hour, err := stringParam(params, "hour", false, "*")
	if err != nil {
		return Result{}, err
	}
	day, err := stringParam(params, "day", false, "*")
	if err != nil {
		return Result{}, err
	}
	weekday, err := stringParam(params, "weekday", false, "*")
	if err != nil {
		return Result{}, err
	}
	month, err := stringParam(params, "month", false, "*")
	if err != nil {
		return Result{}, err
	}
	specialTime, err := stringParam(params, "special_time", false, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "present")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	if state != "present" && state != "absent" {
		return Result{}, fmt.Errorf("state: unsupported value %q (want present|absent)", state)
	}
	if state == "present" && job == "" {
		return Result{}, fmt.Errorf("job: required when state=present")
	}

	marker := cronMarkerPrefix + name
	var scheduleLine string
	if state == "present" {
		if specialTime != "" {
			scheduleLine = "@" + specialTime + " " + job
		} else {
			scheduleLine = strings.Join([]string{minute, hour, day, month, weekday, job}, " ")
		}
	}

	current, err := c.readCrontab(ctx, user)
	if err != nil {
		return Result{}, err
	}

	newLines, changed := applyCronEntry(current, marker, scheduleLine, state)
	if !changed {
		return Result{Changed: false, Msg: "no change needed", Data: map[string]any{"name": name, "user": user}}, nil
	}

	if !dryRun {
		if err := c.writeCrontab(ctx, user, newLines); err != nil {
			return Result{}, err
		}
	}

	return Result{Changed: true, Msg: "cron entry " + state, Data: map[string]any{"name": name, "user": user}}, nil
}

// readCrontab returns user's current crontab as a slice of lines, treating
// "no crontab for user" (crontab -l's own not-found condition) as an empty
// crontab rather than an error.
func (c *Cron) readCrontab(ctx context.Context, user string) ([]string, error) {
	out, err := c.Runner(ctx, "crontab", "-l", "-u", user)
	if err != nil {
		if strings.Contains(err.Error(), "no crontab for") {
			return nil, nil
		}
		return nil, fmt.Errorf("cron: reading crontab for %s: %w", user, err)
	}
	text := strings.TrimRight(string(out), "\n")
	if text == "" {
		return nil, nil
	}
	return strings.Split(text, "\n"), nil
}

// writeCrontab installs lines as user's new crontab. crontab accepts a
// filename argument (in addition to "-" for stdin), so this writes to a
// temp file and passes its path — no stdin plumbing needed in CommandRunner.
func (c *Cron) writeCrontab(ctx context.Context, user string, lines []string) error {
	content := ""
	if len(lines) > 0 {
		content = strings.Join(lines, "\n") + "\n"
	}
	tmp, err := os.CreateTemp("", "cron-*")
	if err != nil {
		return fmt.Errorf("cron: creating temp file: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return fmt.Errorf("cron: writing temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("cron: closing temp file: %w", err)
	}
	if _, err := c.Runner(ctx, "crontab", "-u", user, tmpPath); err != nil {
		return fmt.Errorf("cron: installing crontab for %s: %w", user, err)
	}
	return nil
}

// applyCronEntry computes the new crontab lines and whether they differ
// from lines, for either state=present (replace an existing marker+entry
// pair in place, or append a new one at the end) or state=absent (remove
// the marker+entry pair, if found).
func applyCronEntry(lines []string, marker, scheduleLine, state string) ([]string, bool) {
	markerIdx := -1
	for i, l := range lines {
		if l == marker {
			markerIdx = i
			break
		}
	}
	found := markerIdx != -1 && markerIdx+1 < len(lines)

	if state == "absent" {
		if !found {
			return lines, false
		}
		out := append(append([]string{}, lines[:markerIdx]...), lines[markerIdx+2:]...)
		return out, true
	}

	if found {
		if lines[markerIdx+1] == scheduleLine {
			return lines, false
		}
		out := append([]string{}, lines...)
		out[markerIdx+1] = scheduleLine
		return out, true
	}

	return append(append([]string{}, lines...), marker, scheduleLine), true
}
