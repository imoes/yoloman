package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// This file gives the standalone agent the same host-management REST surface a
// Fleet Commander (Bossman) exposes per agent, so the reused fleet management
// UI works directly against the agent — network / service-units / logs /
// accounts / storage / updates / virt, plus the config catalog for the
// Roles & Features wizard. Each endpoint calls the agent's OWN module in
// process (the same module Bossman would call remotely) and reshapes the
// result identically. Data-gathering endpoints only need read modules; the
// write endpoints honor the global write gate.
//
// The modules used are all either native Go or embedded built-ins
// (network_interface, package_updates, zpool_facts), so these work even with
// modules_autoload=false.

// configsDir is where the .deb ships the bundled config catalog (codecs,
// directives, templates, package catalog) for the standalone Server Manager.
// configsDir is where the package installs the config catalog (codecs, directives, templates, and the
// recorded projections the standalone field editor serves). A var, not a const, so a test can point it at a
// fixture — the alternative is testing the handlers against whatever the build host happens to have
// installed, which is not a test.
var configsDir = "/usr/share/agentic-mcp/configs"

// RegisterManagementRoutes mounts the per-host management endpoints on mux.
// They inherit the same identity/auth wrapper as the rest of /api/v1.
func RegisterManagementRoutes(mux *http.ServeMux, cfg RESTConfig) {
	mux.HandleFunc("GET /api/v1/network", func(w http.ResponseWriter, r *http.Request) { mgmtNetwork(w, r, cfg) })
	mux.HandleFunc("POST /api/v1/network", func(w http.ResponseWriter, r *http.Request) { mgmtNetworkConfigure(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/storage", func(w http.ResponseWriter, r *http.Request) { mgmtStorage(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/service-units", func(w http.ResponseWriter, r *http.Request) { mgmtServiceUnits(w, r, cfg) })
	mux.HandleFunc("POST /api/v1/service-control", func(w http.ResponseWriter, r *http.Request) { mgmtServiceControl(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/logs", func(w http.ResponseWriter, r *http.Request) { mgmtLogs(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/logs/files", func(w http.ResponseWriter, r *http.Request) { mgmtLogFiles(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/logs/file", func(w http.ResponseWriter, r *http.Request) { mgmtLogFile(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/accounts", func(w http.ResponseWriter, r *http.Request) { mgmtAccounts(w, r, cfg) })
	mux.HandleFunc("POST /api/v1/accounts/user", func(w http.ResponseWriter, r *http.Request) { mgmtUser(w, r, cfg) })
	mux.HandleFunc("POST /api/v1/accounts/group", func(w http.ResponseWriter, r *http.Request) { mgmtGroup(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/updates", func(w http.ResponseWriter, r *http.Request) { mgmtUpdates(w, r, cfg) })
	mux.HandleFunc("POST /api/v1/updates", func(w http.ResponseWriter, r *http.Request) { mgmtUpdatesApply(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/virt", func(w http.ResponseWriter, r *http.Request) { mgmtVirt(w, r, cfg) })
	// Config catalog for the Roles & Features wizard (served from the bundle).
	mux.HandleFunc("GET /api/v1/config-templates", func(w http.ResponseWriter, r *http.Request) { mgmtConfigTemplates(w, r) })
	mux.HandleFunc("GET /api/v1/config-codecs", func(w http.ResponseWriter, r *http.Request) { mgmtConfigCodecs(w, r) })
	mux.HandleFunc("GET /api/v1/config-directives", func(w http.ResponseWriter, r *http.Request) { mgmtConfigDirectives(w, r) })
	mux.HandleFunc("GET /api/v1/package-catalog", func(w http.ResponseWriter, r *http.Request) { mgmtPackageCatalog(w, r) })
	mux.HandleFunc("GET /api/v1/package-wizard/context", func(w http.ResponseWriter, r *http.Request) { mgmtWizardContext(w, r, cfg) })
	// The console's ensureModules() pushes management modules; on the agent
	// they are built-ins, so a sync is a no-op success rather than a 404.
	mux.HandleFunc("POST /api/v1/modules/sync", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"pushed": 0, "result": map[string]any{"applied": 0, "results": []any{}}})
	})
}

// callModuleData runs a registered module in process and returns its Result
// payload as JSON-decoded generic data (map or slice), so both native (struct)
// and Starlark (map) modules reshape uniformly.
func callModuleData(cfg RESTConfig, r *http.Request, name string, params map[string]any, write bool) (any, error) {
	m, ok := cfg.ModReg.Get(name)
	if !ok {
		return nil, fmt.Errorf("module %q not available", name)
	}
	if write && !cfg.Write {
		return nil, fmt.Errorf("write is disabled (write=false)")
	}
	res, err := m.Run(r.Context(), params, false)
	if err != nil {
		return nil, err
	}
	if res.Data == nil {
		return map[string]any{}, nil
	}
	raw, err := json.Marshal(res.Data)
	if err != nil {
		return nil, err
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func asMap(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

func mgmtError(w http.ResponseWriter, err error) { writeError(w, http.StatusBadGateway, err) }

func mgmtNetwork(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	d, err := callModuleData(cfg, r, "yoloman.network_interface", map[string]any{"state": "gathered"}, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	m := asMap(d)
	writeJSON(w, http.StatusOK, map[string]any{
		"agent_id": "self", "provider": m["provider"], "interfaces": m["interfaces"],
		"routes": m["routes"], "dns": m["dns"],
	})
}

func mgmtNetworkConfigure(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body == nil {
		body = map[string]any{}
	}
	d, err := callModuleData(cfg, r, "yoloman.network_interface", body, true)
	if err != nil {
		mgmtError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"agent_id": "self", "result": map[string]any{"data": d}})
}

func mgmtStorage(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	d, err := callModuleData(cfg, r, "storage_facts", map[string]any{}, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	m := asMap(d)
	zfs := map[string]any{"available": false}
	if zd, zerr := callModuleData(cfg, r, "community.general.zpool_facts", map[string]any{}, false); zerr == nil {
		zfs = map[string]any{"available": true, "pools": asMap(zd)["pools"]}
	} else {
		zfs["error"] = zerr.Error()
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"agent_id": "self", "block_devices": m["block_devices"], "lvm": m["lvm"], "vdo": m["vdo"], "zfs": zfs,
	})
}

func mgmtServiceUnits(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	d, err := callModuleData(cfg, r, "service_facts", map[string]any{}, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"agent_id": "self", "services": d})
}

func mgmtServiceControl(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	var body struct {
		Service string `json:"service"`
		Action  string `json:"action"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.Service) == "" {
		writeError(w, http.StatusBadRequest, fmt.Errorf("service and action are required"))
		return
	}
	params := map[string]any{"name": body.Service}
	switch body.Action {
	case "start":
		params["state"] = "started"
	case "stop":
		params["state"] = "stopped"
	case "restart":
		params["state"] = "restarted"
	case "reload":
		params["state"] = "reloaded"
	case "enable":
		params["enabled"] = true
	case "disable":
		params["enabled"] = false
	default:
		writeError(w, http.StatusBadRequest, fmt.Errorf("unknown action %q", body.Action))
		return
	}
	d, err := callModuleData(cfg, r, "systemd", params, true)
	if err != nil {
		mgmtError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"agent_id": "self", "service": body.Service, "action": body.Action, "result": map[string]any{"data": d}})
}

func mgmtLogs(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	q := r.URL.Query()
	params := map[string]any{"lines": queryInt(q.Get("lines"), 200), "boot": q.Get("boot") == "true"}
	for _, k := range []string{"unit", "priority", "since", "grep"} {
		if v := q.Get(k); v != "" {
			params[k] = v
		}
	}
	d, err := callModuleData(cfg, r, "journal", params, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	m := asMap(d)
	writeJSON(w, http.StatusOK, map[string]any{"agent_id": "self", "entries": orEmpty(m["entries"]), "count": m["count"]})
}

func mgmtLogFiles(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	params := map[string]any{"state": "list"}
	if ep := r.URL.Query()["extra_paths"]; len(ep) > 0 {
		params["extra_paths"] = toAnySlice(ep)
	}
	d, err := callModuleData(cfg, r, "logfiles", params, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	m := asMap(d)
	writeJSON(w, http.StatusOK, map[string]any{"agent_id": "self", "roots": orEmpty(m["roots"]), "files": orEmpty(m["files"])})
}

func mgmtLogFile(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	q := r.URL.Query()
	path := q.Get("path")
	if path == "" {
		writeError(w, http.StatusBadRequest, fmt.Errorf("path is required"))
		return
	}
	params := map[string]any{"state": "read", "path": path, "lines": queryInt(q.Get("lines"), 500)}
	if g := q.Get("grep"); g != "" {
		params["grep"] = g
		if q.Get("regex") == "true" {
			params["regex"] = true
		}
		if q.Get("invert") == "true" {
			params["invert"] = true
		}
	}
	if ep := q["extra_paths"]; len(ep) > 0 {
		params["extra_paths"] = toAnySlice(ep)
	}
	d, err := callModuleData(cfg, r, "logfiles", params, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	m := asMap(d)
	writeJSON(w, http.StatusOK, map[string]any{
		"agent_id": "self", "path": orDefault(m["path"], path), "lines": orEmpty(m["lines"]),
		"truncated": m["truncated"], "size": m["size"],
	})
}

func mgmtAccounts(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	passwd, err := callModuleData(cfg, r, "getent", map[string]any{"database": "passwd"}, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	group, err := callModuleData(cfg, r, "getent", map[string]any{"database": "group"}, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	users := []map[string]any{}
	for _, f := range getentRows(passwd) {
		if len(f) < 7 {
			continue
		}
		uid, uerr := strconv.Atoi(f[2])
		if uerr != nil {
			continue
		}
		var gid any
		if g, gerr := strconv.Atoi(f[3]); gerr == nil {
			gid = g
		}
		users = append(users, map[string]any{"name": f[0], "uid": uid, "gid": gid,
			"gecos": f[4], "home": f[5], "shell": f[6], "system": uid < 1000})
	}
	groups := []map[string]any{}
	for _, f := range getentRows(group) {
		if len(f) < 3 {
			continue
		}
		var gid any
		system := false
		if g, gerr := strconv.Atoi(f[2]); gerr == nil {
			gid = g
			system = g < 1000
		}
		members := []string{}
		if len(f) > 3 && f[3] != "" {
			for _, mmb := range strings.Split(f[3], ",") {
				if mmb != "" {
					members = append(members, mmb)
				}
			}
		}
		groups = append(groups, map[string]any{"name": f[0], "gid": gid, "members": members, "system": system})
	}
	writeJSON(w, http.StatusOK, map[string]any{"agent_id": "self", "users": users, "groups": groups})
}

// getentRows pulls the colon-split field lists out of a getent module payload
// ([]{name, fields:[...]}).
func getentRows(d any) [][]string {
	rows := [][]string{}
	list, ok := d.([]any)
	if !ok {
		return rows
	}
	for _, e := range list {
		em := asMap(e)
		fl, ok := em["fields"].([]any)
		if !ok {
			continue
		}
		row := make([]string, 0, len(fl))
		for _, f := range fl {
			row = append(row, fmt.Sprintf("%v", f))
		}
		rows = append(rows, row)
	}
	return rows
}

func mgmtUser(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	mgmtAccountAction(w, r, cfg, "user")
}
func mgmtGroup(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	mgmtAccountAction(w, r, cfg, "group")
}

func mgmtAccountAction(w http.ResponseWriter, r *http.Request, cfg RESTConfig, module string) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(fmt.Sprintf("%v", body["name"])) == "" {
		writeError(w, http.StatusBadRequest, fmt.Errorf("name is required"))
		return
	}
	d, err := callModuleData(cfg, r, module, body, true)
	if err != nil {
		mgmtError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"agent_id": "self", "result": map[string]any{"data": d}})
}

func mgmtUpdates(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	d, err := callModuleData(cfg, r, "yoloman.package_updates", map[string]any{"state": "list"}, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	m := asMap(d)
	writeJSON(w, http.StatusOK, map[string]any{
		"agent_id": "self", "manager": orDefault(m["manager"], "unknown"), "updates": orEmpty(m["updates"]),
		"count": m["count"], "security_count": m["security_count"], "reboot_required": m["reboot_required"],
	})
}

func mgmtUpdatesApply(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	var body struct {
		SecurityOnly bool `json:"security_only"`
		DryRun       bool `json:"dry_run"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	params := map[string]any{"state": "apply", "security_only": body.SecurityOnly, "dry_run": body.DryRun}
	d, err := callModuleData(cfg, r, "yoloman.package_updates", params, true)
	if err != nil {
		mgmtError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"agent_id": "self", "result": map[string]any{"data": d}})
}

func mgmtVirt(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	d, err := callModuleData(cfg, r, "virt_facts", map[string]any{}, false)
	if err != nil {
		mgmtError(w, err)
		return
	}
	m := asMap(d)
	m["agent_id"] = "self"
	writeJSON(w, http.StatusOK, m)
}

// ---- config catalog (served from the bundled /usr/share/agentic-mcp/configs) --

func readBundledJSON(name string) (any, bool) {
	b, err := os.ReadFile(filepath.Join(configsDir, name))
	if err != nil {
		return nil, false
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, false
	}
	return v, true
}

func mgmtPackageCatalog(w http.ResponseWriter, _ *http.Request) {
	v, ok := readBundledJSON("package_catalog.json")
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"packages": map[string]any{}})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"packages": v})
}

func mgmtConfigDirectives(w http.ResponseWriter, _ *http.Request) {
	v, ok := readBundledJSON("config_directives.json")
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"directives": map[string]any{}, "available": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"directives": v, "available": true})
}

func mgmtConfigCodecs(w http.ResponseWriter, _ *http.Request) {
	v, ok := readBundledJSON("config_codecs.json")
	raw, _ := v.(map[string]any)
	if !ok || raw == nil {
		writeJSON(w, http.StatusOK, map[string]any{"entries": []any{}, "available": false})
		return
	}
	entries := []map[string]any{}
	for pattern, spec := range raw {
		sm := asMap(spec)
		entries = append(entries, map[string]any{
			"pattern": pattern, "codec": orDefault(sm["codec"], "none"), "confidence": orDefault(sm["confidence"], "unknown"),
			"comment": sm["comment"], "separator": sm["separator"], "notes": sm["notes"],
			"sections": sm["sections"], "paths": sm["paths"], "packages": sm["packages"],
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "available": true})
}

func mgmtConfigTemplates(w http.ResponseWriter, _ *http.Request) {
	root := filepath.Join(configsDir, "config_templates")
	templates := []map[string]any{}
	dirs, err := os.ReadDir(root)
	if err == nil {
		for _, d := range dirs {
			if !d.IsDir() {
				continue
			}
			tpl := filepath.Join(root, d.Name(), "template.j2")
			body, terr := os.ReadFile(tpl)
			if terr != nil {
				continue
			}
			entry := map[string]any{"name": d.Name(), "template": string(body)}
			for key, fname := range map[string]string{"schema": "schema.json", "sample": "sample.json"} {
				if v, ok := readBundledJSON(filepath.Join("config_templates", d.Name(), fname)); ok {
					entry[key] = v
				} else {
					entry[key] = map[string]any{}
				}
			}
			templates = append(templates, entry)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"templates": templates})
}

// mgmtWizardContext backs the Roles & Features wizard: the host's OS family,
// which catalog roles are installed (from package_facts), and each role's
// family-resolved package names / service / config path. Mirrors Bossman's
// GET /agents/{id}/package-wizard/context.
func mgmtWizardContext(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	family := osFamily()
	cat, _ := readBundledJSON("package_catalog.json")
	catalog := asMap(cat)

	// Installed package name → version, from the package_facts module.
	inv := map[string]string{}
	if d, err := callModuleData(cfg, r, "package_facts", map[string]any{}, false); err == nil {
		if list, ok := d.([]any); ok {
			for _, e := range list {
				em := asMap(e)
				if n, ok := em["name"].(string); ok && n != "" {
					inv[n] = fmt.Sprintf("%v", em["version"])
				}
			}
		}
	}

	installed := map[string]string{}
	resolved := map[string]any{}
	for pkg, entryAny := range catalog {
		entry := asMap(entryAny)
		fams := asMap(entry["families"])
		fam := asMap(fams[family])
		if len(fam) == 0 {
			fam = asMap(fams["debian"])
		}
		if len(fam) == 0 {
			for _, v := range fams { // any family
				fam = asMap(v)
				break
			}
		}
		resolved[pkg] = map[string]any{
			"packages": orEmpty(fam["packages"]), "service": orDefault(fam["service"], ""),
			"config_path": orDefault(fam["config_path"], ""),
		}
		if names, ok := fam["packages"].([]any); ok {
			for _, n := range names {
				if ver, present := inv[fmt.Sprintf("%v", n)]; present {
					installed[pkg] = ver
					break
				}
			}
		}
	}
	host, _ := os.Hostname()
	writeJSON(w, http.StatusOK, map[string]any{
		"host": host, "family": family, "installed": installed, "catalog_resolved": resolved,
	})
}

// osFamily derives debian/redhat/suse from /etc/os-release (default debian).
func osFamily() string {
	b, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return "debian"
	}
	s := strings.ToLower(string(b))
	for _, t := range []string{"rhel", "centos", "fedora", "rocky", "almalinux", "redhat"} {
		if strings.Contains(s, t) {
			return "redhat"
		}
	}
	if strings.Contains(s, "suse") || strings.Contains(s, "sles") {
		return "suse"
	}
	return "debian"
}

// ---- small helpers ----

func queryInt(s string, def int) int {
	if s == "" {
		return def
	}
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return def
}

func orEmpty(v any) any {
	if v == nil {
		return []any{}
	}
	return v
}

func orDefault(v any, def any) any {
	if v == nil {
		return def
	}
	return v
}

func toAnySlice(s []string) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}
