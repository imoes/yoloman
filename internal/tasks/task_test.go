package tasks

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/checks"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
)

func TestParseFile_ModuleTaskWithFixedParams(t *testing.T) {
	task, err := ParseFile([]byte(`
name: restart_nginx
description: "restart nginx"
ansible.builtin.service:
  name: nginx
  state: restarted
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if task.Name != "restart_nginx" || task.Module != "service" {
		t.Errorf("unexpected task: %+v", task)
	}
	if task.Body["name"] != "nginx" || task.Body["state"] != "restarted" {
		t.Errorf("unexpected body: %+v", task.Body)
	}
	if task.IsPipeline() {
		t.Error("expected module task, not pipeline")
	}
}

func TestParseFile_ModuleTaskWithPlaceholderParam(t *testing.T) {
	task, err := ParseFile([]byte(`
name: deploy_motd
description: "set motd"
ansible.builtin.copy:
  dest: /etc/motd
  content: "{{ message }}"
params:
  message:
    type: string
    required: true
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	spec, ok := task.Params["message"]
	if !ok || !spec.Required || spec.Type != "string" {
		t.Errorf("unexpected params: %+v", task.Params)
	}
}

func TestParseFile_CheckTask(t *testing.T) {
	task, err := ParseFile([]byte(`
name: check_root_disk
description: "root filesystem usage"
check: [/bin/sh, -c, "echo 'OK - fine'; exit 0"]
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if !task.IsCheck() {
		t.Fatal("expected check task")
	}
	if len(task.Check) != 3 || task.Check[0] != "/bin/sh" {
		t.Errorf("unexpected check argv: %+v", task.Check)
	}
}

func TestParseFile_PipelineTask(t *testing.T) {
	task, err := ParseFile([]byte(`
name: nginx_errors
description: "recent nginx error lines"
pipeline:
  - [dmesg]
  - [grep, -i, error]
  - [tail, -n, "50"]
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if !task.IsPipeline() {
		t.Fatal("expected pipeline task")
	}
	if len(task.Pipeline) != 3 || task.Pipeline[1][0] != "grep" {
		t.Errorf("unexpected pipeline: %+v", task.Pipeline)
	}
}

func TestParseFile_MissingName(t *testing.T) {
	if _, err := ParseFile([]byte(`description: "x"`)); err == nil {
		t.Fatal("expected error for missing name")
	}
}

func TestParseFile_NeitherModuleNorPipeline(t *testing.T) {
	if _, err := ParseFile([]byte(`
name: bad
description: "x"
`)); err == nil {
		t.Fatal("expected error when neither module nor pipeline key given")
	}
}

func TestParseFile_BothModuleAndPipeline(t *testing.T) {
	_, err := ParseFile([]byte(`
name: bad
description: "x"
ansible.builtin.command:
  cmd: "ls"
pipeline:
  - [ls]
`))
	if err == nil {
		t.Fatal("expected error when both module and pipeline keys given")
	}
}

func TestParseFile_MultipleModuleKeys(t *testing.T) {
	_, err := ParseFile([]byte(`
name: bad
description: "x"
ansible.builtin.command:
  cmd: "ls"
ansible.builtin.copy:
  dest: /tmp/x
  content: "y"
`))
	if err == nil {
		t.Fatal("expected error for multiple ansible.builtin.* keys")
	}
}

func TestParseFile_UnexpectedTopLevelKey(t *testing.T) {
	_, err := ParseFile([]byte(`
name: bad
description: "x"
random_key: 1
ansible.builtin.command:
  cmd: "ls"
`))
	if err == nil {
		t.Fatal("expected error for unexpected top-level key")
	}
}

func TestParseFile_InvalidParamType(t *testing.T) {
	_, err := ParseFile([]byte(`
name: bad
description: "x"
ansible.builtin.command:
  cmd: "ls"
params:
  foo:
    type: bogus
`))
	if err == nil {
		t.Fatal("expected error for invalid param type")
	}
}

func TestParseFile_InvalidParamPattern(t *testing.T) {
	_, err := ParseFile([]byte(`
name: bad
description: "x"
ansible.builtin.command:
  cmd: "ls"
params:
  foo:
    pattern: "[invalid"
`))
	if err == nil {
		t.Fatal("expected error for invalid regex pattern")
	}
}

func TestTask_Writes_ModuleTaskDelegatesToModule(t *testing.T) {
	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewStat())
	_ = reg.Register(modules.NewCommand())

	readTask, _ := ParseFile([]byte(`
name: check_path
description: "x"
ansible.builtin.stat:
  path: /tmp
`))
	writes, err := readTask.Writes(reg)
	if err != nil || writes {
		t.Errorf("expected stat-backed task to not write, got writes=%v err=%v", writes, err)
	}

	writeTask, _ := ParseFile([]byte(`
name: run_something
description: "x"
ansible.builtin.command:
  cmd: "ls"
`))
	writes, err = writeTask.Writes(reg)
	if err != nil || !writes {
		t.Errorf("expected command-backed task to write, got writes=%v err=%v", writes, err)
	}
}

func TestTask_Writes_PipelineAlwaysWrites(t *testing.T) {
	task, _ := ParseFile([]byte(`
name: p
description: "x"
pipeline:
  - [echo, hi]
`))
	writes, err := task.Writes(modules.NewRegistry())
	if err != nil || !writes {
		t.Errorf("expected pipeline task to always report writes=true, got %v %v", writes, err)
	}
}

func TestTask_Writes_CheckAlwaysReadOnly(t *testing.T) {
	task, _ := ParseFile([]byte(`
name: check_x
description: "x"
check: [/bin/true]
`))
	writes, err := task.Writes(modules.NewRegistry())
	if err != nil || writes {
		t.Errorf("expected check task to always report writes=false, got %v %v", writes, err)
	}
}

func TestTask_Writes_UnknownModule(t *testing.T) {
	task, _ := ParseFile([]byte(`
name: bad
description: "x"
ansible.builtin.nonexistent_module:
  foo: bar
`))
	if _, err := task.Writes(modules.NewRegistry()); err == nil {
		t.Fatal("expected error referencing an unknown module")
	}
}

func TestTask_Run_ModuleTaskWithFixedParams(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "checked")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	task, err := ParseFile([]byte(`
name: check_it
description: "x"
ansible.builtin.stat:
  path: ` + target + `
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}

	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewStat())

	res, err := task.Run(context.Background(), reg, pipeline.EmptyPolicy(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["exists"] != true {
		t.Errorf("expected exists=true, got %+v", data)
	}
}

func TestTask_Run_ModuleTaskWithPlaceholderSubstitution(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "motd")
	task, err := ParseFile([]byte(`
name: deploy_motd
description: "x"
ansible.builtin.copy:
  dest: ` + dest + `
  content: "{{ message }}"
params:
  message:
    type: string
    required: true
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}

	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewCopy())

	res, err := task.Run(context.Background(), reg, pipeline.EmptyPolicy(), map[string]any{"message": "hello world"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true on first write")
	}
	got, err := os.ReadFile(dest)
	if err != nil || string(got) != "hello world" {
		t.Errorf("dest content = %q (err=%v), want %q", got, err, "hello world")
	}
}

func TestTask_Run_MissingRequiredParam(t *testing.T) {
	task, _ := ParseFile([]byte(`
name: deploy_motd
description: "x"
ansible.builtin.copy:
  dest: /tmp/x
  content: "{{ message }}"
params:
  message:
    type: string
    required: true
`))
	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewCopy())
	if _, err := task.Run(context.Background(), reg, pipeline.EmptyPolicy(), nil, false); err == nil {
		t.Fatal("expected error for missing required parameter")
	}
}

func TestTask_Run_UnknownParamRejected(t *testing.T) {
	task, _ := ParseFile([]byte(`
name: deploy_motd
description: "x"
ansible.builtin.copy:
  dest: /tmp/x
  content: "fixed"
`))
	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewCopy())
	if _, err := task.Run(context.Background(), reg, pipeline.EmptyPolicy(), map[string]any{"typo": "x"}, false); err == nil {
		t.Fatal("expected error for unknown parameter")
	}
}

func TestTask_Run_ParamPatternValidation(t *testing.T) {
	task, _ := ParseFile([]byte(`
name: restart_unit
description: "x"
ansible.builtin.systemd:
  name: "{{ unit }}"
  state: restarted
params:
  unit:
    type: string
    required: true
    pattern: "^[a-z0-9_-]+$"
`))
	reg := modules.NewRegistry()
	fakeSystemd := &modules.Systemd{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return nil, nil
	}}
	_ = reg.Register(fakeSystemd)

	if _, err := task.Run(context.Background(), reg, pipeline.EmptyPolicy(), map[string]any{"unit": "nginx; rm -rf /"}, false); err == nil {
		t.Fatal("expected pattern validation to reject an unsafe unit name")
	}

	res, err := task.Run(context.Background(), reg, pipeline.EmptyPolicy(), map[string]any{"unit": "nginx"}, false)
	if err != nil {
		t.Fatalf("Run with valid unit name: %v", err)
	}
	if !res.Changed {
		t.Error("expected restarted state to always report changed=true")
	}
}

func TestTask_Run_PipelineTask(t *testing.T) {
	task, err := ParseFile([]byte(`
name: greet
description: "x"
pipeline:
  - [printf, "hello\nworld\n"]
  - [grep, world]
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	policy := &pipeline.Policy{Allow: []pipeline.AllowedCommand{{Binary: "printf"}, {Binary: "grep"}}}

	res, err := task.Run(context.Background(), modules.NewRegistry(), policy, nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected pipeline task to report changed=true")
	}
	pipeRes := res.Data.(pipeline.Result)
	if pipeRes.Stdout != "world\n" {
		t.Errorf("stdout = %q, want %q", pipeRes.Stdout, "world\n")
	}
}

func TestTask_Run_PipelineWithSubstitution(t *testing.T) {
	task, err := ParseFile([]byte(`
name: grep_for
description: "x"
pipeline:
  - [printf, "a\nb\nc\n"]
  - [grep, "{{ needle }}"]
params:
  needle:
    type: string
    required: true
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	policy := &pipeline.Policy{Allow: []pipeline.AllowedCommand{{Binary: "printf"}, {Binary: "grep"}}}

	res, err := task.Run(context.Background(), modules.NewRegistry(), policy, map[string]any{"needle": "b"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	pipeRes := res.Data.(pipeline.Result)
	if pipeRes.Stdout != "b\n" {
		t.Errorf("stdout = %q, want %q", pipeRes.Stdout, "b\n")
	}
}

func TestTask_Run_CheckTask(t *testing.T) {
	task, err := ParseFile([]byte(`
name: check_x
description: "x"
check: [/bin/sh, -c, "echo 'CRITICAL - disk full | used=99%'; exit 2"]
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}

	res, err := task.Run(context.Background(), modules.NewRegistry(), pipeline.EmptyPolicy(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected check task to always report changed=false")
	}
	checkRes := res.Data.(checks.Result)
	if checkRes.Status != checks.StatusCritical {
		t.Errorf("status = %q, want CRITICAL", checkRes.Status)
	}
	if checkRes.Message != "CRITICAL - disk full" {
		t.Errorf("message = %q", checkRes.Message)
	}
	if len(checkRes.Perfdata) != 1 || checkRes.Perfdata[0].Label != "used" {
		t.Errorf("unexpected perfdata: %+v", checkRes.Perfdata)
	}
}

func TestTask_Run_CheckWithSubstitution(t *testing.T) {
	task, err := ParseFile([]byte(`
name: check_threshold
description: "x"
check: [/bin/sh, -c, "echo OK - warn is {{ warn }}"]
params:
  warn:
    type: string
    required: true
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}

	res, err := task.Run(context.Background(), modules.NewRegistry(), pipeline.EmptyPolicy(), map[string]any{"warn": "80"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	checkRes := res.Data.(checks.Result)
	if checkRes.Message != "OK - warn is 80" {
		t.Errorf("message = %q, want substitution to have applied", checkRes.Message)
	}
}

func TestTask_Run_CheckMissingRequiredParam(t *testing.T) {
	task, err := ParseFile([]byte(`
name: check_threshold
description: "x"
check: [/bin/sh, -c, "echo OK - {{ warn }}"]
params:
  warn:
    type: string
    required: true
`))
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if _, err := task.Run(context.Background(), modules.NewRegistry(), pipeline.EmptyPolicy(), nil, false); err == nil {
		t.Fatal("expected error for missing required parameter")
	}
}

func TestLoadDir_ParsesAllFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("a.yaml", "name: a\ndescription: x\nansible.builtin.command:\n  cmd: ls\n")
	write("b.yml", "name: b\ndescription: x\nansible.builtin.command:\n  cmd: ls\n")
	write("ignored.txt", "not a task file")

	list, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("expected 2 tasks, got %d: %+v", len(list), list)
	}
}

func TestLoadDir_DuplicateNameRejected(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("a.yaml", "name: dup\ndescription: x\nansible.builtin.command:\n  cmd: ls\n")
	write("b.yaml", "name: dup\ndescription: x\nansible.builtin.command:\n  cmd: ls\n")

	if _, err := LoadDir(dir); err == nil {
		t.Fatal("expected error for duplicate task name across files")
	}
}

func TestLoadDir_MissingDirReturnsEmpty(t *testing.T) {
	list, err := LoadDir(filepath.Join(t.TempDir(), "does-not-exist"))
	if err != nil {
		t.Fatalf("expected no error for missing tools.d dir, got %v", err)
	}
	if len(list) != 0 {
		t.Errorf("expected empty list, got %v", list)
	}
}

func TestTask_InputSchema(t *testing.T) {
	task, _ := ParseFile([]byte(`
name: deploy_motd
description: "x"
ansible.builtin.copy:
  dest: /etc/motd
  content: "{{ message }}"
params:
  message:
    type: string
    required: true
`))
	schema := task.InputSchema()
	props := schema["properties"].(map[string]any)
	if _, ok := props["message"]; !ok {
		t.Errorf("expected 'message' property in schema, got %+v", schema)
	}
	required := schema["required"].([]string)
	if len(required) != 1 || required[0] != "message" {
		t.Errorf("expected message to be required, got %+v", required)
	}
}
