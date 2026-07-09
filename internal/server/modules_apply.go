package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutkluge/agentic-mcp/internal/starmodules"
)

// moduleDelivery is one pushed Starlark module: its fqcn, the .star source,
// the metadata sidecar (+ its format), and a sha256 of the .star for
// integrity.
type moduleDelivery struct {
	FQCN          string `json:"fqcn"`
	Star          string `json:"star"`
	Sidecar       string `json:"sidecar"`
	SidecarFormat string `json:"sidecar_format"` // "nt" | "yaml"
	SHA256        string `json:"sha256"`
}

type modulesApplyRequest struct {
	Modules []moduleDelivery `json:"modules"`
}

type moduleApplyResult struct {
	FQCN  string `json:"fqcn"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// handleModulesApply receives Bossman-pushed Starlark modules (Block G3),
// validates each (sha256 + parse/lint via starmodules.BuildModule), persists
// it under ModulesDir so it survives a restart, and live-registers it in the
// running module registry (REST dispatch reads the registry live; MCP tools
// appear after the next restart). Gated on cfg.Write — delivering capability
// to an agent is a management mutation, so a read-only agent declines it.
func handleModulesApply(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("module delivery is disabled (write=false)"))
		return
	}
	if cfg.ModReg == nil || cfg.ModulesDir == "" {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("module registry/dir not configured"))
		return
	}

	var req modulesApplyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("decoding request: %w", err))
		return
	}

	results := make([]moduleApplyResult, 0, len(req.Modules))
	applied := 0
	for _, md := range req.Modules {
		if err := applyOneModule(cfg, md); err != nil {
			results = append(results, moduleApplyResult{FQCN: md.FQCN, OK: false, Error: err.Error()})
			continue
		}
		results = append(results, moduleApplyResult{FQCN: md.FQCN, OK: true})
		applied++
	}
	writeJSON(w, http.StatusOK, map[string]any{"applied": applied, "results": results})
}

func applyOneModule(cfg RESTConfig, md moduleDelivery) error {
	if md.SHA256 != "" {
		sum := sha256.Sum256([]byte(md.Star))
		if hex.EncodeToString(sum[:]) != md.SHA256 {
			return fmt.Errorf("sha256 mismatch")
		}
	}
	// Validate + build (parse/lint gate) before touching disk.
	m, err := starmodules.BuildModule([]byte(md.Star), []byte(md.Sidecar), md.SidecarFormat, cfg.Write)
	if err != nil {
		return err
	}
	if err := persistModule(cfg.ModulesDir, md); err != nil {
		return err
	}
	cfg.ModReg.Set(m)
	return nil
}

// persistModule writes the .star + sidecar under <ModulesDir>/<collection>/,
// so a restart's loadComponents reloads it.
func persistModule(modulesDir string, md moduleDelivery) error {
	collection, _, name := lastCut(md.FQCN, ".")
	if collection == "" || name == "" {
		return fmt.Errorf("bad fqcn %q", md.FQCN)
	}
	dir := filepath.Join(modulesDir, collection)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %q: %w", dir, err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".star"), []byte(md.Star), 0o644); err != nil {
		return fmt.Errorf("writing .star: %w", err)
	}
	ext := ".yaml"
	if md.SidecarFormat == "nt" {
		ext = ".nt"
	}
	if err := os.WriteFile(filepath.Join(dir, name+ext), []byte(md.Sidecar), 0o644); err != nil {
		return fmt.Errorf("writing sidecar: %w", err)
	}
	return nil
}

// lastCut splits s on the last occurrence of sep (fqcn → collection, name).
func lastCut(s, sep string) (before, s2, after string) {
	i := strings.LastIndex(s, sep)
	if i < 0 {
		return "", "", ""
	}
	return s[:i], sep, s[i+len(sep):]
}
