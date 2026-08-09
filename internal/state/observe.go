package state

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"sort"
	"time"
	"unicode/utf8"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// ObservedResource is one config file as it exists on disk right now: either
// structured `values` (a codec parsed it) or, for a format with no clean codec
// yet, a content `sha256`+`size` reference (drift-trackable, Class-B template
// pending).
type ObservedResource struct {
	Type      string         `json:"type"`
	Path      string         `json:"path"`
	Format    string         `json:"format"`
	Separator string         `json:"separator,omitempty"`
	Values    map[string]any `json:"values,omitempty"`
	SHA256    string         `json:"sha256,omitempty"`
	Size      int64          `json:"size,omitempty"`
	// Raw is the file's verbatim text (comments + order intact), included for
	// textual files up to maxRawBytes so the UI can show + edit the real file,
	// not a lossy re-serialization of Values. Empty for binary/oversized files.
	Raw   string `json:"raw,omitempty"`
	Error string `json:"error,omitempty"`
}

// maxRawBytes caps the verbatim file text carried in observed state — big
// enough for any real /etc config, small enough to keep the document sane.
const maxRawBytes = 256 * 1024

// ObservedState is the whole server rendered as one JSON document: which
// services are enabled, and the current content of every config file they
// reference. This is the "GET the server as JSON" side of the model — the
// input a desired-state PUT/plan diffs against.
type ObservedState struct {
	GeneratedAt time.Time          `json:"generated_at"`
	Services    any                `json:"services"`
	Config      []ObservedResource `json:"config"`
}

// Observe builds the observed state: it runs config_discover to find the config
// files this host's services actually use, then reads each — structured via the
// config codec when the format is known, otherwise as a hash reference. `now`
// is injectable for tests.
func Observe(ctx context.Context, reg *modules.Registry, now time.Time) (ObservedState, error) {
	out := ObservedState{GeneratedAt: now}

	disc, ok := reg.Get("config_discover")
	if !ok {
		return out, fmt.Errorf("config_discover module not registered")
	}
	res, err := disc.Run(ctx, map[string]any{}, true)
	if err != nil {
		return out, fmt.Errorf("discover: %w", err)
	}
	data, _ := res.Data.(map[string]any)
	if data == nil {
		return out, nil
	}
	out.Services = data["services"]

	files, _ := data["config_files"].([]map[string]any)
	// Data may round-trip as []any depending on the caller; normalize.
	if files == nil {
		if raw, ok := data["config_files"].([]any); ok {
			for _, e := range raw {
				if m, ok := e.(map[string]any); ok {
					files = append(files, m)
				}
			}
		}
	}

	cfgMod, hasCfg := reg.Get("config")
	for _, f := range files {
		path, _ := f["path"].(string)
		format, _ := f["format"].(string)
		sep, _ := f["separator"].(string)
		or := ObservedResource{Type: "config", Path: path, Format: format, Separator: sep}
		// Read the file once: its verbatim text (for display/edit) + its hash.
		raw, readErr := os.ReadFile(path)
		if readErr == nil {
			or.Size = int64(len(raw))
			if len(raw) <= maxRawBytes && utf8.Valid(raw) {
				or.Raw = string(raw)
			}
		}
		if format != "" && hasCfg {
			p := map[string]any{"path": path, "format": format}
			if sep != "" {
				p["separator"] = sep
			}
			r, e := cfgMod.Run(ctx, p, true)
			if e != nil {
				or.Error = e.Error()
			} else if m, ok := r.Data.(map[string]any); ok {
				if c, ok := m["config"].(map[string]any); ok {
					or.Values = c
				}
			}
		} else if readErr == nil {
			// No codec: track by content hash so drift is still detectable.
			sum := sha256.Sum256(raw)
			or.SHA256 = fmt.Sprintf("%x", sum[:])
		} else {
			or.Error = readErr.Error()
		}
		out.Config = append(out.Config, or)
	}
	sort.Slice(out.Config, func(i, j int) bool { return out.Config[i].Path < out.Config[j].Path })
	return out, nil
}
