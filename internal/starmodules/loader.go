package starmodules

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/danielledeleo/nestedtext"
	"gopkg.in/yaml.v3"

	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/starmod"
)

// BuildModule builds one StarModule from its .star source + metadata sidecar,
// validating the .star through the shared starmod validator (parse+lint) so
// only contract-valid modules become executable. sidecarFormat is "nt" or
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

// LoadDir loads every <collection>/<name>.star module (with its .nt or .yaml
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

// readSidecar finds a module's metadata sidecar next to its .star, preferring
// NestedText (.nt) over YAML (.yaml) — matching Bossman's metadata_path.
func readSidecar(starPath string) (data []byte, format string, err error) {
	base := strings.TrimSuffix(starPath, filepath.Ext(starPath))
	for _, cand := range []struct{ ext, format string }{{".nt", "nt"}, {".yaml", "yaml"}, {".yml", "yaml"}} {
		if b, e := os.ReadFile(base + cand.ext); e == nil {
			return b, cand.format, nil
		}
	}
	return nil, "", fmt.Errorf("no metadata sidecar (.nt/.yaml) next to %s", filepath.Base(starPath))
}

// parseSidecar decodes a metadata sidecar (nt or yaml) into a map.
func parseSidecar(data []byte, format string) (map[string]any, error) {
	var meta map[string]any
	switch format {
	case "nt":
		if err := nestedtext.Unmarshal(data, &meta); err != nil {
			return nil, fmt.Errorf("parsing NestedText sidecar: %w", err)
		}
	case "yaml", "yml", "":
		if err := yaml.Unmarshal(data, &meta); err != nil {
			return nil, fmt.Errorf("parsing YAML sidecar: %w", err)
		}
	default:
		return nil, fmt.Errorf("unknown sidecar format %q", format)
	}
	if meta == nil {
		return nil, fmt.Errorf("empty sidecar")
	}
	return meta, nil
}
