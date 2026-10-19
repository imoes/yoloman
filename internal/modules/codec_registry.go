package modules

import (
	_ "embed"
	"encoding/json"
	"path/filepath"
	"regexp"
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

var digitRun = regexp.MustCompile(`[0-9]+`)

// versionless: a path with every digit run replaced by `#` — only for absolute paths that contain a digit.
func versionless(path string) string {
	if !strings.HasPrefix(path, "/") || !digitRun.MatchString(path) {
		return ""
	}
	return digitRun.ReplaceAllString(path, "#")
}

// codecByVersionless: versionless(key) → spec, for registry keys that are absolute paths with digits; a versionless
// key whose candidates disagree on the codec is left out (ambiguous — no guess).
var codecByVersionless = func() map[string]codecSpec {
	out, bad := map[string]codecSpec{}, map[string]bool{}
	for k, s := range codecRegistry {
		v := versionless(k)
		if v == "" || s.Codec == "" || s.Codec == "none" {
			continue
		}
		if prev, ok := out[v]; ok && prev != s {
			bad[v] = true
		}
		out[v] = s
	}
	for v := range bad {
		delete(out, v)
	}
	return out
}()

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
	// Full-path key first: the canonical registry (shipped in the package) keys
	// most entries by absolute path (the universe classifier's output); the
	// basename/glob keys below remain for the man-page-derived entries.
	if s, ok := codecRegistry[path]; ok && s.Codec != "" && s.Codec != "none" {
		return s.Codec, s.Separator, true
	}
	// The same file of another VERSION: the registry was measured on one release, and paths carry the version
	// (`/etc/java/java-21-openjdk/java-21-openjdk-21.0.12.0.8-1.2.el9.alma.2.x86_64/conf/…`, java-latest's
	// `java-25-openjdk` while the mirror ships 27) — every update left those files without a codec. Matched with
	// every digit run treated as one, and only when that names exactly one codec.
	if s, ok := codecByVersionless[versionless(path)]; ok {
		return s.Codec, s.Separator, true
	}
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
