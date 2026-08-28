// fix-bool-render adds `| lower` to exactly those template substitutions that render a Python-cased boolean,
// and proves each edit by rendering.
//
// WHY A MEASURED EDIT RATHER THAN A RULE. gonja renders a bool Python-cased because Jinja2 does, so
// `debug={{ debug }}` writes "False" — which shell, INI and YAML reject or read as a non-empty (true) string.
// Fixing it in the renderer was tried and reverted: coercing the value to a string made `{% if flag %}` and
// `| yes_no` see a truthy string and take the wrong branch. And `| lower` cannot be applied blindly, because
// it is NOT a no-op for strings — measured, it turns "AbC" into "abc", which would corrupt paths, hostnames
// and values like LOG_DAEMON or CyrKoi.
//
// So each candidate expression is piped, the template re-rendered against its own sample, and the edit KEPT
// ONLY IF the output changed exactly by losing a Python-cased boolean. Any other difference — a lowercased
// string, a render error — and the edit is discarded. The proof is the render itself.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

var (
	// EVERY substitution, not only the bare ones. Measured: the bulk of the remaining Python booleans come
	// from `{{ x | default(True) }}` — already piped, so a rule keyed on bare names never sees them, and
	// 50-server.cnf alone has 54 of that shape. `| lower` appends to whatever is already there.
	//
	// NON-GREEDY, AND NOT `[^{}]*`: an expression may CONTAIN braces — `{{ (config | default({})).color |
	// default(true) }}` is the idiom the generator emits for a nested field, and a pattern forbidding inner
	// braces skipped every one of them. That left multispeech.conf, rebuildctl and restic still writing
	// True/False after a pass that reported success.
	subst   = regexp.MustCompile(`\{\{(.*?)\}\}`)
	pyBool  = regexp.MustCompile(`\b(True|False)\b`)
	tmpRoot string
)

func render(body string, sample map[string]any, name string) (string, error) {
	dest := filepath.Join(tmpRoot, name)
	if _, err := modules.NewTemplateRender().Run(context.Background(), map[string]any{
		"template": body, "dest": dest, "values": sample,
	}, false); err != nil {
		return "", err
	}
	out, err := os.ReadFile(dest)
	return string(out), err
}

func main() {
	write := len(os.Args) > 1 && os.Args[1] == "--write"
	tmpRoot, _ = os.MkdirTemp("", "fixbool")
	root := "configs/config_templates"
	dirs, _ := os.ReadDir(root)
	type edit struct {
		Template string `json:"template"`
		Expr     string `json:"expr"`
		Count    int    `json:"occurrences"`
	}
	var kept []edit
	var refused []edit
	fixed, stillBad := 0, 0

	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		bodyFile := filepath.Join(root, d.Name(), "template.j2")
		body, e1 := os.ReadFile(bodyFile)
		sraw, e2 := os.ReadFile(filepath.Join(root, d.Name(), "sample.json"))
		if e1 != nil || e2 != nil {
			continue
		}
		var sample map[string]any
		if json.Unmarshal(sraw, &sample) != nil {
			continue
		}
		before, err := render(string(body), sample, d.Name())
		if err != nil || !pyBool.MatchString(before) {
			continue // renders fine and clean, or does not render at all — not this tool's business
		}
		current := string(body)
		currentOut := before
		// Try each distinct bare expression, most specific first so `a.b` is tried before `a`.
		exprs := map[string]bool{}
		for _, m := range subst.FindAllStringSubmatch(current, -1) {
			inner := strings.TrimSpace(m[1])
			// Skip what is already lowercased, and anything that is not a value expression.
			if inner == "" || strings.HasSuffix(inner, "| lower") || strings.Contains(inner, "lower") {
				continue
			}
			exprs[inner] = true
		}
		names := make([]string, 0, len(exprs))
		for e := range exprs {
			names = append(names, e)
		}
		sort.Slice(names, func(i, j int) bool { return len(names[i]) > len(names[j]) })
		for _, expr := range names {
			pat := regexp.MustCompile(`\{\{\s*` + regexp.QuoteMeta(expr) + `\s*\}\}`)
			candidate := pat.ReplaceAllString(current, "{{ "+expr+" | lower }}")
			if candidate == current {
				continue
			}
			out, err := render(candidate, sample, d.Name())
			if err != nil {
				refused = append(refused, edit{d.Name(), expr, 0})
				continue
			}
			// THE PROOF: the ONLY difference must be Python-cased booleans becoming lowercase. Undo the
			// change on both sides and require equality — that is what "changed nothing else" means.
			normA := strings.NewReplacer("True", "true", "False", "false").Replace(currentOut)
			normB := strings.NewReplacer("True", "true", "False", "false").Replace(out)
			fewer := len(pyBool.FindAllString(out, -1)) < len(pyBool.FindAllString(currentOut, -1))
			if fewer && normA == normB {
				current, currentOut = candidate, out
				kept = append(kept, edit{d.Name(), expr, len(pat.FindAllString(string(body), -1))})
			} else if fewer {
				refused = append(refused, edit{d.Name(), expr, 0})
			}
		}
		if current != string(body) {
			fixed++
			if write {
				os.WriteFile(bodyFile, []byte(current), 0o644)
			}
		}
		if pyBool.MatchString(currentOut) {
			stillBad++
		}
	}
	fmt.Printf("%d template(s) repaired, %d edits kept, %d candidate edits refused (they changed something else)\n",
		fixed, len(kept), len(refused))
	fmt.Printf("%d template(s) still write a Python-cased boolean after this pass\n", stillBad)
	if write {
		rec, _ := json.MarshalIndent(map[string]any{"kept": kept, "refused": refused}, "", "  ")
		os.WriteFile("configs/bool_render_edits.json", rec, 0o644)
		fmt.Println("wrote the bodies and configs/bool_render_edits.json")
	} else {
		fmt.Println("(no --write — bodies untouched)")
	}
}
