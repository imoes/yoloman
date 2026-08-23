package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixtureCatalog writes a miniature config catalog and points the handlers at it.
func fixtureCatalog(t *testing.T, files map[string]string) {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		full := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old := configsDir
	configsDir = dir
	t.Cleanup(func() { configsDir = old })
}

func getFields(t *testing.T, query string) map[string]any {
	t.Helper()
	mux := http.NewServeMux()
	RegisterConfigFieldRoutes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/config-fields?"+query, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestConfigFields_CodecPathCarriesDirectivesAndProvenance(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_codecs.json": `{"/etc/ssh/sshd_config": {"codec": "space_kv", "separator": " ",
			"source": "probe", "confidence": "high"}}`,
		// Filed under the BASENAME, which 91 catalogs are: a single-key lookup would find no fields at all
		// and the editor would say "no settings" about a file with a measured grammar.
		"config_directives.json": `{"sshd_config": {"PermitRootLogin":
			{"type": "string", "values": ["yes", "no"], "default": {"value": "no"}, "description": "d"}}}`,
	})
	out := getFields(t, "path=/etc/ssh/sshd_config")
	if out["write"] != "codec" || out["format"] != "space_kv" {
		t.Errorf("write/format = %v/%v, want codec/space_kv", out["write"], out["format"])
	}
	field, _ := out["fields"].(map[string]any)["PermitRootLogin"].(map[string]any)
	if field == nil {
		t.Fatalf("no field for a basename-keyed catalog: %v", out["fields"])
	}
	if enum, _ := field["enum"].([]any); len(enum) != 2 {
		t.Errorf("enum = %v, want the directive's values as a dropdown", field["enum"])
	}
	// `{"value": "no"}` is the catalog's shape; a form cannot render a wrapper as a default.
	if field["default"] != "no" {
		t.Errorf("default = %#v, want the unwrapped scalar", field["default"])
	}
	prov, _ := out["provenance"].(map[string]any)
	if prov["measured"] != true {
		t.Errorf("provenance = %v, want measured:true for source=probe", prov)
	}
}

func TestConfigFields_PerFamilyCodecWins(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		// The registry's top level is the conservative answer; the family branch is the measured one. Of 1605
		// paths in both corpora 33 disagree, so a host must get its own family's grammar or the editor writes
		// the wrong shape.
		"config_codecs.json": `{"/etc/logrotate.conf": {"codec": "space_kv", "source": "extension",
			"by_family": {"redhat": {"codec": "nested_block", "source": "probe"}}}}`,
		"config_directives.json": `{}`,
	})
	if out := getFields(t, "path=/etc/logrotate.conf&family=redhat"); out["format"] != "nested_block" {
		t.Errorf("redhat format = %v, want the family branch nested_block", out["format"])
	}
	if out := getFields(t, "path=/etc/logrotate.conf&family=debian"); out["format"] != "space_kv" {
		t.Errorf("debian format = %v, want the top-level space_kv", out["format"])
	}
}

func TestConfigFields_TemplateWithholdsFieldsTheBodyNeverPlaces(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_codecs.json": `{"/etc/nginx/nginx.conf": {"codec": "none"}}`,
		"config_template_index.json": `{"base": {"paths": {"/etc/nginx/nginx.conf":
			{"template": "nginx", "source": "template-meta"}}, "snapins": {}, "conflicts": []},
			"families": {"debian": null, "redhat": null, "suse": null}}`,
		"config_templates/nginx/template.j2": "worker_processes {{ worker_processes }};\n",
		"config_templates/nginx/schema.json": `{"worker_processes": {"type": "int"},
			"ssl_protocols": {"type": "string"}}`,
		"config_templates/nginx/sample.json": `{"worker_processes": 4}`,
		"config_templates/nginx/meta.json":   `{"source": "deb", "witness": "deb", "target_path": "/etc/nginx/nginx.conf"}`,
		"template_withheld.json":             `{"nginx": ["ssl_protocols"]}`,
		"template_renderer_gaps.json":        `{"nginx": ["items"]}`,
	})
	out := getFields(t, "path=/etc/nginx/nginx.conf")
	if out["write"] != "template" || out["template_name"] != "nginx" {
		t.Fatalf("write/template = %v/%v, want template/nginx", out["write"], out["template_name"])
	}
	fields, _ := out["fields"].(map[string]any)
	if _, offered := fields["ssl_protocols"]; offered {
		t.Error("a field the body never places is still offered — a value set there vanishes on write")
	}
	if _, offered := fields["worker_processes"]; !offered {
		t.Error("the field the body does place was dropped")
	}
	// NOTHING VANISHES SILENTLY: withheld is reported, not merely removed.
	wh, _ := out["withheld"].(map[string]any)
	if wh == nil || wh["count"].(float64) != 1 {
		t.Errorf("withheld = %v, want the count and the names", out["withheld"])
	}
	if out["renderer_gaps"] == nil {
		t.Error("a template calling .items() must say so before Apply, not fail during it")
	}
}

func TestConfigFields_FreeformAndUnknownAreDifferentClaims(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_codecs.json":     `{"/etc/rc.local": {"codec": "none"}}`,
		"config_directives.json": `{}`,
	})
	// Measured "no grammar fits" is not the same statement as "nothing was ever recorded". Collapsing them
	// once produced write=codec, format=none, fields={} — the API contradicting the record it read.
	if out := getFields(t, "path=/etc/rc.local"); out["write"] != "freeform" {
		t.Errorf("write = %v, want freeform for a measured codec:none", out["write"])
	}
	out := getFields(t, "path=/etc/never/heard/of.conf")
	if out["write"] != "unknown" {
		t.Errorf("write = %v, want unknown for an unrecorded path", out["write"])
	}
	if out["reason"] == nil || out["reason"] == "" {
		t.Error("a path with no fields must say why")
	}
}

func TestConfigTemplateIndex_FamilyAnswerWinsAndAbsenceIsNamed(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_template_index.json": `{"base": {"paths": {"/etc/cups/cupsd.conf": {"template": "cups"}},
			"snapins": {}, "conflicts": []},
			"families": {"debian": null, "suse": null,
			 "redhat": {"paths": {"/etc/cups/cupsd.conf": {"template": "cups-redhat"}}, "snapins": {},
			 "conflicts": []}}}`,
	})
	mux := http.NewServeMux()
	RegisterConfigFieldRoutes(mux)
	ask := func(q string) map[string]any {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/config-templates/index"+q, nil))
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	paths := ask("?family=redhat")["paths"].(map[string]any)
	entry := paths["/etc/cups/cupsd.conf"].(map[string]any)
	if entry["template"] != "cups-redhat" {
		t.Errorf("redhat template = %v; binding cupsd.conf to `cups` would render cups' snmp.conf over it",
			entry["template"])
	}
	// A null family entry means "same as base" — one answer to keep true rather than three copies.
	paths = ask("?family=debian")["paths"].(map[string]any)
	if paths["/etc/cups/cupsd.conf"].(map[string]any)["template"] != "cups" {
		t.Error("a null family entry must fall back to base, not to nothing")
	}
}

func TestConfigTemplateIndex_MissingArtifactSaysSoInsteadOfGuessing(t *testing.T) {
	fixtureCatalog(t, map[string]string{"config_codecs.json": `{}`})
	mux := http.NewServeMux()
	RegisterConfigFieldRoutes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/config-templates/index", nil))
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out["available"] != false || out["reason"] == "" {
		t.Errorf("out = %v, want available:false with the reason — an empty index must not look like an "+
			"answer, and must never be replaced by a basename guess", out)
	}
}

func TestConfigFields_SaysWhenNoPackageShipsThePath(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		// A measured grammar for a path that is a DIRECTORY. Both facts are true and they are about different
		// questions: the registry says how such a file would be written, the verdict says there is no file.
		"config_codecs.json":     `{"/etc/bind": {"codec": "nested_block", "source": "probe"}}`,
		"config_directives.json": `{}`,
		"config_path_verdicts.json": `{"/etc/bind": {"verdict": "directory", "package": "bind9",
			"postinst_mentions": false}}`,
	})
	out := getFields(t, "path=/etc/bind")
	pv, _ := out["path_verdict"].(map[string]any)
	if pv == nil {
		t.Fatal("a path no package ships as a file must say so — otherwise the editor opens on nothing")
	}
	if pv["verdict"] != "directory" || pv["package"] != "bind9" {
		t.Errorf("path_verdict = %v, want the measured verdict and the package it was measured in", pv)
	}
	if pv["created_at_install"] != false {
		t.Error("a directory is not a config created at install time")
	}
	// The codec is still reported: the measurement refutes the FILE, not the grammar, and hiding the record
	// would take its own refutation with it.
	if out["write"] != "codec" {
		t.Errorf("write = %v; the verdict annotates the answer, it does not replace it", out["write"])
	}
}

func TestConfigFields_AnAbsentPathAMaintainerScriptCreatesIsNotAWarning(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_codecs.json":     `{"/etc/foo.conf": {"codec": "keyvalue"}}`,
		"config_directives.json": `{}`,
		"config_path_verdicts.json": `{"/etc/foo.conf": {"verdict": "absent", "package": "foo",
			"postinst_mentions": true}}`,
	})
	pv, _ := getFields(t, "path=/etc/foo.conf")["path_verdict"].(map[string]any)
	if pv == nil || pv["created_at_install"] != true {
		// Absent from the archive is not absent from the host. Calling this "nothing to edit" would refuse a
		// file that exists on every installed machine.
		t.Errorf("path_verdict = %v, want created_at_install:true", pv)
	}
}

func TestConfigFields_NoVerdictMeansNoClaim(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_codecs.json":     `{"/etc/unmeasured.conf": {"codec": "keyvalue"}}`,
		"config_directives.json": `{}`,
	})
	// An agent installed from an older package has no verdict file at all. Absence of a measurement is not a
	// measurement of absence — it must produce no annotation rather than a warning.
	if out := getFields(t, "path=/etc/unmeasured.conf"); out["path_verdict"] != nil {
		t.Errorf("path_verdict = %v, want none when nothing was measured", out["path_verdict"])
	}
}

func TestConfigFields_DistinguishesNotLookedFromLookedAndUndecidable(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_codecs.json": `{"/etc/security/limits.conf": {"codec": "keyvalue", "confidence": "high"},
			"/etc/never-tried.conf": {"codec": "keyvalue", "confidence": "high"}}`,
		"config_directives.json": `{}`,
		// The shipped file is entirely comments, so the bytes cannot confirm or refute the grammar.
		"codec_probe_verdicts.json": `{"/etc/security/limits.conf": {"verdict": "no-evidence",
			"active_lines": 0, "keys": 0}}`,
	})
	probed, _ := getFields(t, "path=/etc/security/limits.conf")["provenance"].(map[string]any)
	if probed["measured"] != false {
		t.Error("no-evidence is not a measurement of the grammar")
	}
	if !strings.Contains(probed["note"].(string), "no active setting") {
		t.Errorf("note = %q, want the reason the probe could not decide", probed["note"])
	}
	if probed["probe"] == nil {
		t.Error("the probe's own answer must travel, so a screen can tell the two states apart")
	}

	// The other shape: nobody has looked. Same `measured: false`, different work to do.
	untried, _ := getFields(t, "path=/etc/never-tried.conf")["provenance"].(map[string]any)
	if !strings.Contains(untried["note"].(string), "never been checked") {
		t.Errorf("note = %q, want \"never checked\" for a claim nobody probed", untried["note"])
	}
	if untried["probe"] != nil {
		t.Error("an unprobed path must carry no probe record — that would be a measurement it never had")
	}
}

func TestConfigFields_ADisarmedVerdictIsNotAWarning(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_codecs.json":     `{"/etc/hostname": {"codec": "raw"}, "/etc/named.conf": {"codec": "nested_block"}}`,
		"config_directives.json": `{}`,
		"config_path_verdicts.json": `{
			"/etc/hostname":   {"verdict": "absent", "package": "hostname", "postinst_mentions": false,
			                    "exists_elsewhere": false},
			"/etc/named.conf": {"verdict": "absent", "package": "bind9", "postinst_mentions": false,
			                    "exists_elsewhere": true}}`,
		// No package on any distribution owns /etc/hostname — the system creates it.
		"config_unowned_paths.json": `{"/etc/hostname": {"families": ["debian"], "container_artifact": false}}`,
	})
	// Both are "absent" and both files exist on every host. Reporting either as "nothing to edit" would be
	// a false statement about the machine's own hostname and about EL's named.conf.
	if out := getFields(t, "path=/etc/hostname"); out["path_verdict"] != nil {
		t.Errorf("path_verdict = %v; a file no package owns is expected to be absent from every archive",
			out["path_verdict"])
	}
	if out := getFields(t, "path=/etc/named.conf"); out["path_verdict"] != nil {
		t.Errorf("path_verdict = %v; the corpus proves this file exists, just not in the Debian package",
			out["path_verdict"])
	}
}

func TestConfigFields_TheFamilysOwnPathVerdictWins(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_codecs.json":     `{"/etc/named.conf": {"codec": "nested_block"}}`,
		"config_directives.json": `{}`,
		// Measured on both distributions and they disagree — 20 of 83 such paths do. The conservative top
		// level says "file" so a host-independent view never withdraws it; a host that knows its family must
		// not settle for that.
		"config_path_verdicts.json": `{"/etc/named.conf": {"verdict": "file", "package": "bind",
			"family": "redhat", "exists_elsewhere": true,
			"by_family": {"debian": {"verdict": "absent", "package": "bind9", "postinst_mentions": false},
			              "redhat": {"verdict": "file",   "package": "bind",  "postinst_mentions": true}}}}`,
	})
	// On Debian the file genuinely is not there — Debian's bind9 reads /etc/bind/named.conf — so a whole-file
	// write would create a file the daemon ignores. That must be said.
	deb, _ := getFields(t, "path=/etc/named.conf&family=debian")["path_verdict"].(map[string]any)
	if deb == nil {
		t.Fatal("Debian ships no file there and the answer stayed silent about it")
	}
	if deb["verdict"] != "absent" || deb["package"] != "bind9" || deb["family"] != "debian" {
		t.Errorf("path_verdict = %v, want Debian's own measurement", deb)
	}
	// On EL it is a real file: no warning at all.
	if el := getFields(t, "path=/etc/named.conf&family=redhat")["path_verdict"]; el != nil {
		t.Errorf("path_verdict = %v; EL ships this file", el)
	}
}
