package modules

import (
	"context"
	"fmt"
	"strings"
)

// Debconf sets a single debconf database value for a Debian package,
// mirroring ansible.builtin.debconf — most commonly used to pre-seed
// answers a package's postinst would otherwise prompt for interactively.
// Idempotent: reads the current value via `debconf-show` before deciding
// whether to change it.
type Debconf struct {
	Runner      CommandRunner
	RunnerStdin CommandRunnerWithStdin
}

// NewDebconf returns a Debconf module backed by the real debconf-show /
// debconf-set-selections / debconf-communicate binaries.
func NewDebconf() *Debconf {
	return &Debconf{Runner: defaultCommandRunner, RunnerStdin: defaultCommandRunnerWithStdin}
}

func (d *Debconf) Name() string { return "debconf" }

func (d *Debconf) Description() string {
	return "" +
		"Set a debconf database value for a Debian package (pre-seeding an answer a package's " +
		"postinst script would otherwise prompt for interactively), via debconf-set-selections. " +
		"Idempotent — reads the current value via `debconf-show <name>` first and only sets it " +
		"when it differs. Setting a value does not by itself re-run a package's postinst; that " +
		"remains a separate `dpkg-reconfigure` step if the package needs to react immediately. " +
		"Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.debconf. Same name/question/vtype/value/unseen parameter " +
		"names.\n" +
		"- Chef: the `execute` resource shelling out to debconf-set-selections — no dedicated " +
		"resource exists.\n" +
		"- Puppet: no dedicated core type; typically a `exec` resource wrapping debconf-set-" +
		"selections, same as Chef.\n" +
		"- Salt: the `debconf.set` state.\n" +
		"- Terraform: not applicable — Terraform does not manage package installer prompts on a " +
		"running host."
}

func (d *Debconf) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"name":     stringProp(`Package name the question belongs to, e.g. "postfix".`),
		"question": stringProp(`Debconf question name, e.g. "postfix/main_mailer_type".`),
		"vtype":    stringEnumProp(`Debconf value type. Default "string".`, "string", "boolean", "select", "multiselect", "note", "password"),
		"value":    stringProp("Desired value for the question."),
		"unseen":   boolProp("When true, also clear the question's \"seen\" flag so the package will prompt for it again if reconfigured. Default false.", false),
		"dry_run":  boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "name", "question", "value")
}

func (d *Debconf) Writes() bool { return true }

func (d *Debconf) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	name, err := stringParam(params, "name", true, "")
	if err != nil {
		return Result{}, err
	}
	question, err := stringParam(params, "question", true, "")
	if err != nil {
		return Result{}, err
	}
	value, err := stringParam(params, "value", true, "")
	if err != nil {
		return Result{}, err
	}
	vtype, err := stringParam(params, "vtype", false, "string")
	if err != nil {
		return Result{}, err
	}
	switch vtype {
	case "string", "boolean", "select", "multiselect", "note", "password":
	default:
		return Result{}, fmt.Errorf("vtype: unsupported value %q (want string|boolean|select|multiselect|note|password)", vtype)
	}
	unseen, err := boolParam(params, "unseen", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	currentValue, currentlySeen, err := d.currentValue(ctx, name, question)
	if err != nil {
		return Result{}, err
	}

	valueChanged := currentValue != value
	seenChanged := unseen && currentlySeen
	changed := valueChanged || seenChanged

	data := map[string]any{"name": name, "question": question, "value": value, "previous": currentValue}

	if !changed {
		return Result{Changed: false, Msg: "value already set", Data: data}, nil
	}

	if !dryRun {
		if valueChanged {
			stdin := fmt.Sprintf("%s %s %s %s\n", name, question, vtype, value)
			if _, err := d.RunnerStdin(ctx, stdin, "debconf-set-selections"); err != nil {
				return Result{}, fmt.Errorf("debconf: setting %s/%s: %w", name, question, err)
			}
		}
		if seenChanged {
			stdin := fmt.Sprintf("fset %s seen false\n", question)
			if _, err := d.RunnerStdin(ctx, stdin, "debconf-communicate", name); err != nil {
				return Result{}, fmt.Errorf("debconf: clearing seen flag for %s/%s: %w", name, question, err)
			}
		}
	}

	return Result{Changed: true, Msg: "value updated", Data: data}, nil
}

// currentValue reads name/question's current value and "seen" flag via
// `debconf-show`. A package with no debconf entries yet (or one debconf
// doesn't know about) reports an empty value and seen=false rather than an
// error, since that's debconf-show's normal (non-zero exit) response.
func (d *Debconf) currentValue(ctx context.Context, name, question string) (value string, seen bool, err error) {
	out, err := d.Runner(ctx, "debconf-show", name)
	if err != nil {
		if isExitError(err) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("debconf: querying %s: %w", name, err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		lineSeen := strings.HasPrefix(line, "*")
		trimmed := strings.TrimSpace(strings.TrimPrefix(line, "*"))
		idx := strings.Index(trimmed, ":")
		if idx < 0 {
			continue
		}
		q := strings.TrimSpace(trimmed[:idx])
		if q != question {
			continue
		}
		return strings.TrimSpace(trimmed[idx+1:]), lineSeen, nil
	}
	return "", false, nil
}
