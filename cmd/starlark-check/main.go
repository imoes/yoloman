// starlark-check validates a Starlark module against the module contract
// v1 (see internal/starmod and docs/plan.md Block G7/G8). It prints a
// JSON Report to stdout and exits 0 when the hard gate (parse + contract
// lint) passes, 1 otherwise; -strict additionally requires the stub run
// to pass. Bossman's validate_module/submit_module MCP tools shell out to
// this binary.
//
// Usage:
//
//	starlark-check [-params '{"name": "nginx"}'] [-strict] module.star
//	cat module.star | starlark-check -
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/mutkluge/agentic-mcp/internal/starmod"
)

func main() {
	params := flag.String("params", "", "JSON object with sample params for the stub run")
	strict := flag.Bool("strict", false, "also require the stub execution to pass")
	flag.Parse()

	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: starlark-check [-params JSON] [-strict] <module.star | ->")
		os.Exit(2)
	}

	name := flag.Arg(0)
	var src []byte
	var err error
	if name == "-" {
		name = "stdin.star"
		src, err = io.ReadAll(os.Stdin)
	} else {
		src, err = os.ReadFile(name)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "starlark-check: %v\n", err)
		os.Exit(2)
	}

	rep := starmod.Validate(name, src, starmod.Options{ParamsJSON: []byte(*params)})

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(rep); err != nil {
		fmt.Fprintf(os.Stderr, "starlark-check: %v\n", err)
		os.Exit(2)
	}

	if !rep.OK || (*strict && !rep.StubOK) {
		os.Exit(1)
	}
}
