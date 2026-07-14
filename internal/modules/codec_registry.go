package modules

import (
	_ "embed"
	"encoding/json"
	"path/filepath"
	"strings"
)

// config_codecs.json is the man-page-derived codec registry produced by
// scripts/classify_config_codecs.py: for each documented config file (keyed by
// basename, or a "/etc/default/*"-style dir glob), which codec + separator the
// config module should use. Embedded so the knowledge ships with the agent and
// works standalone. Extra fields (packages/paths/confidence/notes) are ignored.
//
//go:embed config_codecs.json
var codecRegistryJSON []byte

type codecSpec struct {
	Codec     string `json:"codec"`
	Separator string `json:"separator"`
	Comment   string `json:"comment"`
}

var codecRegistry = loadCodecRegistry()

func loadCodecRegistry() map[string]codecSpec {
	m := map[string]codecSpec{}
	_ = json.Unmarshal(codecRegistryJSON, &m)
	return m
}

// lookupCodec consults the registry for a config path: dir globs first
// (/etc/default/*), then the file's basename, then — for a conf.d/*.d drop-in
// fragment — its parent service's entry (same resolution as the classifier).
// Returns (format, separator, true) when found with a usable codec.
func lookupCodec(path string) (string, string, bool) {
	if s, ok := codecRegistry[filepath.Dir(path)+"/*"]; ok && s.Codec != "" && s.Codec != "none" {
		return s.Codec, s.Separator, true
	}
	base := filepath.Base(path)
	if s, ok := codecRegistry[base]; ok && s.Codec != "" && s.Codec != "none" {
		return s.Codec, s.Separator, true
	}
	if svc := dropinService(path); svc != "" {
		for _, k := range []string{svc, svc + ".conf", svc + ".d"} {
			if s, ok := codecRegistry[k]; ok && s.Codec != "" && s.Codec != "none" {
				return s.Codec, s.Separator, true
			}
		}
	}
	return "", "", false
}

// dropinService derives the parent service of a conf.d / *.d drop-in fragment
// (mirrors classify_config_codecs.py's dropin_service): /etc/nginx/conf.d/x ->
// nginx, /etc/sysctl.d/x -> sysctl, /etc/sudoers.d/x -> sudoers.
func dropinService(path string) string {
	parts := strings.Split(path, "/")
	for i, p := range parts {
		if p == "conf.d" && i >= 1 {
			return parts[i-1]
		}
		if strings.HasSuffix(p, ".d") && p != "conf.d" {
			return strings.TrimSuffix(p, ".d")
		}
	}
	return ""
}
