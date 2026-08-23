package starmodules

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/starmod"
)

// BuildModule builds one StarModule from its .star source + metadata sidecar,
// validating the .star through the shared starmod validator (parse+lint) so
// only contract-valid modules become executable. sidecarFormat is
// "yaml". agentWrite is the agent-wide write gate (cfg.Write). This is the one
// construction path used by both the disk loader and the delivery endpoint.
func BuildModule(starSrc, sidecar []byte, sidecarFormat string, agentWrite bool) (*StarModule, error) {
	meta, err := parseSidecar(sidecar, sidecarFormat)
	if err != nil {
		return nil, err
	}
	fqcn, _ := meta["fqcn"].(string)
	name, _ := meta["name"].(string)
	if fqcn == "" || name == "" {
		return nil, fmt.Errorf("sidecar missing required 'fqcn'/'name'")
	}
	options, _ := meta["options"].(map[string]any)

	if rep := starmod.Validate(name+".star", starSrc, starmod.Options{}); !rep.OK {
		msg := "invalid"
		if len(rep.Errors) > 0 {
			msg = rep.Errors[0].Message
		}
		return nil, fmt.Errorf("%s: .star failed validation: %s", fqcn, msg)
	}

	desc, _ := meta["short_description"].(string)
	if desc == "" {
		desc = fqcn
	}
	return &StarModule{
		fqcn:        fqcn,
		shortName:   name,
		description: desc,
		writes:      coerceBool(meta["writes"]),
		agentWrite:  agentWrite,
		options:     options,
		src:         starSrc,
	}, nil
}

// LoadDir loads every <collection>/<name>.star module (with its .yaml
// sidecar) under dir into modules.Module values. A missing directory yields
// no modules (optional, like tools.d). Individual modules that fail to load
// are returned as warnings rather than aborting the whole load.
func LoadDir(dir string, agentWrite bool) (mods []modules.Module, warnings []string, err error) {
	info, statErr := os.Stat(dir)
	if statErr != nil || !info.IsDir() {
		return nil, nil, nil
	}

	var starPaths []string
	walkErr := filepath.WalkDir(dir, func(path string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if !d.IsDir() && strings.EqualFold(filepath.Ext(path), ".star") {
			starPaths = append(starPaths, path)
		}
		return nil
	})
	if walkErr != nil {
		return nil, nil, fmt.Errorf("scanning %q: %w", dir, walkErr)
	}
	sort.Strings(starPaths)

	for _, starPath := range starPaths {
		starSrc, readErr := os.ReadFile(starPath)
		if readErr != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", starPath, readErr))
			continue
		}
		sidecar, format, sErr := readSidecar(starPath)
		if sErr != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", starPath, sErr))
			continue
		}
		m, bErr := BuildModule(starSrc, sidecar, format, agentWrite)
		if bErr != nil {
			warnings = append(warnings, bErr.Error())
			continue
		}
		mods = append(mods, m)
	}
	return mods, warnings, nil
}

// LoadFS is LoadDir's counterpart for an embedded (or any) fs.FS — used to
// bake a curated built-in module set into the agent binary via go:embed, so
// those modules are always present (no push, no on-disk modules.d needed).
// Same rules as LoadDir: every <name>.star with a sibling .yaml sidecar
// is built through the shared validator; per-module failures become warnings.
func LoadFS(fsys fs.FS, agentWrite bool) (mods []modules.Module, warnings []string, err error) {
	var starPaths []string
	walkErr := fs.WalkDir(fsys, ".", func(path string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if !d.IsDir() && strings.EqualFold(filepath.Ext(path), ".star") {
			starPaths = append(starPaths, path)
		}
		return nil
	})
	if walkErr != nil {
		return nil, nil, fmt.Errorf("scanning embedded FS: %w", walkErr)
	}
	sort.Strings(starPaths)

	for _, starPath := range starPaths {
		starSrc, readErr := fs.ReadFile(fsys, starPath)
		if readErr != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", starPath, readErr))
			continue
		}
		sidecar, format, sErr := readSidecarFS(fsys, starPath)
		if sErr != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", starPath, sErr))
			continue
		}
		m, bErr := BuildModule(starSrc, sidecar, format, agentWrite)
		if bErr != nil {
			warnings = append(warnings, bErr.Error())
			continue
		}
		mods = append(mods, m)
	}
	return mods, warnings, nil
}

// readSidecarFS is readSidecar for an fs.FS (paths use forward slashes).
func readSidecarFS(fsys fs.FS, starPath string) (data []byte, format string, err error) {
	base := strings.TrimSuffix(starPath, filepath.Ext(starPath))
	for _, ext := range []string{".yaml", ".yml"} {
		if b, e := fs.ReadFile(fsys, base+ext); e == nil {
			return b, "yaml", nil
		}
	}
	return nil, "", fmt.Errorf("no metadata sidecar (.yaml) next to %s", filepath.Base(starPath))
}

// readSidecar finds a module's metadata sidecar next to its .star.
//
// YAML ONLY. NestedText was the other authoring format and is gone (docs/nestedtext-removal.md); this loader
// PREFERRED .nt over .yaml, so any leftover .nt would have won over the file Bossman actually writes.
// Measured before removing: 0 `.nt` files against 1431 `.yaml` sidecars in the check library.
func readSidecar(starPath string) (data []byte, format string, err error) {
	base := strings.TrimSuffix(starPath, filepath.Ext(starPath))
	for _, ext := range []string{".yaml", ".yml"} {
		if b, e := os.ReadFile(base + ext); e == nil {
			return b, "yaml", nil
		}
	}
	return nil, "", fmt.Errorf("no metadata sidecar (.yaml) next to %s", filepath.Base(starPath))
}

// parseSidecar decodes a metadata sidecar into a map. YAML is the only format; `format` is still accepted so
// a delivery from an older Bossman that still says "nt" is REFUSED with a clear message rather than silently
// parsed as YAML and half-understood.
func parseSidecar(data []byte, format string) (map[string]any, error) {
	var meta map[string]any
	switch format {
	case "yaml", "yml", "":
		if err := yaml.Unmarshal(data, &meta); err != nil {
			return nil, fmt.Errorf("parsing YAML sidecar: %w", err)
		}
	case "nt":
		return nil, fmt.Errorf("NestedText sidecars are no longer supported — this delivery came from a " +
			"Bossman that predates the removal; upgrade it and re-deliver")
	default:
		return nil, fmt.Errorf("unknown sidecar format %q", format)
	}
	if meta == nil {
		return nil, fmt.Errorf("empty sidecar")
	}
	return meta, nil
}
