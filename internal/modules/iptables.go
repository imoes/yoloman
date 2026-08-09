package modules

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
)

// Iptables ensures a netfilter rule is present or absent, mirroring
// ansible.builtin.iptables. It is idempotent via `iptables -C` — the
// "check" flag added specifically for idempotent scripting: exit 0 means
// the exact rule already exists, exit 1 means it doesn't (a normal
// negative result, not an error); any other failure (bad syntax, missing
// permissions, iptables not installed) is a genuine Go error.
type Iptables struct {
	Runner CommandRunner
}

// NewIptables returns an Iptables module backed by the real iptables binary.
func NewIptables() *Iptables { return &Iptables{Runner: defaultCommandRunner} }

func (i *Iptables) Name() string { return "iptables" }

func (i *Iptables) Description() string {
	return "" +
		"Ensure a netfilter rule is present or absent in a given table/chain, via `iptables`. " +
		"Idempotent through `iptables -C` (the check flag purpose-built for idempotent " +
		"scripting) — only calls -A/-I/-D when the exact rule's presence doesn't already match " +
		"state. Supports check_mode via dry_run=true (the check itself is read-only and always " +
		"runs, even under dry_run, to report accurately what would change). A focused subset of " +
		"real Ansible's ~40 iptables parameters: protocol/source/destination/ports/interfaces/" +
		"jump/comment cover the common case — conntrack state matching, NAT-specific options, " +
		"and numeric rule positioning are not implemented here.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.iptables. Same table/chain/protocol/source/destination/" +
		"source_port/destination_port/in_interface/out_interface/jump/comment/action/state " +
		"parameter names.\n" +
		"- Chef: the `iptables_rule` resource.\n" +
		"- Puppet: the puppetlabs-firewall module's `firewall` type.\n" +
		"- Salt: the `iptables.append`/`iptables.insert`/`iptables.delete` execution modules.\n" +
		"- Terraform: not applicable — Terraform does not manage a running host's kernel " +
		"firewall state."
}

func (i *Iptables) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"table":            stringProp(`Netfilter table. Default "filter".`),
		"chain":            stringProp(`Chain name, e.g. "INPUT", "FORWARD", or a custom chain.`),
		"protocol":         stringProp(`Protocol to match, e.g. "tcp", "udp", "icmp".`),
		"source":           stringProp("Source address/CIDR to match."),
		"destination":      stringProp("Destination address/CIDR to match."),
		"source_port":      stringProp("Source port to match (requires protocol tcp or udp)."),
		"destination_port": stringProp("Destination port to match (requires protocol tcp or udp)."),
		"in_interface":     stringProp("Input interface to match."),
		"out_interface":    stringProp("Output interface to match."),
		"jump":             stringProp(`Target, e.g. "ACCEPT", "DROP", "REJECT". Required for state=present.`),
		"comment":          stringProp("Optional comment attached to the rule via the comment match module."),
		"action":           stringEnumProp(`Where to place a new rule. Default "append".`, "append", "insert"),
		"state":            stringEnumProp(`Whether the rule should be present or absent. Default "present".`, "present", "absent"),
		"dry_run":          boolProp("When true, report what would change without applying it (check_mode).", false),
	}, "chain")
}

func (i *Iptables) Writes() bool { return true }

func (i *Iptables) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	table, err := stringParam(params, "table", false, "filter")
	if err != nil {
		return Result{}, err
	}
	chain, err := stringParam(params, "chain", true, "")
	if err != nil {
		return Result{}, err
	}
	protocol, err := stringParam(params, "protocol", false, "")
	if err != nil {
		return Result{}, err
	}
	source, err := stringParam(params, "source", false, "")
	if err != nil {
		return Result{}, err
	}
	destination, err := stringParam(params, "destination", false, "")
	if err != nil {
		return Result{}, err
	}
	sourcePort, err := stringParam(params, "source_port", false, "")
	if err != nil {
		return Result{}, err
	}
	destPort, err := stringParam(params, "destination_port", false, "")
	if err != nil {
		return Result{}, err
	}
	inInterface, err := stringParam(params, "in_interface", false, "")
	if err != nil {
		return Result{}, err
	}
	outInterface, err := stringParam(params, "out_interface", false, "")
	if err != nil {
		return Result{}, err
	}
	jump, err := stringParam(params, "jump", false, "")
	if err != nil {
		return Result{}, err
	}
	comment, err := stringParam(params, "comment", false, "")
	if err != nil {
		return Result{}, err
	}
	action, err := stringParam(params, "action", false, "append")
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
	if action != "append" && action != "insert" {
		return Result{}, fmt.Errorf("action: unsupported value %q (want append|insert)", action)
	}
	if state == "present" && jump == "" {
		return Result{}, fmt.Errorf("jump: required when state=present")
	}

	ruleArgs := buildIptablesRuleArgs(protocol, source, destination, sourcePort, destPort, inInterface, outInterface, jump, comment)

	checkArgs := append([]string{"-t", table, "-C", chain}, ruleArgs...)
	present, err := i.ruleExists(ctx, checkArgs)
	if err != nil {
		return Result{}, err
	}

	if state == "present" {
		if present {
			return Result{Changed: false, Msg: "rule already present", Data: map[string]any{"chain": chain}}, nil
		}
		if !dryRun {
			flag := "-A"
			if action == "insert" {
				flag = "-I"
			}
			args := append([]string{"-t", table, flag, chain}, ruleArgs...)
			if _, err := i.Runner(ctx, "iptables", args...); err != nil {
				return Result{}, fmt.Errorf("iptables: adding rule to %s: %w", chain, err)
			}
		}
		return Result{Changed: true, Msg: "rule added", Data: map[string]any{"chain": chain}}, nil
	}

	if !present {
		return Result{Changed: false, Msg: "rule already absent", Data: map[string]any{"chain": chain}}, nil
	}
	if !dryRun {
		args := append([]string{"-t", table, "-D", chain}, ruleArgs...)
		if _, err := i.Runner(ctx, "iptables", args...); err != nil {
			return Result{}, fmt.Errorf("iptables: removing rule from %s: %w", chain, err)
		}
	}
	return Result{Changed: true, Msg: "rule removed", Data: map[string]any{"chain": chain}}, nil
}

// ruleExists runs `iptables -C ...` (via checkArgs) and interprets its
// specific two-outcome exit contract: 0 means the rule exists, 1 means it
// doesn't (a normal negative result). Any other error is genuine.
func (i *Iptables) ruleExists(ctx context.Context, checkArgs []string) (bool, error) {
	_, err := i.Runner(ctx, "iptables", checkArgs...)
	if err == nil {
		return true, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
		return false, nil
	}
	return false, fmt.Errorf("iptables: checking rule: %w", err)
}

// buildIptablesRuleArgs builds the match/target argv for a single rule,
// without the table/chain/action flags (the caller prepends those).
func buildIptablesRuleArgs(protocol, source, destination, sourcePort, destPort, inInterface, outInterface, jump, comment string) []string {
	var args []string
	if protocol != "" {
		args = append(args, "-p", protocol)
	}
	if source != "" {
		args = append(args, "-s", source)
	}
	if destination != "" {
		args = append(args, "-d", destination)
	}
	if sourcePort != "" {
		args = append(args, "--sport", sourcePort)
	}
	if destPort != "" {
		args = append(args, "--dport", destPort)
	}
	if inInterface != "" {
		args = append(args, "-i", inInterface)
	}
	if outInterface != "" {
		args = append(args, "-o", outInterface)
	}
	if comment != "" {
		args = append(args, "-m", "comment", "--comment", comment)
	}
	if jump != "" {
		args = append(args, "-j", jump)
	}
	return args
}
