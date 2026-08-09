package modules

import (
	"context"
	"fmt"
)

// Debug mirrors ansible.builtin.debug: emit a message during a run. The
// controller (Bossman) has already substituted any {{ vars }} in `msg` before
// this reaches the host, so this module just surfaces the rendered text — the
// value shows up as the step's msg/data in the run's audit trail.
//
// Note the `var` form of ansible.builtin.debug (dump a named variable) is a
// controller-side lookup — the translator rewrites `var: x` to `msg: "{{ x }}"`
// so it arrives here already resolved; a bare `var` is echoed as-is.
type Debug struct{}

// NewDebug returns a Debug module.
func NewDebug() *Debug { return &Debug{} }

func (d *Debug) Name() string { return "debug" }

func (d *Debug) Description() string {
	return "" +
		"Emit a message during a run (ansible.builtin.debug). `msg` is the text to show; " +
		"{{ vars }} are substituted by the controller before the call, so pass the rendered " +
		"message. Always read-only, never changes host state. Returns {\"msg\": <text>}.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.debug (msg form).\n" +
		"- Salt: `test.echo` / a `debug` log statement.\n" +
		"- Chef: `log 'message'`.\n" +
		"- Puppet: `notify { 'message': }`."
}

func (d *Debug) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"msg":       map[string]any{"description": "The message to print (any type; rendered to text)."},
		"var":       stringProp("A variable name to dump — normally rewritten to msg by the translator."),
		"verbosity": map[string]any{"type": "integer", "description": "Only show at or above this -v level (accepted; always shown here).", "default": 0},
	})
}

func (d *Debug) Writes() bool { return false }

func (d *Debug) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	if v, ok := params["msg"]; ok {
		msg := fmt.Sprintf("%v", v)
		return Result{Changed: false, Msg: msg, Data: map[string]any{"msg": msg}}, nil
	}
	if v, ok := params["var"]; ok {
		s := fmt.Sprintf("%v", v)
		return Result{Changed: false, Msg: s, Data: map[string]any{"var": s}}, nil
	}
	return Result{Changed: false, Msg: "Hello world!", Data: map[string]any{"msg": "Hello world!"}}, nil
}
