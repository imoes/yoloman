package modules

import (
	"context"
	"fmt"
	"os"
	"syscall"
)

// Stat reports metadata about a filesystem path, mirroring
// ansible.builtin.stat's "exists" + attribute fields.
type Stat struct{}

// NewStat returns a Stat module.
func NewStat() *Stat { return &Stat{} }

func (s *Stat) Name() string { return "stat" }

func (s *Stat) Description() string {
	return "" +
		"Inspect a single filesystem path without reading its content: whether it exists, its " +
		"size in bytes, permission mode (octal string, e.g. \"0644\"), owning uid/gid, whether " +
		"it is a regular file, directory, or symlink, and its modification time (Unix seconds). " +
		"Returns {\"exists\": false, \"path\": ...} if nothing is at that path — this is not an " +
		"error, callers should check the \"exists\" field. Use this before a file/copy/template " +
		"operation to check whether a change is actually needed (idempotency check), or to " +
		"verify a prior write took effect.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.stat. Same field semantics (exists, size, mode, isdir, " +
		"isreg, issymlink, uid, gid, mtime).\n" +
		"- Chef: the implicit current-resource lookup a `file`/`directory`/`template` resource " +
		"performs internally (File.stat), or explicit Ruby `::File.exist?`/`::File.stat` in a " +
		"recipe/library.\n" +
		"- Puppet: no dedicated introspection type; closest is querying the `file` resource's " +
		"current state via `puppet resource file <path>`, or a custom fact.\n" +
		"- Salt: the `file.stats` execution module.\n" +
		"- Terraform: a `data \"local_file\"` data source (for the machine running Terraform) or " +
		"a `null_resource` with a `remote-exec`/`local-exec` provisioner running `stat` for a " +
		"managed host."
}

func (s *Stat) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"path": stringProp(`Filesystem path to inspect, e.g. "/etc/nginx/nginx.conf" or "/opt/app".`),
	}, "path")
}

func (s *Stat) Writes() bool { return false }

func (s *Stat) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	path, err := stringParam(params, "path", true, "")
	if err != nil {
		return Result{}, err
	}

	fi, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return Result{Changed: false, Data: map[string]any{"exists": false, "path": path}}, nil
	}
	if err != nil {
		return Result{}, fmt.Errorf("stat: %w", err)
	}

	data := map[string]any{
		"exists":    true,
		"path":      path,
		"size":      fi.Size(),
		"mode":      fmt.Sprintf("%#o", fi.Mode().Perm()),
		"isdir":     fi.IsDir(),
		"isreg":     fi.Mode().IsRegular(),
		"issymlink": fi.Mode()&os.ModeSymlink != 0,
		"mtime":     fi.ModTime().Unix(),
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		data["uid"] = st.Uid
		data["gid"] = st.Gid
	}

	return Result{Changed: false, Data: data}, nil
}
