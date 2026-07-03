package modules

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// Find locates files/directories under one or more paths, optionally
// filtering by glob pattern, entry type, and recursion — mirroring
// ansible.builtin.find's paths/patterns/recurse/file_type parameters.
type Find struct{}

// NewFind returns a Find module.
func NewFind() *Find { return &Find{} }

func (f *Find) Name() string { return "find" }

func (f *Find) Description() string {
	return "" +
		"Search one or more directories for entries matching a glob pattern and/or type, " +
		"optionally recursing into subdirectories. Returns a list of {path, isdir, size} for " +
		"every match. Use this to discover what already exists on disk before deciding what " +
		"file/copy/template operations are needed (e.g. \"find all *.conf files under " +
		"/etc/nginx/conf.d\"), or to answer an inventory question about the filesystem.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.find. Same paths/pattern/recurse/file_type parameter names " +
		"and meaning (a subset of Ansible's fuller option set).\n" +
		"- Chef: `Dir.glob(pattern)` in recipe/library Ruby code.\n" +
		"- Puppet: the `fileset()` built-in function, or a custom fact enumerating files.\n" +
		"- Salt: the `file.find` execution module.\n" +
		"- Terraform: the `fileset()` built-in configuration function (evaluated against the " +
		"machine running `terraform plan`, not a remote managed host)."
}

func (f *Find) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"paths":     stringArrayProp(`One or more directories to search, e.g. ["/etc/nginx/conf.d"].`),
		"pattern":   stringProp(`Optional glob pattern matched against each entry's base name, e.g. "*.conf". Empty means match everything.`),
		"recurse":   boolProp("Whether to descend into subdirectories. Default false (only direct children of each path).", false),
		"file_type": stringEnumProp(`Restrict matches by entry type. Default "any".`, "any", "file", "directory"),
	}, "paths")
}

func (f *Find) Writes() bool { return false }

func (f *Find) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	paths, err := stringSliceParam(params, "paths", true)
	if err != nil {
		return Result{}, err
	}
	pattern, err := stringParam(params, "pattern", false, "")
	if err != nil {
		return Result{}, err
	}
	recurse, err := boolParam(params, "recurse", false)
	if err != nil {
		return Result{}, err
	}
	fileType, err := stringParam(params, "file_type", false, "any")
	if err != nil {
		return Result{}, err
	}
	if fileType != "any" && fileType != "file" && fileType != "directory" {
		return Result{}, fmt.Errorf("file_type: must be one of any|file|directory, got %q", fileType)
	}

	var matches []map[string]any
	match := func(path string, d fs.DirEntry) error {
		if pattern != "" {
			ok, err := filepath.Match(pattern, d.Name())
			if err != nil {
				return fmt.Errorf("pattern: %w", err)
			}
			if !ok {
				return nil
			}
		}
		isDir := d.IsDir()
		if fileType == "file" && isDir {
			return nil
		}
		if fileType == "directory" && !isDir {
			return nil
		}
		var size int64
		if info, err := d.Info(); err == nil {
			size = info.Size()
		}
		matches = append(matches, map[string]any{
			"path":  path,
			"isdir": isDir,
			"size":  size,
		})
		return nil
	}

	for _, root := range paths {
		if recurse {
			err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
				if err != nil {
					return nil // skip unreadable entries rather than aborting the whole search
				}
				if path == root {
					return nil
				}
				return match(path, d)
			})
			if err != nil {
				return Result{}, err
			}
			continue
		}

		entries, err := os.ReadDir(root)
		if err != nil {
			return Result{}, fmt.Errorf("find: reading %q: %w", root, err)
		}
		for _, e := range entries {
			if err := match(filepath.Join(root, e.Name()), e); err != nil {
				return Result{}, err
			}
		}
	}

	if matches == nil {
		matches = []map[string]any{}
	}
	return Result{Changed: false, Data: matches}, nil
}
