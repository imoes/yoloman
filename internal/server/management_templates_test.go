package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// getTemplates runs the template surface against a fixture catalog. It registers all THREE routes on one
// mux — the listing, the {name} lookup and the literal /index — because their coexistence is part of what is
// under test: {name} must not swallow "index", and the daemon mounts them from two different functions.
func getTemplates(t *testing.T, suffix string) map[string]any {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/config-templates", func(w http.ResponseWriter, r *http.Request) {
		mgmtConfigTemplates(w, r)
	})
	mux.HandleFunc("GET /api/v1/config-templates/{name}", func(w http.ResponseWriter, r *http.Request) {
		mgmtConfigTemplate(w, r)
	})
	RegisterConfigFieldRoutes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/config-templates"+suffix, nil))
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	out["_status"] = float64(rec.Code)
	return out
}

// The listing must stay a listing. It used to return every template's body, schema and sample in one reply —
// against the real tree a ~36 MB document assembled in memory, for a caller that then edits one path. A body
// leaking back into the listing is the regression this pins.
func TestConfigTemplates_ListingCarriesNoBodies(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_templates/nginx/template.j2": "worker_processes {{ worker_processes }};\n",
		"config_templates/nginx/schema.json": `{"worker_processes": {"type": "int"}}`,
		"config_templates/nginx/meta.json":   `{"source": "deb", "target_path": "/etc/nginx/nginx.conf"}`,
		"config_templates/bind9/template.j2": "options { directory \"{{ directory }}\"; };\n",
		"config_templates/bind9/meta.json":   `{"source": "deb", "target_path": "/etc/bind/named.conf"}`,
		"config_templates_manifest.json": `{"shipped": 2, "withheld": 4424,
			"criterion": "nothing names them"}`,
	})
	out := getTemplates(t, "")
	list, _ := out["templates"].([]any)
	if len(list) != 2 {
		t.Fatalf("listed %d templates, want 2", len(list))
	}
	for _, item := range list {
		entry, _ := item.(map[string]any)
		if _, carried := entry["template"]; carried {
			t.Errorf("%v carries its body in the listing", entry["name"])
		}
		if _, carried := entry["schema"]; carried {
			t.Errorf("%v carries its schema in the listing", entry["name"])
		}
		if entry["target_path"] == nil {
			t.Errorf("%v has no target_path — then the listing cannot be used to choose one", entry["name"])
		}
	}
	// NOTHING VANISHES SILENTLY. The package ships fewer templates than Bossman knows, and the count plus
	// the criterion are what turn that from a discrepancy into a stated fact.
	if out["withheld"] != float64(4424) {
		t.Errorf("withheld = %v, want the manifest's 4424", out["withheld"])
	}
	// And NOT a shipped count: that is len(templates), and a field restating it is a second thing to keep
	// true — the two would disagree the first time a template failed to stage.
	if _, restated := out["shipped"]; restated {
		t.Error("the reply restates the shipped count that the list itself already gives")
	}
	if s, _ := out["criterion"].(string); s == "" {
		t.Error("withheld is reported without the reason it was withheld")
	}
}

// A missing manifest is an OLDER PACKAGE, not an error: the listing still answers, it just cannot say how
// many were withheld. Reporting withheld=0 in that case would be the one wrong answer — it would claim
// completeness that was never measured.
func TestConfigTemplates_ListingWithoutAManifestClaimsNoCounts(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_templates/nginx/template.j2": "worker_processes 4;\n",
	})
	out := getTemplates(t, "")
	if _, claimed := out["withheld"]; claimed {
		t.Error("no manifest, yet the reply states a withheld count")
	}
	if list, _ := out["templates"].([]any); len(list) != 1 {
		t.Fatalf("listed %d, want the one template that is there", len(list))
	}
}

func TestConfigTemplates_OneByName(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_templates/nginx/template.j2": "worker_processes {{ worker_processes }};\n",
		"config_templates/nginx/schema.json": `{"worker_processes": {"type": "int"}}`,
		"config_templates/nginx/sample.json": `{"worker_processes": 4}`,
		"config_templates/nginx/meta.json":   `{"target_path": "/etc/nginx/nginx.conf"}`,
		// Bossman's reply for this route carries capabilities; standalone must not quietly drop it.
		"config_templates/nginx/capabilities.json": `{"provides": ["http-server"]}`,
	})
	out := getTemplates(t, "/nginx")
	if caps, _ := out["capabilities"].(map[string]any); caps["provides"] == nil {
		t.Error("capabilities did not come with the template — Bossman's reply for this route carries them")
	}
	if !strings.Contains(out["template"].(string), "worker_processes") {
		t.Errorf("body = %q, want the template source", out["template"])
	}
	if schema, _ := out["schema"].(map[string]any); schema["worker_processes"] == nil {
		t.Error("the schema did not come with the body")
	}

	// A withheld or misspelled name gets a 404 that says WHY it might be absent — otherwise the only
	// available reading is "this template does not exist", which for 4424 of them is false.
	missing := getTemplates(t, "/doesnotexist")
	if missing["_status"] != float64(http.StatusNotFound) {
		t.Errorf("status = %v, want 404", missing["_status"])
	}
	if s, _ := missing["reason"].(string); !strings.Contains(s, "withholds") {
		t.Errorf("reason = %q, want it to name withholding as a possible cause", s)
	}
}

// A name is a directory label, never a path. A plain ../ is cleaned away by net/http before routing, so the
// case worth pinning is the ENCODED one: %2f survives into the wildcard and PathValue hands back a decoded
// "../../etc/passwd". readTemplateDir refuses the separator, and this is the test that says so.
func TestConfigTemplates_EncodedTraversalIsRefused(t *testing.T) {
	fixtureCatalog(t, map[string]string{"config_templates/nginx/template.j2": "worker_processes 4;\n"})
	out := getTemplates(t, "/..%2f..%2f..%2fetc%2fpasswd")
	if out["_status"] != float64(http.StatusNotFound) {
		t.Errorf("status = %v, want 404 — a name with a separator in it is not a template", out["_status"])
	}
}

// /config-templates/index is the path INDEX, not a template called "index". The wildcard route must not
// swallow it. Go resolves by specificity so this holds regardless of registration order — pinned because the
// same two routes on Bossman's FastAPI depend on declaration order, and a reader who knows that rule would
// reasonably expect it to matter here too.
func TestConfigTemplates_IndexIsNotATemplateName(t *testing.T) {
	fixtureCatalog(t, map[string]string{
		"config_template_index.json": `{"base": {"paths": {"/etc/nginx/nginx.conf":
			{"template": "nginx", "source": "template-meta"}}, "snapins": {}, "conflicts": []},
			"families": {"debian": null, "redhat": null, "suse": null}}`,
		"config_templates/nginx/template.j2": "worker_processes 4;\n",
	})
	out := getTemplates(t, "/index")
	if out["_status"] != float64(http.StatusOK) {
		t.Fatalf("status = %v, want the index to answer 200", out["_status"])
	}
	paths, _ := out["paths"].(map[string]any)
	if paths["/etc/nginx/nginx.conf"] == nil {
		t.Errorf("/index served something other than the path index: %v", out)
	}
}
