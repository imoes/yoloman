package server

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/tasks"
)

func connectTaskServer(t *testing.T, list []*tasks.Task, modReg *modules.Registry, policy *pipeline.Policy, write bool) *mcp.ClientSession {
	t.Helper()
	s := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	if err := RegisterTasks(s, list, modReg, policy, write, nil, nil); err != nil {
		t.Fatalf("RegisterTasks: %v", err)
	}
	RegisterRunPipeline(s, policy, write, nil, nil)

	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ctx := context.Background()
	go func() { _ = s.Run(ctx, serverTransport) }()

	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func mustParseTask(t *testing.T, yaml string) *tasks.Task {
	t.Helper()
	task, err := tasks.ParseFile([]byte(yaml))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	return task
}

func TestRegisterTasks_ReadOnlyTaskAlwaysRegistered(t *testing.T) {
	task := mustParseTask(t, `
name: check_root
description: "check /"
stat:
  path: /
`)
	modReg := modules.NewRegistry()
	_ = modReg.Register(modules.NewStat())

	cs := connectTaskServer(t, []*tasks.Task{task}, modReg, pipeline.EmptyPolicy(), false)
	names := toolNames(t, cs)
	if !names["check_root"] {
		t.Error("expected read-only task tool to be registered even with write=false")
	}
}

func TestRegisterTasks_WriteTaskHiddenWhenWriteFalse(t *testing.T) {
	task := mustParseTask(t, `
name: restart_nginx
description: "restart nginx"
systemd:
  name: nginx
  state: restarted
`)
	modReg := modules.NewRegistry()
	_ = modReg.Register(modules.NewSystemd())

	cs := connectTaskServer(t, []*tasks.Task{task}, modReg, pipeline.EmptyPolicy(), false)
	names := toolNames(t, cs)
	if names["restart_nginx"] {
		t.Error("expected write-backed task tool to be absent when write=false")
	}
}

func TestRegisterTasks_WriteTaskPresentWhenWriteTrue(t *testing.T) {
	task := mustParseTask(t, `
name: restart_nginx
description: "restart nginx"
systemd:
  name: nginx
  state: restarted
`)
	modReg := modules.NewRegistry()
	_ = modReg.Register(&modules.Systemd{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return nil, nil
	}})

	cs := connectTaskServer(t, []*tasks.Task{task}, modReg, pipeline.EmptyPolicy(), true)
	names := toolNames(t, cs)
	if !names["restart_nginx"] {
		t.Error("expected write-backed task tool to be present when write=true")
	}
}

func TestRegisterTasks_CallRoundTrip(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "motd")
	task := mustParseTask(t, `
name: deploy_motd
description: "set motd"
copy:
  dest: `+dest+`
  content: "{{ message }}"
params:
  message:
    type: string
    required: true
`)
	modReg := modules.NewRegistry()
	_ = modReg.Register(modules.NewCopy())

	cs := connectTaskServer(t, []*tasks.Task{task}, modReg, pipeline.EmptyPolicy(), true)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "deploy_motd",
		Arguments: map[string]any{"message": "hello from a task"},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}
	got, err := os.ReadFile(dest)
	if err != nil || string(got) != "hello from a task" {
		t.Errorf("dest content = %q (err=%v)", got, err)
	}
}

func TestRegisterRunPipeline_HiddenWhenWriteFalse(t *testing.T) {
	cs := connectTaskServer(t, nil, modules.NewRegistry(), pipeline.EmptyPolicy(), false)
	names := toolNames(t, cs)
	if names["run_pipeline"] {
		t.Error("expected run_pipeline to be absent when write=false")
	}
}

func TestRegisterRunPipeline_CallRoundTrip(t *testing.T) {
	policy := &pipeline.Policy{Allow: []pipeline.AllowedCommand{{Binary: "printf"}, {Binary: "grep"}}}
	cs := connectTaskServer(t, nil, modules.NewRegistry(), policy, true)

	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "run_pipeline",
		Arguments: map[string]any{
			"stages": []any{
				[]any{"printf", "hello\nworld\n"},
				[]any{"grep", "world"},
			},
		},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}
	out := res.StructuredContent.(map[string]any)
	if out["stdout"] != "world\n" {
		t.Errorf("stdout = %v, want %q", out["stdout"], "world\n")
	}
}

func TestRegisterRunPipeline_PolicyRejectsDisallowedBinary(t *testing.T) {
	policy := &pipeline.Policy{Allow: []pipeline.AllowedCommand{{Binary: "printf"}}}
	cs := connectTaskServer(t, nil, modules.NewRegistry(), policy, true)

	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "run_pipeline",
		Arguments: map[string]any{
			"stages": []any{[]any{"rm", "-rf", "/"}},
		},
	})
	if err != nil {
		t.Fatalf("CallTool transport error: %v", err)
	}
	if !res.IsError {
		t.Fatal("expected policy to reject an unlisted binary")
	}
}
