// Command render-check renders a Jinja2 template through the SAME gonja path the
// agent uses at runtime (internal/modules.TemplateRender — which registers the
// Ansible filter set), so the enrich batch can gate a generated template.j2 on
// "does the Go agent actually render this?" without duplicating engine logic.
//
// Usage:
//
//	render-check -template path/to/template.j2 -values path/to/sample.json
//
// Prints the rendered output to stdout and exits 0 on success. On any parse or
// render error it prints the error to stderr and exits 1 — that non-zero exit is
// the gate. -values is optional; with none, an empty context is used (which also
// proves every variable carries a default, mirroring the Ansible empty-context gate).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

func main() {
	tmplPath := flag.String("template", "", "path to the Jinja2 template file (required)")
	valuesPath := flag.String("values", "", "path to a JSON file with the render context (optional)")
	flag.Parse()

	if *tmplPath == "" {
		fmt.Fprintln(os.Stderr, "render-check: -template is required")
		os.Exit(2)
	}

	values := map[string]any{}
	if *valuesPath != "" {
		raw, err := os.ReadFile(*valuesPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "render-check: read values: %v\n", err)
			os.Exit(2)
		}
		if err := json.Unmarshal(raw, &values); err != nil {
			fmt.Fprintf(os.Stderr, "render-check: parse values: %v\n", err)
			os.Exit(2)
		}
	}

	// Render to a throwaway dest — we only care about the rendered string and whether it errors.
	dest := filepath.Join(os.TempDir(), "render-check.out")
	res, err := modules.NewTemplateRender().Run(context.Background(), map[string]any{
		"template_path": *tmplPath,
		"dest":          dest,
		"values":        values,
	}, true) // dry_run: never write the target, this is a gate
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}
	rendered, _ := res.Data.(map[string]any)["rendered"].(string)
	fmt.Print(rendered)
}
