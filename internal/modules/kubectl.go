package modules

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// KubectlExecFunc runs kubectl (no shell) with stdin and returns captured
// stdout, stderr and the exit code. A non-zero exit is DATA, not a Go error:
// kubectl's stderr carries the reason an operator acts on ("admission webhook
// denied", "the server could not find the requested resource", a server
// warning on an otherwise successful apply), and `kubectl diff` exits 1 to
// mean "there are differences". Only failing to start the process is an err.
//
// The Command module's CommandExecFunc has the same shape minus stdin;
// CommandRunnerWithStdin has stdin but discards stderr on success — which is
// exactly the warning text this module must keep. Hence its own seam.
type KubectlExecFunc func(ctx context.Context, stdin string, argv []string) (stdout, stderr []byte, exitCode int, err error)

func defaultKubectlExec(ctx context.Context, stdin string, argv []string) ([]byte, []byte, int, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Env = os.Environ()
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	if runErr := cmd.Run(); runErr != nil {
		var exitErr *exec.ExitError
		if !errors.As(runErr, &exitErr) {
			return nil, nil, 0, fmt.Errorf("starting kubectl: %w", runErr)
		}
		return outBuf.Bytes(), errBuf.Bytes(), exitErr.ExitCode(), nil
	}
	return outBuf.Bytes(), errBuf.Bytes(), 0, nil
}

// Kubectl exposes the kubectl CLI as ONE module with a structured input, so a
// caller (Bossman's Kubernetes console, an MCP client, a runbook step) builds
// the command line deterministically and the write gate keys on the verb —
// including two-word verbs such as "rollout status". The host this runs on is
// the cluster's ACCESS HOST: it holds kubectl and the kubeconfig; Bossman never
// stores a cluster credential. Writes always go through server-side apply
// with a fixed field manager, so ownership of every field we set is visible in
// the object's managedFields.
type Kubectl struct {
	Exec KubectlExecFunc
}

// NewKubectl returns a Kubectl module backed by the real kubectl binary.
func NewKubectl() *Kubectl { return &Kubectl{Exec: defaultKubectlExec} }

func (m *Kubectl) Name() string { return "kubectl" }

// KubectlFieldManager is the server-side-apply field manager every write of
// this module uses. One stable name, so `managedFields` can say "bossman set
// this" and a later apply from another manager conflicts visibly instead of
// silently taking the field over.
const KubectlFieldManager = "bossman"

// kubectlReadOnly are the verbs that only read cluster state. They run even
// under dry_run and report changed=false. "apply-dry-run" is a read: it is
// `apply --dry-run=server`, which runs admission and validation on the API
// server without persisting anything — the preview the console shows before
// a real apply. Everything else is mutating.
var kubectlReadOnly = map[string]bool{
	"get": true, "describe": true, "logs": true, "top": true, "events": true,
	"api-resources": true, "api-versions": true, "version": true, "cluster-info": true,
	"explain": true, "diff": true, "apply-dry-run": true,
	"rollout status": true, "rollout history": true,
	"auth can-i": true, "config get-contexts": true, "config current-context": true,
	"config view": true,
}

// kubectlInteractive are verbs that need a terminal or a long-lived stream and
// cannot be a module call. Refused with the reason, not run.
var kubectlInteractive = map[string]bool{
	"exec": true, "attach": true, "port-forward": true, "proxy": true, "edit": true, "debug": true,
}

// kubectlJSONCapable lists the verbs that accept `-o json`; the module adds it
// by default for these so callers get a parsed object, and never for the
// text-only verbs (describe, logs, diff, cordon, …) where kubectl would reject
// it. Measured, not assumed: `kubectl delete -o json` answers "unexpected -o
// output mode: json. We only support '-o name'", so delete gets `-o name`.
var kubectlJSONCapable = map[string]bool{
	"get": true, "apply": true, "apply-dry-run": true, "create": true, "scale": true,
	"patch": true, "version": true, "events": true, "label": true, "annotate": true,
}

// kubectlNameCapable are the verbs whose only structured output is `-o name`.
var kubectlNameCapable = map[string]bool{"delete": true}

func (m *Kubectl) Description() string {
	return "" +
		"Run kubectl against the cluster this host's kubeconfig points at — the whole kubectl surface in " +
		"one tool with a structured input. verb is the kubectl verb (\"get\", \"apply\", \"delete\", \"scale\", " +
		"\"rollout restart\", \"rollout undo\", \"logs\", \"describe\", \"cordon\", \"drain\", …), resource/name/" +
		"namespace address the object, manifest is a YAML/JSON document fed on stdin for apply/delete. " +
		"Read verbs (get, describe, logs, top, events, api-resources, version, explain, diff, rollout " +
		"status/history, auth can-i, and apply-dry-run = `apply --dry-run=server`, the server-side preview) " +
		"run even in check_mode and report changed=false. Every other verb is mutating — write-gated, " +
		"skipped under dry_run=true. apply is ALWAYS server-side apply with field manager \"" +
		KubectlFieldManager + "\" (--validate=strict), so the fields this tool set are visible in " +
		"managedFields. `-o json` is added automatically for verbs that support it; the parsed object " +
		"is returned as data.parsed. A non-zero exit code is returned as data (rc, stderr), not as an " +
		"error — stderr is the reason the caller must show. Interactive verbs (exec, attach, " +
		"port-forward, proxy, edit, debug) are refused. etcd is never touched: the API server is the " +
		"only writer, and this tool only ever talks to it."
}

func (m *Kubectl) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"verb":           stringProp("The kubectl verb, e.g. \"get\", \"apply\", \"apply-dry-run\", \"delete\", \"scale\", \"rollout restart\", \"rollout undo\", \"rollout status\", \"logs\", \"describe\", \"events\", \"cordon\", \"uncordon\", \"drain\", \"label\", \"annotate\", \"api-resources\", \"version\"."),
		"resource":       stringProp("Resource type (\"pods\", \"deployment\", \"deploy.apps\", \"configmap\", …). Omit for apply/delete with a manifest and for verbs that take none (version, api-resources)."),
		"name":           stringProp("Object name. Omit to address every object of the resource type."),
		"namespace":      stringProp("Namespace (-n). Omit for cluster-scoped objects or to use the kubeconfig's default namespace."),
		"all_namespaces": boolProp("List across all namespaces (-A). Only for list verbs; overrides namespace.", false),
		"manifest":       stringProp("A YAML or JSON document (one or more objects) fed to kubectl on stdin as `-f -`. Required for apply and apply-dry-run; optional for delete and diff."),
		"args": map[string]any{
			"type":        "array",
			"items":       map[string]any{"type": "string"},
			"description": "Extra positional arguments and flags appended after the structured ones, e.g. [\"--replicas=3\"] for scale, [\"--to-revision=2\"] for rollout undo, [\"--ignore-daemonsets\"] for drain, [\"-c\",\"web\",\"--tail=200\",\"--previous\"] for logs.",
		},
		"output":     stringProp("Output format (-o): \"json\" (default for verbs that support it), \"yaml\", \"wide\", \"name\", or \"text\" for kubectl's plain table/text output with no -o flag."),
		"kubeconfig": stringProp("Path to a kubeconfig file (--kubeconfig). Default: KUBECONFIG or ~/.kube/config of the agent's user."),
		"context":    stringProp("kubeconfig context (--context). Default: the file's current-context."),
		"dry_run":    boolProp("When true, mutating verbs are reported but not executed (check_mode). Read verbs and apply-dry-run still run.", false),
	}, "verb")
}

func (m *Kubectl) Writes() bool { return true }

// kubectlArgv builds the command line from the structured params. It is a
// pure function so the test can pin every flag the console relies on.
func kubectlArgv(verb string, params map[string]any) (argv []string, stdin string, readOnly bool, err error) {
	resource, _ := stringParam(params, "resource", false, "")
	name, _ := stringParam(params, "name", false, "")
	namespace, _ := stringParam(params, "namespace", false, "")
	manifest, _ := stringParam(params, "manifest", false, "")
	output, _ := stringParam(params, "output", false, "")
	kubeconfig, _ := stringParam(params, "kubeconfig", false, "")
	kctx, _ := stringParam(params, "context", false, "")
	allNS, err := boolParam(params, "all_namespaces", false)
	if err != nil {
		return nil, "", false, err
	}
	extra, err := stringSliceParam(params, "args", false)
	if err != nil {
		return nil, "", false, err
	}

	argv = []string{"kubectl"}
	if kubeconfig != "" {
		argv = append(argv, "--kubeconfig", kubeconfig)
	}
	if kctx != "" {
		argv = append(argv, "--context", kctx)
	}

	switch verb {
	case "apply", "apply-dry-run":
		if strings.TrimSpace(manifest) == "" {
			return nil, "", false, fmt.Errorf("kubectl %s: manifest is required (the document to apply, fed on stdin)", verb)
		}
		argv = append(argv, "apply", "--server-side", "--field-manager="+KubectlFieldManager, "--validate=strict")
		if verb == "apply-dry-run" {
			argv = append(argv, "--dry-run=server")
		}
		argv = append(argv, "-f", "-")
		stdin = manifest
	case "delete", "diff":
		argv = append(argv, strings.Fields(verb)...)
		if strings.TrimSpace(manifest) != "" {
			argv = append(argv, "-f", "-")
			stdin = manifest
		} else {
			if resource == "" {
				return nil, "", false, fmt.Errorf("kubectl %s: either manifest or resource is required", verb)
			}
			argv = append(argv, resource)
			if name != "" {
				argv = append(argv, name)
			}
		}
	default:
		argv = append(argv, strings.Fields(verb)...)
		if resource != "" {
			argv = append(argv, resource)
		}
		if name != "" {
			argv = append(argv, name)
		}
	}

	if allNS {
		argv = append(argv, "-A")
	} else if namespace != "" {
		argv = append(argv, "-n", namespace)
	}

	switch {
	case output == "text":
		// kubectl's own table/text output, no -o.
	case output != "":
		argv = append(argv, "-o", output)
	case kubectlJSONCapable[verb]:
		argv = append(argv, "-o", "json")
	case kubectlNameCapable[verb]:
		argv = append(argv, "-o", "name")
	}
	argv = append(argv, extra...)
	return argv, stdin, kubectlReadOnly[verb], nil
}

func (m *Kubectl) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	verb, err := stringParam(params, "verb", true, "")
	if err != nil {
		return Result{}, err
	}
	verb = strings.Join(strings.Fields(verb), " ")
	if verb == "" {
		return Result{}, fmt.Errorf("kubectl: verb must not be empty")
	}
	if kubectlInteractive[verb] || kubectlInteractive[strings.Fields(verb)[0]] {
		return Result{}, fmt.Errorf("kubectl %s: interactive verbs need a terminal and cannot run as a module call — use logs/describe/events for inspection, or the console's own shell", verb)
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	argv, stdin, readOnly, err := kubectlArgv(verb, params)
	if err != nil {
		return Result{}, err
	}
	data := map[string]any{"verb": verb, "cmd": strings.Join(argv, " ")}

	if !readOnly && dryRun {
		data["skipped"] = true
		return Result{Changed: true, Msg: "would run " + strings.Join(argv, " "), Data: data}, nil
	}

	stdout, stderr, rc, err := m.Exec(ctx, stdin, argv)
	if err != nil {
		return Result{}, fmt.Errorf("kubectl %s: %w", verb, err)
	}
	data["rc"] = rc
	data["stdout"] = string(stdout)
	data["stderr"] = string(stderr)
	if wantsJSON(argv) {
		var parsed any
		if jerr := json.Unmarshal(bytes.TrimSpace(stdout), &parsed); jerr == nil {
			data["parsed"] = parsed
		}
	}

	switch {
	case verb == "diff":
		// kubectl diff: 0 = identical, 1 = differences, >1 = error.
		data["differs"] = rc == 1
		if rc > 1 {
			data["error"] = firstLine(stderr)
			return Result{Changed: false, Msg: "kubectl diff failed: " + firstLine(stderr), Data: data}, nil
		}
		return Result{Changed: false, Msg: fmt.Sprintf("kubectl diff: differs=%v", rc == 1), Data: data}, nil
	case rc != 0:
		data["error"] = firstLine(stderr)
		return Result{Changed: false, Msg: "kubectl " + verb + " failed (rc " + fmt.Sprint(rc) + "): " + firstLine(stderr), Data: data}, nil
	case readOnly:
		return Result{Changed: false, Msg: "kubectl " + verb, Data: data}, nil
	default:
		return Result{Changed: true, Msg: "kubectl " + verb, Data: data}, nil
	}
}

func wantsJSON(argv []string) bool {
	for i := 0; i+1 < len(argv); i++ {
		if argv[i] == "-o" && argv[i+1] == "json" {
			return true
		}
	}
	return false
}

func firstLine(b []byte) string {
	s := strings.TrimSpace(string(b))
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}
