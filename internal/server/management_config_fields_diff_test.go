package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
)

func splitLines(s string) []string {
	out := []string{}
	for _, line := range strings.Split(s, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	return out
}

func urlEscape(s string) string { return url.QueryEscape(s) }

// A DIFFERENTIAL check against Bossman, because "no rule is reimplemented" is a claim that can be measured.
//
// The unit tests above use fixtures and prove the assembly. They cannot prove the thing that actually matters:
// that the agent, reading the shipped projection, gives the SAME answer Bossman computes from the rules. Two
// implementations of one question is the failure mode this whole design avoids, so it gets a test rather than
// a comment.
//
//	AGENT_CONFIG_DIR=./configs go test ./internal/server/ -run ConfigFieldsMatchBossman
//
// scripts/diff-agent-config-fields.sh drives it and asks Bossman for the same paths.
func TestConfigFieldsMatchBossman_LocalHalf(t *testing.T) {
	dir := os.Getenv("AGENT_CONFIG_DIR")
	if dir == "" {
		t.Skip("set AGENT_CONFIG_DIR to the real catalog to dump the agent's answers")
	}
	paths := os.Getenv("AGENT_DIFF_PATHS")
	if paths == "" {
		t.Skip("set AGENT_DIFF_PATHS to a newline-separated list of paths")
	}
	out := os.Getenv("AGENT_DIFF_OUT")
	if out == "" {
		t.Fatal("set AGENT_DIFF_OUT to the file the answers are written to")
	}
	old := configsDir
	configsDir = dir
	t.Cleanup(func() { configsDir = old })

	mux := http.NewServeMux()
	RegisterConfigFieldRoutes(mux)
	answers := map[string]any{}
	for _, p := range splitLines(paths) {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest("GET",
			"/api/v1/config-fields?family="+os.Getenv("AGENT_DIFF_FAMILY")+"&path="+urlEscape(p), nil))
		var a map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &a); err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		answers[p] = a
	}
	blob, err := json.MarshalIndent(answers, "", " ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(out, blob, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %d answers to %s", len(answers), out)
}
