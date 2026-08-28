package modules

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// Print the FULL parser diagnosis for every template on the ratchet — the ratchet's own reasons are
// truncated at 400 characters, and for 50 of the 52 syntax errors the diagnosis sits AFTER the echoed
// template text and is therefore cut off. Without it there is no way to tell a class from a one-off, and
// "52 individual defects" was a guess.
//
//	TEMPLATE_DIAGNOSE=1 go test ./internal/modules/ -run TemplateDiagnose -v
//
// Read-only: it writes no ratchet and no template.
func TestTemplateDiagnoseBrokenReasons(t *testing.T) {
	if os.Getenv("TEMPLATE_DIAGNOSE") == "" {
		t.Skip("set TEMPLATE_DIAGNOSE=1 to print the full diagnosis for every ratcheted template")
	}
	raw, err := os.ReadFile("../../configs/template_render_broken.json")
	if err != nil {
		t.Fatal(err)
	}
	var broken map[string]string
	if err := json.Unmarshal(raw, &broken); err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(broken))
	for name := range broken {
		names = append(names, name)
	}
	sort.Strings(names)

	// The diagnosis, with the echoed template text stripped: gonja puts the message first, then the whole
	// body, then "(Line: N Col: M ...)". Grouping needs the message and the position, not the body.
	head := regexp.MustCompile(`^[^']*`)
	tail := regexp.MustCompile(`\(Line: \d+ Col: \d+[^)]*\)`)
	counts := map[string]int{}
	for _, name := range names {
		err := renderTemplateWithSample("../../configs/config_templates", name, t.TempDir()+"/out")
		if err == nil {
			t.Errorf("%s: on the ratchet but renders fine — a stale entry", name)
			continue
		}
		msg := err.Error()
		diag := strings.TrimSpace(head.FindString(msg))
		if pos := tail.FindString(msg); pos != "" {
			diag += " " + pos
		}
		key := regexp.MustCompile(`Line: \d+ Col: \d+`).ReplaceAllString(diag, "Line: N Col: M")
		counts[key]++
		t.Logf("%-34s %s", name, diag)
	}
	t.Log("---- by diagnosis ----")
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return counts[keys[i]] > counts[keys[j]] })
	for _, k := range keys {
		t.Logf("%4d  %s", counts[k], k)
	}
}

// Render ONE named template with its sample and print the result — the verification step for a mechanical
// template repair. The repair scripts render before and after a rewrite and demand byte-identical output:
// these templates render today, so their sample provably never reaches the rewritten line, and any change in
// the output means the rewrite touched a path the sample DOES take.
//
//	TEMPLATE_RENDER_ONE=apt-cudf go test ./internal/modules/ -run TestTemplateRenderOne
func TestTemplateRenderOne(t *testing.T) {
	name := os.Getenv("TEMPLATE_RENDER_ONE")
	if name == "" {
		t.Skip("set TEMPLATE_RENDER_ONE to a template directory name")
	}
	dest := t.TempDir() + "/out"
	if err := renderTemplateWithSample("../../configs/config_templates", name, dest); err != nil {
		t.Fatalf("render %s: %v", name, err)
	}
	body, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("read rendered file: %v", err)
	}
	// Printed rather than logged with the test name, so the caller compares only the CONTENT.
	fmt.Print(string(body))
}
