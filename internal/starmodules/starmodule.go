package starmodules

import (
	"context"
	"fmt"

	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/starmod"
)

// StarModule adapts one translated .star module + its argspec sidecar to the
// modules.Module interface, so it registers in the same registry and is
// dispatched by the same REST/MCP paths as native Go modules. Run drives the
// shared starmod runtime with a RealCaps carrying the write gate + check_mode.
type StarModule struct {
	fqcn        string // registry name, e.g. community.crypto.openssl_privatekey
	shortName   string // bare module name, for the .star filename label
	description string
	writes      bool           // from the sidecar (writes:true = mutating)
	agentWrite  bool           // the agent-wide write gate (cfg.Write)
	options     map[string]any // the argspec (option name -> spec)
	src         []byte         // the .star source
}

// Ensure StarModule satisfies the interface.
var _ modules.Module = (*StarModule)(nil)

func (m *StarModule) Name() string        { return m.fqcn }
func (m *StarModule) Description() string { return m.description }
func (m *StarModule) Writes() bool        { return m.writes }

// InputSchema renders the sidecar argspec as a JSON Schema (draft 2020-12),
// mirroring native modules' typed contract.
func (m *StarModule) InputSchema() map[string]any {
	props := map[string]any{}
	var required []string
	for name, raw := range m.options {
		spec, _ := raw.(map[string]any)
		p := map[string]any{"type": jsonType(spec["type"])}
		if d, ok := spec["description"]; ok {
			p["description"] = d
		}
		if choices, ok := spec["choices"]; ok {
			p["enum"] = choices
		}
		props[name] = p
		if coerceBool(spec["required"]) {
			required = append(required, name)
		}
	}
	schema := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

// Run executes the module. The dispatch layer already applies the write gate
// (a mutating module is 403/hidden when cfg.Write is false); RealCaps
// re-enforces it in-ctx (defense-in-depth) using agentWrite + writes.
func (m *StarModule) Run(_ context.Context, params map[string]any, dryRun bool) (modules.Result, error) {
	for name, raw := range m.options {
		spec, _ := raw.(map[string]any)
		if coerceBool(spec["required"]) {
			if _, ok := params[name]; !ok {
				return modules.Result{}, fmt.Errorf("%s: missing required parameter %q", m.fqcn, name)
			}
		}
	}
	// REST and MCP both dispatch with dryRun=false, so a caller asking for a
	// dry run does it via a params["dry_run"] flag (mirrors the native modules,
	// e.g. systemd/command). OR it into check_mode here.
	checkMode := dryRun || coerceBool(params["dry_run"])
	caps := NewRealCaps(checkMode, m.agentWrite, m.writes)
	res, err := starmod.Execute(m.shortName+".star", m.src, params, caps, starmod.Options{})
	if err != nil {
		return modules.Result{}, fmt.Errorf("%s: %w", m.fqcn, err)
	}
	// ALWAYS reported, including attempts=0. Omitting it there made "this module
	// read nothing at all" indistinguishable from "an agent too old to say", and
	// the caller has to treat the latter as unknown — so mkevents, which makes no
	// ctx call whatsoever and still reports OK, kept being discovered on every host.
	// With the field always present, its absence means exactly one thing.
	out := modules.Result{Changed: res.Changed, Msg: res.Msg, Data: res.Data}
	out.DataSource = map[string]int{"attempts": res.Evidence.Attempts, "produced": res.Evidence.Produced}
	return out, nil
}

// jsonType maps an Ansible argspec type to a JSON Schema type.
func jsonType(t any) string {
	s, _ := t.(string)
	switch s {
	case "int":
		return "integer"
	case "bool":
		return "boolean"
	case "float":
		return "number"
	case "list":
		return "array"
	case "dict", "json":
		return "object"
	default: // str, path, raw, "", anything else
		return "string"
	}
}

// coerceBool reads a metadata boolean that may be a real bool (YAML) or a
// string (NestedText is all-strings).
func coerceBool(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case string:
		switch x {
		case "true", "yes", "on", "1", "True":
			return true
		}
	}
	return false
}
