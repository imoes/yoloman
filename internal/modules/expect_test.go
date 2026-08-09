package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFirstUnansweredMatch_FindsMatchingPattern(t *testing.T) {
	patterns, err := compileExpectPatterns(map[string]string{
		"Username:": "deploy",
		"Password:": "hunter2",
	})
	if err != nil {
		t.Fatal(err)
	}
	answered := make([]bool, len(patterns))
	idx, ok := firstUnansweredMatch("Please enter Username:", patterns, answered)
	if !ok {
		t.Fatal("expected a match")
	}
	if patterns[idx].answer != "deploy" {
		t.Errorf("answer = %q, want deploy", patterns[idx].answer)
	}
}

func TestFirstUnansweredMatch_SkipsAlreadyAnswered(t *testing.T) {
	patterns, err := compileExpectPatterns(map[string]string{"Username:": "deploy"})
	if err != nil {
		t.Fatal(err)
	}
	answered := []bool{true}
	_, ok := firstUnansweredMatch("Username:", patterns, answered)
	if ok {
		t.Error("expected no match once already answered")
	}
}

func TestFirstUnansweredMatch_NoMatch(t *testing.T) {
	patterns, err := compileExpectPatterns(map[string]string{"Username:": "deploy"})
	if err != nil {
		t.Fatal(err)
	}
	answered := make([]bool, len(patterns))
	_, ok := firstUnansweredMatch("nothing relevant here", patterns, answered)
	if ok {
		t.Error("expected no match")
	}
}

func TestCompileExpectPatterns_InvalidRegexErrors(t *testing.T) {
	_, err := compileExpectPatterns(map[string]string{"[invalid": "x"})
	if err == nil {
		t.Fatal("expected error for an invalid regex")
	}
}

func TestExpect_MissingResponsesRejected(t *testing.T) {
	e := NewExpect()
	_, err := e.Run(context.Background(), map[string]any{"cmd": "true"}, false)
	if err == nil {
		t.Fatal("expected error when responses is missing")
	}
}

func TestExpect_EmptyResponsesRejected(t *testing.T) {
	e := NewExpect()
	_, err := e.Run(context.Background(), map[string]any{
		"cmd": "true", "responses": map[string]any{},
	}, false)
	if err == nil {
		t.Fatal("expected error when responses is empty")
	}
}

func TestExpect_DryRunDoesNotExecute(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "ran")
	scriptPath := filepath.Join(dir, "touch.sh")
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\ntouch "+marker+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	e := NewExpect()
	res, err := e.Run(context.Background(), map[string]any{
		"cmd": scriptPath, "responses": map[string]any{"x": "y"}, "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Error("expected dry_run to not actually execute the script")
	}
}

// TestExpect_RealScriptRespondsToPrompt exercises the module against a
// real interactive shell script that prompts for a name and echoes it
// back, proving the poll/match/write-to-stdin loop actually works against
// a real process, not just the pure matching helper above.
func TestExpect_RealScriptRespondsToPrompt(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "prompt.sh")
	script := "#!/bin/sh\n" +
		"printf 'Name: '\n" +
		"read name\n" +
		"echo \"Hello, $name!\"\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	e := NewExpect()
	res, err := e.Run(context.Background(), map[string]any{
		"cmd":       scriptPath,
		"responses": map[string]any{"Name:": "World"},
		"timeout":   "5",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	data := res.Data.(map[string]any)
	if data["rc"] != 0 {
		t.Errorf("rc = %v, want 0", data["rc"])
	}
	if data["responses_sent"] != 1 {
		t.Errorf("responses_sent = %v, want 1", data["responses_sent"])
	}
	output, _ := data["output"].(string)
	if !strings.Contains(output, "Hello, World!") {
		t.Errorf("output = %q, want it to contain %q", output, "Hello, World!")
	}
}
