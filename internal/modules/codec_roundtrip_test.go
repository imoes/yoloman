package modules

// Round-trip probe: does a CLAIMED codec actually fit a file? Run it against a fixture, not in CI:
//
//	CODEC_PROBE=/tmp/probe_in.json CODEC_PROBE_OUT=/tmp/probe_out.json \
//	  go test ./internal/modules/ -run TestCodecRoundTripProbe -v
//
// WHY THIS EXISTS. Two codec registries disagree about 236 files — configs/config_codecs.json says
// /etc/dhcpcd.conf is freeform, the registry compiled into this very package says keyvalue — and the write
// path reads one while the UI decides from the other. Choosing between them by preference ("a specific
// codec beats none", "high confidence wins") is not available: `confidence` says "high" on both sides in
// 14 of 18 sampled conflicts. So the tie needs an observation point, and the write path already implies
// one.
//
// THE INVARIANT. Observing a file and applying exactly what was observed must change nothing. So for the
// real shipped text: parse -> render-over-the-original must come back byte-identical. A codec that fails
// that would rewrite a file the moment anything is applied to it, which is precisely the damage the wrong
// codec does in production.
//
// THREE MEASURES, because byte-equality alone would be too harsh AND too lenient:
//   - keys: how many settings the codec found. 0 refutes the claim outright — the grammar does not apply.
//   - byteIdentical: the strong property above.
//   - stable: parse(render(...)) == parse(original). A codec may legitimately normalise spacing; if the
//     VALUES survive, the file is still understood, and only the diff is noisy.
//
// It lives in the package because newCodec/parse/render are unexported, and it stays a probe rather than a
// product API: nothing in the server needs to ask this question at runtime.

import (
	"encoding/json"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// A CHOPPED setting: the codec kept a brace as if it were a value. `options {` read as key "options",
// value "{" is the signature of a flat grammar cutting through a nested one.
//
// This replaced a key-NAME test (must look like an identifier), which was the wrong signal: real settings
// are named `passdb backend` in smb.conf and `php_admin_value[error_log]` in www.conf, so the name test
// refuted two files it should have accepted. The VALUE side has no such false positives — no configuration
// file assigns a bare brace to a setting on purpose.
var choppedValue = regexp.MustCompile(`^[{}();]+$`)

// STRUCTURAL REFUTATION, stronger than any round-trip. `options {` ... `};` and `<Directory /srv>` are
// NESTING, and a flat key/value grammar cannot represent nesting at all — so when it round-trips such a
// file that is a coincidence of writing nonsense back unchanged, not a fit. Counting block openers is
// intrinsic evidence about the file, independent of which codec is being judged, which is exactly what a
// tie-breaker between two codec claims must be.
var blockOpen = regexp.MustCompile(`(?m)(\{\s*$|^\s*<[A-Za-z][^>/]*>\s*$)`)

// countBlocks: block openers, counted two ways because one pattern missed a whole family. syslog-ng writes
// `options { chain_hostnames(off); flush_lines(0);` — the brace opens MID-LINE with content after it, so a
// pattern anchored at end-of-line saw exactly 1 block in a thoroughly nested file and let a flat grammar
// through with 14 settings out of 76 active lines. A line that opens more braces than it closes is an
// opener regardless of what follows it.
func countBlocks(text string) int {
	n := len(blockOpen.FindAllString(text, -1))
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, ";") {
			continue
		}
		if strings.HasSuffix(trimmed, "{") {
			continue // already counted by blockOpen
		}
		if strings.Count(trimmed, "{") > strings.Count(trimmed, "}") {
			n++
		}
	}
	return n
}

// A POSITIONAL SECTION HEADER: unindented, unbracketed, no separator, and followed by an indented line.
// haproxy.cfg is built out of these — `global`, `defaults`, `frontend main` with their settings indented
// underneath — and they are the hardest case for a flat codec BECAUSE the round-trip succeeds: parse
// flattens `maxconn 3000` out of its section, and the merge then has nowhere correct to put it back. Which
// section a setting belongs to is carried by POSITION, so flattening silently changes meaning.
//
// smb.conf, redis.conf, sshd_config, main.cf, nfs.conf all score 0 here — bracketed sections are not
// positional, so this refutes haproxy without touching the files a flat codec really does fit.
var positionalHeader = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_ .:/-]*$`)

func countPositionalSections(text string) int {
	lines := strings.Split(text, "\n")
	n := 0
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || line[:1] == " " || line[:1] == "\t" || strings.ContainsAny(trimmed[:1], "#;[<") ||
			strings.Contains(trimmed, "=") || !positionalHeader.MatchString(trimmed) {
			continue
		}
		for _, next := range lines[i+1:] {
			if strings.TrimSpace(next) == "" {
				continue
			}
			if next[:1] == " " || next[:1] == "\t" {
				n++
			}
			break
		}
	}
	return n
}

// activeLines: lines that actually say something. EL ships /etc/libvirt/libvirtd.conf as 18 kB of pure
// comment — 0 active lines — so NO codec can find a setting in it. That is not the same as "this file is
// freeform"; it is "the shipped file carries no evidence either way", and conflating the two would file a
// perfectly parsable ini under templates forever.
func activeLines(text string) int {
	n := 0
	for _, line := range strings.Split(text, "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") || strings.HasPrefix(t, ";") || strings.HasPrefix(t, "//") {
			continue
		}
		n++
	}
	return n
}

// leafKeys walks the parsed values: an ini codec returns SECTIONS at the top level, so len(values) counted
// 4 for smb.conf's 24 settings and the sane-key ratio then judged section names ("print$") instead of
// settings. Settings are the leaves; sections are structure.
// choppedLeaves counts leaves whose VALUE is nothing but structure punctuation.
func choppedLeaves(values map[string]any) int {
	n := 0
	for _, val := range values {
		if nested, ok := val.(map[string]any); ok && len(nested) > 0 {
			n += choppedLeaves(nested)
			continue
		}
		if str, ok := val.(string); ok && choppedValue.MatchString(strings.TrimSpace(str)) {
			n++
		}
	}
	return n
}

// bareLeaves counts leaves with no value at all.
func bareLeaves(values map[string]any) int {
	n := 0
	for _, val := range values {
		if nested, ok := val.(map[string]any); ok && len(nested) > 0 {
			n += bareLeaves(nested)
			continue
		}
		if str, ok := val.(string); ok && strings.TrimSpace(str) == "" {
			n++
		}
	}
	return n
}

// isStrictJSON: does encoding/json accept the text? The json codec PARSES with yaml.Unmarshal ("YAML is a
// JSON superset", config.go:849) but RENDERS with json.MarshalIndent — so on a YAML file it parses fine and
// is judged "stable", because the VALUES survive. Nothing in the round-trip can then tell json from yaml,
// and the tie was decided by map order: /etc/docker/registry/config.yml was about to be recorded as json,
// which would rewrite a YAML file as JSON on the first apply. Whether the bytes are strict JSON is the
// distinction the round-trip cannot see.
// bracketedSection: a line that is nothing but [name] — the same test iniCodec.sectionOf applies
// (config.go:584), so what is counted here is exactly what the ini codec would treat as a section.
var bracketedSection = regexp.MustCompile(`(?m)^\s*\[[^\]]+\]\s*$`)

// countSections: how many bracketed section headers the file has.
//
// This decided 28 of the 75 disagreements between the RedHat measurement and the registry, all of the form
// "registry says ini, probe says keyvalue" — /etc/UPower/UPower.conf, /etc/avahi/avahi-daemon.conf. Those ARE
// ini files, and keyvalue won only because it counted every [Section] line as one more setting, so it scored
// MORE keys and the ranking preferred it. Flattening bracketed sections loses which section a setting belongs
// to, exactly as with haproxy's positional ones, so keyvalue is refuted where they exist.
func countSections(text string) int { return len(bracketedSection.FindAllString(text, -1)) }

// shellConstruct: control flow that only exists in a program.
var shellConstruct = regexp.MustCompile(`(?m)^\s*(if\s|case\s.*\sin\s*$|for\s.*\sin\s|while\s|fi\s*$|esac\s*$|done\s*$|function\s+\w+)`)

// looksExecutable: is this a SCRIPT rather than a settings file?
//
// Measured on the harvested RedHat corpus: 286 files that a codec fitted — stably, round-tripping cleanly —
// are shell scripts. /etc/zprofile got `ini` because one of its eleven lines contains an "=" sign, and
// /etc/X11/xinit/xinitrc the same. A structure-preserving merge would not corrupt them, but the settings
// editor would list `if [ -f "$HOME/.profile" ]` as a setting with a value, which is a lie about what the
// file is.
//
// Executable content therefore refutes every codec, no matter how well the round-trip goes — the same shape
// of rule as the nesting and positional-section refusals: a property of the file that no grammar can undo.
func looksExecutable(text string) bool {
	if strings.HasPrefix(strings.TrimSpace(text), "#!") {
		return true
	}
	return shellConstruct.MatchString(text)
}

func isStrictJSON(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return false
	}
	var any_ any
	return json.Unmarshal([]byte(trimmed), &any_) == nil
}

func leafKeys(values map[string]any) []string {
	var out []string
	for key, val := range values {
		if nested, ok := val.(map[string]any); ok && len(nested) > 0 {
			out = append(out, leafKeys(nested)...)
			continue
		}
		out = append(out, key)
	}
	return out
}

type probeRequest struct {
	Path       string   `json:"path"`
	Text       string   `json:"text"`
	Candidates []string `json:"candidates"`
	Separator  string   `json:"separator,omitempty"`
	Comment    string   `json:"comment,omitempty"`
	// Separators/Comments turn one request into the cross product of the variants to try, so a file's TEXT
	// is carried once instead of once per variant. With 8843 files and 8 variants each, the one-copy-per-
	// variant form meant a 136 MB input for a 17 MB corpus.
	Separators []string `json:"separators,omitempty"`
	Comments   []string `json:"comments,omitempty"`
}

// variants expands a request into the (codec, separator, comment) triples it asks for. The separator and
// comment are part of the CLAIM, not of the file: probing haproxy.cfg with "=" invents 42 settings out of 24,
// and probing www.conf with "#" instead of ";" reads 366 commented examples as live ones.
func (r probeRequest) variants() []probeRequest {
	separators := r.Separators
	if len(separators) == 0 {
		separators = []string{r.Separator}
	}
	comments := r.Comments
	if len(comments) == 0 {
		comments = []string{r.Comment}
	}
	var out []probeRequest
	for _, codec := range r.Candidates {
		for _, separator := range separators {
			for _, comment := range comments {
				out = append(out, probeRequest{Path: r.Path, Text: r.Text, Candidates: []string{codec},
					Separator: separator, Comment: comment})
			}
		}
	}
	return out
}

type probeResult struct {
	Path          string `json:"path"`
	Codec         string `json:"codec"`
	Keys          int    `json:"keys"`
	ByteIdentical bool   `json:"byte_identical"`
	Stable        bool   `json:"stable"`
	Chopped       int    `json:"chopped"`
	Bare          int    `json:"bare"`
	Junk          int    `json:"junk"`
	Comment       string `json:"comment"`
	Blocks        int    `json:"blocks"`
	ActiveLines   int    `json:"active_lines"`
	Positional    int    `json:"positional"`
	StrictJSON    bool   `json:"strict_json"`
	Executable    bool   `json:"executable"`
	Sections      int    `json:"sections"`
	Separator     string `json:"separator"`
	Error         string `json:"error,omitempty"`
}

func probeOne(req probeRequest, format string) probeResult {
	res := probeResult{Path: req.Path, Codec: format, Separator: req.Separator,
		Comment: req.Comment, Blocks: countBlocks(req.Text), ActiveLines: activeLines(req.Text),
		Positional: countPositionalSections(req.Text), StrictJSON: isStrictJSON(req.Text),
		Executable: looksExecutable(req.Text), Sections: countSections(req.Text)}
	params := map[string]any{}
	if req.Separator != "" {
		params["separator"] = req.Separator
	}
	if req.Comment != "" {
		params["comment"] = req.Comment
	}
	codec, err := newCodec(format, params)
	if err != nil {
		res.Error = "newCodec: " + err.Error()
		return res
	}
	original := []byte(req.Text)
	values, err := codec.parse(original)
	if err != nil {
		res.Error = "parse: " + err.Error()
		return res
	}
	leaves := leafKeys(values)
	res.Keys = len(leaves)
	// PROMISCUITY GUARD. keyvalue claims 32 settings in /etc/named.conf — a braced, nested format where
	// `options {` becomes key "options", value "{". That round-trips perfectly, because writing nonsense
	// back unchanged is still unchanged. Stability alone cannot tell a fitting grammar from a greedy one.
	res.Chopped = choppedLeaves(values)
	// BARE DIRECTIVES are how the wrong separator hides. keyValueCodec.splitLine returns the whole line as
	// a key with an empty value when the separator is absent (config.go:764), so probing haproxy.cfg — a
	// space-separated file — with sep="=" yields 42 "settings" like `stats socket /var/lib/haproxy/stats`
	// instead of 24 real ones. MORE keys therefore means WORSE fit, and only counting valueless leaves
	// makes that visible.
	res.Bare = bareLeaves(values)
	// A KEY THAT STARTS WITH A COMMENT CHARACTER is a commented-out example read as a setting — the way a
	// wrong comment character hides when it only misreads a line or two (haproxy.cfg probed with ';' beat
	// the correct '#' by exactly the two '#' lines it swallowed). No real setting is named "#foo".
	for _, key := range leaves {
		if strings.HasPrefix(key, "#") || strings.HasPrefix(key, ";") || strings.HasPrefix(key, "//") {
			res.Junk++
		}
	}
	// manage="" — no managed-block marker, we are re-applying what the file already says.
	out, err := codec.render(original, values, "")
	if err != nil {
		res.Error = "render: " + err.Error()
		return res
	}
	res.ByteIdentical = string(out) == req.Text
	again, err := codec.parse(out)
	if err != nil {
		res.Error = "reparse: " + err.Error()
		return res
	}
	res.Stable = reflect.DeepEqual(values, again)
	return res
}

func TestCodecRoundTripProbe(t *testing.T) {
	in := os.Getenv("CODEC_PROBE")
	if in == "" {
		t.Skip("set CODEC_PROBE=<json> to probe claimed codecs against real file text")
	}
	raw, err := os.ReadFile(in)
	if err != nil {
		t.Fatalf("read %s: %v", in, err)
	}
	var requests []probeRequest
	if err := json.Unmarshal(raw, &requests); err != nil {
		t.Fatalf("parse %s: %v", in, err)
	}
	var results []probeResult
	for _, outer := range requests {
		for _, req := range outer.variants() {
			format := req.Candidates[0]
			r := probeOne(req, format)
			results = append(results, r)
			t.Logf("%-46s %-9s sep=%-3q cmt=%-3q exe=%-5v sec=%-3d keys=%-4d chop=%-4d bare=%-4d junk=%-4d blocks=%-3d pos=%-3d active=%-4d byte=%-5v stable=%-5v %s",
				req.Path, format, r.Separator, r.Comment, r.Executable, r.Sections, r.Keys, r.Chopped, r.Bare, r.Junk, r.Blocks, r.Positional, r.ActiveLines,
				r.ByteIdentical, r.Stable, r.Error)
		}
	}
	if out := os.Getenv("CODEC_PROBE_OUT"); out != "" {
		blob, _ := json.MarshalIndent(results, "", " ")
		if err := os.WriteFile(out, blob, 0o644); err != nil {
			t.Fatalf("write %s: %v", out, err)
		}
		t.Logf("wrote %d results to %s", len(results), out)
	}
}
