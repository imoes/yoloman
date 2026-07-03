package modules

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
)

// Slurp reads a file's full contents, base64-encoded, mirroring
// ansible.builtin.slurp.
type Slurp struct{}

// NewSlurp returns a Slurp module.
func NewSlurp() *Slurp { return &Slurp{} }

func (s *Slurp) Name() string { return "slurp" }

func (s *Slurp) Description() string {
	return "" +
		"Read a file's entire contents from the managed host, returned base64-encoded (so " +
		"binary files are safe to transport as JSON). Use this to inspect the current content " +
		"of a config file before deciding whether/how to change it (e.g. compare against a " +
		"desired template render), or to retrieve a small file's content for display. Not " +
		"intended for very large files — there is no streaming, the whole file is loaded into " +
		"memory and encoded at once.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.slurp. Identical semantics: {content: base64, encoding: " +
		"\"base64\"}.\n" +
		"- Chef: `::File.read(path)` in a recipe, or a `data_bag_item` for pre-managed content.\n" +
		"- Puppet: the `file()` function (reads a local module file at compile time, not a " +
		"remote agent-side file — this tool is closer to an ad-hoc `puppet apply` fact or a " +
		"custom function reading the live agent filesystem).\n" +
		"- Salt: `cp.get_file_str` or the `file.read` execution module.\n" +
		"- Terraform: `data \"local_file\"` (its `content`/`content_base64` attribute), for files " +
		"local to the machine running Terraform."
}

func (s *Slurp) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"path": stringProp(`File to read, e.g. "/etc/nginx/nginx.conf".`),
	}, "path")
}

func (s *Slurp) Writes() bool { return false }

func (s *Slurp) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	path, err := stringParam(params, "path", true, "")
	if err != nil {
		return Result{}, err
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return Result{}, fmt.Errorf("slurp: %w", err)
	}

	return Result{Changed: false, Data: map[string]any{
		"path":     path,
		"content":  base64.StdEncoding.EncodeToString(data),
		"encoding": "base64",
	}}, nil
}
