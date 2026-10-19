package modules

import (
	"context"
	"strings"
	"testing"
)

type kubectlCall struct {
	stdin string
	argv  []string
}

func fakeKubectl(t *testing.T, calls *[]kubectlCall, stdout, stderr string, rc int) KubectlExecFunc {
	t.Helper()
	return func(ctx context.Context, stdin string, argv []string) ([]byte, []byte, int, error) {
		*calls = append(*calls, kubectlCall{stdin: stdin, argv: argv})
		return []byte(stdout), []byte(stderr), rc, nil
	}
}

func TestKubectl_GetRunsUnderDryRunAndParsesJSON(t *testing.T) {
	var calls []kubectlCall
	m := &Kubectl{Exec: fakeKubectl(t, &calls, `{"kind":"List","items":[]}`, "", 0)}
	res, err := m.Run(context.Background(), map[string]any{
		"verb": "get", "resource": "pods", "all_namespaces": true, "dry_run": true,
	}, true)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(calls) != 1 {
		t.Fatalf("a read verb must run even under dry_run; calls=%d", len(calls))
	}
	if got := strings.Join(calls[0].argv, " "); got != "kubectl get pods -A -o json" {
		t.Errorf("argv = %q", got)
	}
	if res.Changed {
		t.Error("a read verb must report changed=false")
	}
	data := res.Data.(map[string]any)
	if data["parsed"].(map[string]any)["kind"] != "List" {
		t.Errorf("parsed JSON missing: %+v", data)
	}
}

func TestKubectl_ApplyIsServerSideWithFieldManagerAndStdin(t *testing.T) {
	var calls []kubectlCall
	m := &Kubectl{Exec: fakeKubectl(t, &calls, `{"kind":"ConfigMap"}`, "", 0)}
	manifest := "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n"
	res, err := m.Run(context.Background(), map[string]any{
		"verb": "apply", "manifest": manifest, "namespace": "demo",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got := strings.Join(calls[0].argv, " ")
	for _, want := range []string{"--server-side", "--field-manager=bossman", "--validate=strict", "-f -", "-n demo", "-o json"} {
		if !strings.Contains(got, want) {
			t.Errorf("argv %q lacks %q", got, want)
		}
	}
	if strings.Contains(got, "--dry-run") {
		t.Errorf("a real apply must not carry --dry-run: %q", got)
	}
	if calls[0].stdin != manifest {
		t.Errorf("manifest must reach stdin verbatim; got %q", calls[0].stdin)
	}
	if !res.Changed {
		t.Error("a successful apply reports changed=true")
	}
}

func TestKubectl_ApplyDryRunIsAReadAndRunsUnderDryRun(t *testing.T) {
	var calls []kubectlCall
	m := &Kubectl{Exec: fakeKubectl(t, &calls, `{}`, "Warning: would violate PodSecurity", 0)}
	res, err := m.Run(context.Background(), map[string]any{
		"verb": "apply-dry-run", "manifest": "kind: Pod\n", "dry_run": true,
	}, true)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(calls) != 1 {
		t.Fatal("apply-dry-run must execute even under dry_run — it is the server-side preview")
	}
	got := strings.Join(calls[0].argv, " ")
	if !strings.Contains(got, "--dry-run=server") || !strings.Contains(got, "--server-side") {
		t.Errorf("argv %q must be a server-side dry run", got)
	}
	if res.Changed {
		t.Error("the preview must report changed=false")
	}
	if !strings.Contains(res.Data.(map[string]any)["stderr"].(string), "PodSecurity") {
		t.Error("server warnings on stderr must be surfaced")
	}
}

func TestKubectl_DryRunSkipsMutating(t *testing.T) {
	m := &Kubectl{Exec: func(ctx context.Context, stdin string, argv []string) ([]byte, []byte, int, error) {
		t.Errorf("dry_run must not execute a mutating verb: %v", argv)
		return nil, nil, 0, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{
		"verb": "scale", "resource": "deployment", "name": "web", "args": []any{"--replicas=3"}, "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if !res.Changed || data["skipped"] != true {
		t.Errorf("dry_run on a mutating verb should report would-change + skipped: %+v", data)
	}
	if !strings.HasSuffix(data["cmd"].(string), "scale deployment web -o json --replicas=3") {
		t.Errorf("cmd = %q", data["cmd"])
	}
}

func TestKubectl_TwoWordVerbsAreClassifiedAsAWhole(t *testing.T) {
	var calls []kubectlCall
	m := &Kubectl{Exec: fakeKubectl(t, &calls, "deployment \"web\" successfully rolled out\n", "", 0)}
	res, err := m.Run(context.Background(), map[string]any{
		"verb": "rollout status", "resource": "deployment/web", "namespace": "demo", "dry_run": true,
	}, true)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(calls) != 1 || res.Changed {
		t.Fatal("rollout status is a read verb: runs under dry_run, changed=false")
	}
	if got := strings.Join(calls[0].argv, " "); got != "kubectl rollout status deployment/web -n demo" {
		t.Errorf("argv = %q (rollout status is text-only, no -o json)", got)
	}
	// and the mutating sibling is gated
	m2 := &Kubectl{Exec: func(ctx context.Context, stdin string, argv []string) ([]byte, []byte, int, error) {
		t.Errorf("rollout restart must be gated under dry_run: %v", argv)
		return nil, nil, 0, nil
	}}
	if _, err := m2.Run(context.Background(), map[string]any{"verb": "rollout restart", "resource": "deployment/web"}, true); err != nil {
		t.Fatalf("Run: %v", err)
	}
}

func TestKubectl_DiffExitOneIsDataNotError(t *testing.T) {
	var calls []kubectlCall
	m := &Kubectl{Exec: fakeKubectl(t, &calls, "-  replicas: 1\n+  replicas: 3\n", "", 1)}
	res, err := m.Run(context.Background(), map[string]any{"verb": "diff", "manifest": "kind: Deployment\n"}, false)
	if err != nil {
		t.Fatalf("diff rc 1 must not be an error: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["differs"] != true || data["rc"] != 1 || res.Changed {
		t.Errorf("diff rc 1 → differs=true, changed=false; got %+v changed=%v", data, res.Changed)
	}
	if got := strings.Join(calls[0].argv, " "); got != "kubectl diff -f -" {
		t.Errorf("argv = %q", got)
	}
}

func TestKubectl_DeleteUsesNameOutputNotJSON(t *testing.T) {
	var calls []kubectlCall
	m := &Kubectl{Exec: fakeKubectl(t, &calls, "configmap/x deleted\n", "", 0)}
	res, err := m.Run(context.Background(), map[string]any{"verb": "delete", "resource": "ConfigMap", "name": "x", "namespace": "d"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := strings.Join(calls[0].argv, " "); got != "kubectl delete ConfigMap x -n d -o name" {
		t.Errorf("argv = %q (kubectl delete only supports -o name)", got)
	}
	if !res.Changed {
		t.Error("a delete that ran reports changed=true")
	}
}

func TestKubectl_NonZeroExitIsDataWithReason(t *testing.T) {
	var calls []kubectlCall
	m := &Kubectl{Exec: fakeKubectl(t, &calls, "", "Error from server (NotFound): deployments.apps \"nope\" not found\nmore", 1)}
	res, err := m.Run(context.Background(), map[string]any{"verb": "get", "resource": "deployment", "name": "nope"}, false)
	if err != nil {
		t.Fatalf("a non-zero exit is data: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["rc"] != 1 || !strings.Contains(data["error"].(string), "NotFound") || strings.Contains(data["error"].(string), "more") {
		t.Errorf("error must be the first stderr line: %+v", data)
	}
	if !strings.Contains(res.Msg, "NotFound") {
		t.Errorf("Msg must carry the reason: %q", res.Msg)
	}
}

func TestKubectl_RefusesInteractiveAndRequiresVerbAndManifest(t *testing.T) {
	m := NewKubectl()
	if !m.Writes() {
		t.Error("kubectl writes")
	}
	if _, err := m.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Error("verb is required")
	}
	if _, err := m.Run(context.Background(), map[string]any{"verb": "exec", "resource": "pod/x"}, false); err == nil {
		t.Error("exec must be refused")
	}
	if _, err := m.Run(context.Background(), map[string]any{"verb": "apply"}, false); err == nil {
		t.Error("apply without manifest must be refused")
	}
	if _, err := m.Run(context.Background(), map[string]any{"verb": "delete"}, false); err == nil {
		t.Error("delete without manifest or resource must be refused")
	}
}

func TestKubectl_OutputTextAndKubeconfigContext(t *testing.T) {
	var calls []kubectlCall
	m := &Kubectl{Exec: fakeKubectl(t, &calls, "NAME  READY\n", "", 0)}
	if _, err := m.Run(context.Background(), map[string]any{
		"verb": "get", "resource": "pods", "output": "text", "kubeconfig": "/tmp/kc", "context": "dev",
	}, false); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := strings.Join(calls[0].argv, " "); got != "kubectl --kubeconfig /tmp/kc --context dev get pods" {
		t.Errorf("argv = %q", got)
	}
}
