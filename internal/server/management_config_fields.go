package server

// The three config surfaces the host Configuration tab needs, served STANDALONE.
//
// Bossman answers these from Python (bossman/bossman/api/config_fields.py, services/template_index.py). An
// agent with no Bossman has to answer them itself, and the tempting way — porting the logic to Go — would put
// one rule in two languages. That is precisely how the two halves of this system came to disagree about
// codecs: the same question resolved by two implementations, one of which was wrong.
//
// So NO RULE IS REIMPLEMENTED HERE. bossman/scripts/export_agent_config_projection.py runs the real logic
// once and records its answer; the package ships that record; this file looks the answer up. What is left in
// Go is only lookup and assembly:
//
//	config_template_index.json  the /config-templates/index reply verbatim, per family (null = same as base)
//	template_withheld.json      per template, the fields its body never places
//	config_generated.json       per path, the file's own "do not edit" sentence
//	config_codecs.json          the codec + its by_family branch
//	config_directives.json      the per-key catalog
//
// The one thing this file DOES decide is the family, because only the host knows which it is — osFamily()
// reads its own /etc/os-release. Bossman derives the same answer from the host's facts.

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// asSlice returns v as a JSON array, or nil. A recorded artifact may simply not mention a template, and an
// absent entry is not an empty one — the callers below distinguish "nothing withheld" from "not recorded"
// only by length, which is the same answer here.
func asSlice(v any) []any {
	if s, ok := v.([]any); ok {
		return s
	}
	return nil
}

// RegisterConfigFieldRoutes mounts the field-spec surface. Split from RegisterManagementRoutes so the
// standalone catch-up is one file rather than three more lines in a 40-route list.
func RegisterConfigFieldRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/config-templates/index", func(w http.ResponseWriter, r *http.Request) {
		mgmtConfigTemplateIndex(w, r)
	})
	mux.HandleFunc("GET /api/v1/config-generated", func(w http.ResponseWriter, r *http.Request) {
		mgmtConfigGenerated(w, r)
	})
	mux.HandleFunc("GET /api/v1/config-fields", func(w http.ResponseWriter, r *http.Request) {
		mgmtConfigFields(w, r)
	})
}

// templateIndexFor returns the recorded index for family: the family's own answer when it has one, else base.
// A null family entry means "identical to base" — measured, debian and suse are, and only redhat differs
// (8 paths). Storing null instead of a third copy means there is one answer to keep true, not three.
// NOTE on asMap: it returns an EMPTY map for anything that is not a JSON object, never nil. So "did the
// lookup find something" has to be asked with len() or a two-value index — `!= nil` is always true and, when
// I wrote it that way, every family resolved to an empty index and every path came back freeform.
func templateIndexFor(family string) map[string]any {
	v, ok := readBundledJSON("config_template_index.json")
	root := asMap(v)
	if !ok || len(root) == 0 {
		return nil
	}
	// A family entry that is present and non-null is that family's own answer; null means "same as base",
	// which is how debian and suse are stored.
	if own := asMap(asMap(root["families"])[family]); len(own) > 0 {
		return own
	}
	if base := asMap(root["base"]); len(base) > 0 {
		return base
	}
	return nil
}

func mgmtConfigTemplateIndex(w http.ResponseWriter, r *http.Request) {
	// A caller may name the family (the OU/authoring view has no host); this host's own is the default.
	family := r.URL.Query().Get("family")
	if family == "" {
		family = osFamily()
	}
	index := templateIndexFor(family)
	if len(index) == 0 {
		// No index means no Configure button, which is the safe direction: the alternative is resolving by
		// basename again, and that once bound /etc/ansible/hosts to the template that renders /etc/hosts.
		writeJSON(w, http.StatusOK, map[string]any{
			"paths": map[string]any{}, "snapins": map[string]any{}, "conflicts": []any{},
			"family": family, "available": false,
			"reason": "config_template_index.json is not installed on this host; regenerate it with " +
				"bossman/scripts/export_agent_config_projection.py --write and reinstall the package",
		})
		return
	}
	out := map[string]any{"family": family, "available": true}
	for k, v := range index {
		out[k] = v
	}
	writeJSON(w, http.StatusOK, out)
}

func mgmtConfigGenerated(w http.ResponseWriter, _ *http.Request) {
	v, ok := readBundledJSON("config_generated.json")
	files := asMap(v)
	if !ok || len(files) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"files": map[string]any{}, "count": 0})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"files": files, "count": len(files)})
}

// fieldFromDirective converts one directive spec into the FieldDef the editor renders. The two shapes differ
// only cosmetically (`values` vs `enum`, `int` vs `number`, a `{value: X}` default) and this is the same
// normalisation _field_from_directive does — kept here because it is a rename, not a rule: there is nothing
// to measure and nothing that can disagree about a fact.
func fieldFromDirective(spec map[string]any) map[string]any {
	out := map[string]any{}
	typ, _ := spec["type"].(string)
	switch typ {
	case "number":
		out["type"] = "int"
	case "":
		out["type"] = "string"
	default:
		out["type"] = typ
	}
	if vals, ok := spec["values"].([]any); ok && len(vals) > 0 {
		out["enum"] = vals
	} else if vals, ok := spec["enum"].([]any); ok && len(vals) > 0 {
		out["enum"] = vals
	}
	def := spec["default"]
	if dm, ok := def.(map[string]any); ok {
		if inner, has := dm["value"]; has {
			def = inner
		}
	}
	if def != nil {
		out["default"] = def
	}
	for _, k := range []string{"description", "min", "max", "widget", "unit", "description_source"} {
		if v, ok := spec[k]; ok && v != nil {
			out[k] = v
		}
	}
	return out
}

// catalogForPath merges the directive catalog entries recorded for path, in the recorded order.
//
// The catalog is keyed inconsistently — basenames, full paths, parent directories, some with a trailing
// slash — and catalog_for_path merges SIX candidates so the more specific key wins. I first wrote that chain
// here as two candidates, and the differential against Bossman (scripts/diff-agent-config-fields.sh) caught
// it on the very first run: /etc/xdg/khtmlrc lost 19 fields, settings an operator could reach through Bossman
// and not on the host. So the chain is not repeated in Go — config_directive_keys.json records which keys
// each path resolves to, and this replays them.
func catalogForPath(path string, catalog map[string]any) map[string]any {
	keysRaw, _ := readBundledJSON("config_directive_keys.json")
	keys := asSlice(asMap(keysRaw)[path])
	if len(keys) == 0 {
		// No recorded chain: fall back to the two keys that need no rule to justify — the path itself and its
		// basename. This is the honest floor for a catalog written after the projection was exported (the
		// mining runs add paths daily), and it is a subset of the chain, never a different answer.
		keys = []any{filepath.Base(path), path}
	}
	merged := map[string]any{}
	for _, k := range keys {
		name, ok := k.(string)
		if !ok {
			continue
		}
		for key, v := range asMap(catalog[name]) {
			if asMap(v) != nil {
				merged[key] = v
			}
		}
	}
	return merged
}

// provenanceOf reports whether this codec was decided by round-tripping the bytes the package really ships,
// or merely asserted. A field editor built on an unmeasured grammar can corrupt the file it writes, so the
// answer travels with the fields rather than being implied by their presence.
//
// NOT-MEASURED HAS TWO SHAPES. "Nobody has looked yet" is a task; "probed, and the file could not decide" is
// a dead end for this method — the shipped /etc/security/limits.conf and /etc/sysctl.conf are entirely
// comments, so their bytes cannot confirm or refute a grammar. The probe record names which it is.
func provenanceOf(codec map[string]any, probe map[string]any) map[string]any {
	source, _ := codec["source"].(string)
	if source == "" {
		source = "unrecorded"
	}
	measured := source == "probe" || source == "extension"
	confidence, _ := codec["confidence"].(string)
	if confidence == "" {
		confidence = "unknown"
	}
	note, _ := codec["notes"].(string)
	if note == "" {
		if measured {
			note = "the grammar was decided by round-tripping a real file from the package"
		} else {
			note = "this grammar has never been checked against a real file"
		}
	}
	out := map[string]any{"source": source, "measured": measured, "confidence": confidence}
	if !measured && probe["verdict"] == "no-evidence" {
		active := 0
		if n, ok := probe["active_lines"].(float64); ok {
			active = int(n)
		}
		note = fmt.Sprintf("probed against the file the package ships: it contains no active setting "+
			"(%d lines), so the bytes cannot confirm or refute this grammar", active)
	}
	out["note"] = note
	if len(probe) > 0 {
		out["probe"] = probe
	} else {
		out["probe"] = nil
	}
	return out
}

func mgmtConfigFields(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("path")
	if path == "" {
		writeError(w, http.StatusBadRequest, fmt.Errorf("query parameter path is required"))
		return
	}
	family := r.URL.Query().Get("family")
	if family == "" {
		family = osFamily()
	}

	codecsRaw, _ := readBundledJSON("config_codecs.json")
	codec := asMap(asMap(codecsRaw)[path])
	// A PER-FAMILY MEASUREMENT WINS. Of 1605 paths present in both corpora, 33 disagree —
	// /etc/logrotate.conf is flat on Debian and nested on EL. One record per path is then wrong for one
	// family, so the registry keeps both and this host asks for its own.
	if branch := asMap(asMap(codec["by_family"])[family]); branch["codec"] != nil {
		merged := map[string]any{}
		for k, v := range codec {
			merged[k] = v
		}
		for k, v := range branch {
			merged[k] = v
		}
		codec = merged
	}
	codecKind, _ := codec["codec"].(string)

	// The file's OWN statement about itself, carried on every branch below. Not a write state and not a
	// refusal: munin.conf is parsable, editable, and still asks not to be edited. An editor that stays
	// silent lets an operator apply a value the next generator run drops, and the drift then has no cause.
	generatedRaw, _ := readBundledJSON("config_generated.json")
	advisory := asMap(asMap(generatedRaw)[path])

	out := map[string]any{"path": path}
	add := func(k string, v any) { out[k] = v }
	if len(advisory) > 0 {
		add("machine_written", advisory)
	}
	// DOES THE FILE EXIST AT ALL — a different question from the codec's, measured by extracting the real
	// package. Carried on every branch below: a measured grammar for a path nothing ships is still an editor
	// over nothing.
	if seen := asMap(asMap(mustJSON("config_path_verdicts.json"))[path]); len(seen) > 0 {
		if verdict, _ := seen["verdict"].(string); verdict != "file" {
			// An absent path a maintainer script names is created at install time — a real file on a real
			// host, legitimately missing from the archive.
			createdLater := verdict == "absent" && seen["postinst_mentions"] == true
			pkg, _ := seen["package"].(string)
			reason := "this path was measured in package " + pkg + " as " + verdict
			if createdLater {
				reason += "; a maintainer script creates it at install time"
			} else {
				reason += " — no file is shipped there, so there is nothing to edit"
			}
			add("path_verdict", map[string]any{"verdict": verdict, "package": pkg,
				"created_at_install": createdLater, "reason": reason})
		}
	}

	if codecKind != "" && codecKind != "none" {
		directivesRaw, _ := readBundledJSON("config_directives.json")
		dirs := catalogForPath(path, asMap(directivesRaw))
		fields := map[string]any{}
		for key, spec := range dirs {
			if sm := asMap(spec); len(sm) > 0 {
				fields[key] = fieldFromDirective(sm)
			}
		}
		add("write", "codec")
		add("format", codecKind)
		add("separator", orDefault(codec["separator"], ""))
		add("provenance", provenanceOf(codec, asMap(asMap(mustJSON("codec_probe_verdicts.json"))[path])))
		add("fields", fields)
		add("available", true)
		writeJSON(w, http.StatusOK, out)
		return
	}

	// Freeform: the whole-file template is the spec. Resolved through the recorded index by TARGET PATH —
	// never by basename, which once matched /etc/aardvark-dns/aardvark-dns.conf to the template that renders
	// forward.conf, and the write path is whole-file.
	index := templateIndexFor(family)
	entry := asMap(asMap(index["paths"])[path])
	tpl, _ := entry["template"].(string)
	if tpl != "" {
		body, schema, sample, meta := readTemplateDir(tpl)
		withheldRaw, _ := readBundledJSON("template_withheld.json")
		withheld := asSlice(asMap(withheldRaw)[tpl])
		placed := map[string]any{}
		hidden := map[string]bool{}
		for _, f := range withheld {
			if name, ok := f.(string); ok {
				hidden[name] = true
			}
		}
		for name, spec := range schema {
			if !hidden[name] {
				placed[name] = spec
			}
		}
		add("write", "template")
		add("template", body)
		add("template_name", tpl)
		add("sample", sample)
		add("fields", placed)
		add("available", true)
		witness, _ := meta["witness"].(string)
		targetPath, _ := meta["target_path"].(string)
		if targetPath == "" {
			targetPath = path
		}
		if witness == "" {
			witness = "none"
		}
		add("provenance", map[string]any{
			"source": orDefault(meta["source"], "unknown"), "measured": witness == "deb" || witness == "rpm",
			"confidence": map[bool]string{true: "high", false: "unknown"}[witness == "deb" || witness == "rpm"],
			"note":       "renders " + targetPath + " (witness: " + witness + ")",
		})
		// NOTHING VANISHES SILENTLY. A whole-file render can only honour a value it actually places; the
		// fields the body never mentions are withheld, and the count is reported rather than the inputs
		// quietly disappearing from the form.
		if len(withheld) > 0 {
			add("withheld", map[string]any{"count": len(withheld), "fields": withheld,
				"reason": "the template never places these fields, so a value set here could not reach the file"})
		}
		unsettableRaw, _ := readBundledJSON("template_unsettable.json")
		if needs := asSlice(asMap(unsettableRaw)[tpl]); len(needs) > 0 {
			add("unsettable", map[string]any{"count": len(needs), "variables": needs,
				"reason": "the template reads these values and no field offers them, so they render empty"})
		}
		gapsRaw, _ := readBundledJSON("template_renderer_gaps.json")
		if calls := asSlice(asMap(gapsRaw)[tpl]); len(calls) > 0 {
			add("renderer_gaps", map[string]any{"calls": calls,
				"reason": "this template calls a Python method the renderer does not implement; a value that " +
					"reaches that line will fail the write"})
		}
		writeJSON(w, http.StatusOK, out)
		return
	}

	// NO WAY TO EDIT BY FIELD — and the two reasons are different claims, so they get different names.
	//
	//	freeform  MEASURED: no codec fits this file, and no template renders it yet. Editable as raw text;
	//	          generating a template is the work that would make it editable by field.
	//	unknown   nothing has ever been recorded about this path. Not the same claim at all.
	//
	// Collapsing them once produced write="codec", format="none", fields={} for a file whose record says
	// "no grammar fits" — the record said one thing and the API the opposite about the same file.
	write, reason := "unknown", "this path has no codec record and no template — nothing is known about it yet"
	if codecKind == "none" {
		write = "freeform"
		reason = "no codec fits this file (measured) and no template renders it yet — raw text only"
	}
	add("write", write)
	add("reason", reason)
	add("format", nil)
	add("separator", "")
	add("fields", map[string]any{})
	add("available", false)
	writeJSON(w, http.StatusOK, out)
}

// mustJSON reads a bundled artifact, returning nil when it is absent. Named for what it is NOT: there is no
// must about it — a projection that has never been exported simply yields no annotation, which is the right
// behaviour for an agent installed from an older package.
func mustJSON(name string) any {
	v, _ := readBundledJSON(name)
	return v
}

// readTemplateDir returns a template's body, schema, sample and meta from the bundled catalog. A missing
// piece is an empty one: a template whose schema failed to parse still has a body worth showing, and
// refusing the whole answer would hide the file the operator asked about.
func readTemplateDir(name string) (body string, schema, sample, meta map[string]any) {
	if strings.ContainsAny(name, "/\\") || name == "" || name == "." || name == ".." {
		return "", map[string]any{}, map[string]any{}, map[string]any{}
	}
	dir := filepath.Join("config_templates", name)
	if b, err := os.ReadFile(filepath.Join(configsDir, dir, "template.j2")); err == nil {
		body = string(b)
	}
	load := func(file string) map[string]any {
		if v, ok := readBundledJSON(filepath.Join(dir, file)); ok {
			if m := asMap(v); m != nil {
				return m
			}
		}
		return map[string]any{}
	}
	return body, load("schema.json"), load("sample.json"), load("meta.json")
}
