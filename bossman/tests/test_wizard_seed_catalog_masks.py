"""Every seeded role's input mask, checked over the REAL catalog and playbooks.

Two defect classes the Playwright scenarios found in single roles and that are cheap to rule out for all:

  * a default outside its own value set — install-apache2 declared `keepalive: On` (YAML 1.1 reads that as
    the boolean true) next to the enum ["On", "Off"], so the dropdown had no valid initial selection;
  * a playbook rendering a template other than the catalog's — install-memcached rendered `memcached`
    (/etc/default/memcached, ENABLE_MEMCACHED=yes) over /etc/memcached.conf, install-chrony rendered `chrony`
    (one DAEMON_OPTS line) over /etc/chrony/chrony.conf.
"""

import json
from pathlib import Path

import pytest

from bossman.services.wizard_seed import _enum_member, _remap_template_step, wizard_doc

CONFIGS = Path(__file__).resolve().parents[2] / "configs"


def _catalog() -> dict:
    return json.loads((CONFIGS / "package_catalog.json").read_text())


def _docs():
    directives = json.loads((CONFIGS / "config_directives.json").read_text())
    for pkg, entry in sorted(_catalog().items()):
        built = wizard_doc(pkg, entry, CONFIGS / "config_templates", CONFIGS / "wizard_playbooks", directives)
        if built is not None:
            yield pkg, entry, built[0]


def test_every_enum_default_is_a_member_of_its_enum():
    bad = []
    for pkg, _entry, doc in _docs():
        for name, spec in (doc.get("parameters") or {}).items():
            enum = spec.get("enum")
            if not enum or spec.get("enum_open") or "default" not in spec or spec["default"] in (None, ""):
                continue
            if spec["default"] not in enum:
                bad.append(f"install-{pkg}.{name}: default {spec['default']!r} not in {enum!r}")
    assert not bad, "\n".join(bad)


def test_every_render_step_uses_the_catalogs_template():
    bad = []
    for pkg, entry, doc in _docs():
        for step in doc.get("steps") or []:
            if step.get("module") == "config_template" and step["args"].get("template") != entry["template"]:
                bad.append(f"install-{pkg}: renders {step['args'].get('template')!r}, catalog says {entry['template']!r}")
    assert not bad, "\n".join(bad)


def test_apache2_keepalive_starts_on_one_of_its_options():
    doc = next(d for p, _e, d in _docs() if p == "apache2")
    assert doc["parameters"]["keepalive"]["default"] in ("On", "Off")
    assert doc["parameters"]["keepalive"]["type"] == "string"


def test_memcached_role_renders_the_memcached_conf_template():
    doc = next(d for p, _e, d in _docs() if p == "memcached")
    render = next(s for s in doc["steps"] if s.get("module") == "config_template")
    assert render["args"]["template"] == "memcached.conf"


@pytest.mark.parametrize("value,enum,expected", [
    (True, ["On", "Off"], "On"), (False, ["On", "Off"], "Off"), (True, ["yes", "no"], "yes"),
    (3, ["1", "3"], "3"), ("x", ["a"], "x"), ("a", ["a"], "a"),
])
def test_enum_member(value, enum, expected):
    assert _enum_member(value, enum) == expected


def test_remap_prefers_the_catalog_template():
    step = {"name": "Render", "module": "ansible.builtin.template", "args": {"src": "chrony.j2", "dest": "/x"}}
    assert _remap_template_step(step, "chrony.conf")["args"]["template"] == "chrony.conf"
    assert _remap_template_step(step)["args"]["template"] == "chrony"


def test_every_seeded_default_passes_the_roles_own_validation():
    """A default the role's own validation rejects refused the role at preview (docker, fapolicyd, gammu, ipmiseld)."""
    from bossman.services.wizard_seed import _coerce_default

    cases = [({"type": "bool", "default": "1"}, True), ({"type": "object", "default": "x"}, None),
             ({"type": "string", "enum": ["mysql", "sqlite3"], "default": "sqlite"}, None),
             ({"type": "number", "default": "42"}, 42), ({"type": "string", "enum": ["On", "Off"], "default": True}, "On")]
    for spec, want in cases:
        _coerce_default(spec)
        assert spec.get("default") == want, spec
        if want is None:
            assert "default_dropped" in spec


def test_an_object_fields_default_is_derived_from_its_properties():
    """fastnetmon `main` had no default but its properties did; `{{ main.ban_time }}` rendered nothing."""
    from bossman.services.schema_defaults import default_of, schema_defaults

    main = {"type": "object", "properties": {"ban_time": {"type": "number", "default": 300},
                                             "graphite": {"type": "object", "properties": {"port": {"default": 2003}}},
                                             "free": {"type": "string"}}}
    assert default_of(main) == {"ban_time": 300, "graphite": {"port": 2003}}
    assert schema_defaults({"main": main, "x": {"default": None}}) == {"main": {"ban_time": 300, "graphite": {"port": 2003}}}


def test_playbook_literals_are_bound_to_the_host_familys_catalog_values():
    """install-docker-daemon named docker-ce; a day after the catalog said docker.io it still installed docker-ce."""
    from bossman.services.wizard_seed import _bind_family_runtime

    pkg = _bind_family_runtime({"name": "Install", "module": "apt", "args": {"name": ["docker-ce"], "state": "present",
                                                                            "update_cache": True}})
    assert pkg["module"] == "package" and pkg["args"] == {"name": "{{ _packages }}", "state": "present"}
    svc = _bind_family_runtime({"name": "Restart", "module": "service", "args": {"name": "docker", "state": "restarted"}})
    assert svc["args"]["name"] == "{{ _service }}" and svc["when"] == "_service"
    tpl = _bind_family_runtime({"module": "config_template", "args": {"template": "x", "dest": "/etc/bind/named.conf"}})
    assert tpl["args"]["dest"] == "{{ _dest }}"
    removal = {"module": "package", "args": {"name": "old", "state": "absent"}}
    assert _bind_family_runtime(removal) is removal


def test_service_step_naming_the_runtime_unit_is_guarded():
    """A playbook service step already written as `{{ _service }}` gets `when: _service` too — adminer has no unit,
    and the unguarded step ran `systemctl restart .service` (Bossman-path e2e)."""
    from bossman.services.wizard_seed import _bind_family_runtime
    step = {"name": "restart", "module": "service", "args": {"name": "{{ _service }}", "state": "restarted"}}
    out = _bind_family_runtime(step)
    assert out["when"] == "_service" and out["args"]["masked"] is False
    guarded = _bind_family_runtime({**step, "when": "_service"})
    assert guarded["when"] == "_service"


def test_the_mask_is_the_templates_fields_with_the_playbooks_defaults():
    """samba's form offered `workgroup`, which its template never read, and lacked fields the template has. The
    template's schema now defines the fields; a play var only sets a default — or stays when the template reads it."""
    from bossman.services.wizard_seed import _params_from_play_vars
    schema = {"server_string": {"type": "string", "default": "Samba", "description": "banner"},
              "log_level": {"type": "number", "default": 1}}
    body = "server string = {{ server_string }}\nlog level = {{ log_level }}\nmax log = {{ max_log_size }}\n"
    play = {"workgroup": "WG", "server_string": "Office", "max_log_size": 1000, "_packages": ["samba"]}
    params = _params_from_play_vars(play, schema, body)
    assert "workgroup" not in params                                   # read by nothing → not offered
    assert params["server_string"]["default"] == "Office"             # playbook sets the default
    assert params["server_string"]["description"] == "banner"
    assert params["log_level"]["default"] == 1                        # schema field the vars block lacked
    assert params["max_log_size"]["default"] == 1000                  # template reads it: schema gap, kept
    assert params["_packages"]["hidden"] is True


def test_a_required_template_field_is_required_in_the_wizard():
    from bossman.services.wizard_seed import _build_parameters

    params = _build_parameters({"topdomain": {"type": "string", "required": True, "description": "t"},
                                "mtu": {"type": "number", "default": 1130}}, {}, {"families": {}})
    assert params["topdomain"]["required"] is True and "required" not in params["mtu"]


def test_the_form_offers_the_family_templates_own_fields():
    """9 of 26 roles shared NO field with the template they render on AlmaLinux, and squid lacked 205 of 207: the
    wizard greyed out everything there. The form is now the union — a family template's own fields join, tagged
    with the family and never required for the role as a whole; a field both files have stays one field."""
    by_pkg = {pkg: doc for pkg, _entry, doc in _docs()}
    tdir = CONFIGS / "config_templates"
    for role in ("squid", "bind9", "clamav"):
        entry = _catalog()[role]
        path = entry["families"]["redhat"]["config_path"]
        from bossman.services.wizard_seed import family_templates
        el = family_templates(tdir)[("redhat", path)]
        el_fields = set(json.loads((tdir / el / "schema.json").read_text()))
        params = by_pkg[role]["parameters"]
        role_fields = set(json.loads((tdir / entry["template"] / "schema.json").read_text()))
        for f in el_fields - role_fields:
            assert params[f]["families"] == ["redhat"], (role, f)
            assert not params[f].get("required"), (role, f)
        for f in role_fields & el_fields:
            assert not params[f].get("families"), (role, f)


def test_a_file_shaped_site_value_becomes_a_field_and_a_copy_step():
    """G2: ctdb needs /etc/ctdb/nodes, mysqld-exporter ~prometheus/.my.cnf — whole files only the site has. The
    catalog declares them per family; the form gets a multi-line field (masked when secret) and the runbook a copy
    step after the render, only when the field is set and the host is of that family."""
    from bossman.services.wizard_seed import _with_files

    entry = {"families": {"debian": {"files": [{"path": "/var/lib/prometheus/.my.cnf", "field": "my_cnf",
                                                "mode": "0600", "owner": "prometheus", "secret": True}]}}}
    params: dict = {}
    steps = _with_files([{"module": "package"}, {"module": "config_template"}, {"module": "service"}], params, entry)
    assert [s.get("module") for s in steps] == ["package", "config_template", "copy", "service"]
    copy = steps[2]
    assert copy["args"] == {"dest": "/var/lib/prometheus/.my.cnf", "content": "{{ my_cnf }}", "mode": "0600",
                            "owner": "prometheus"}
    assert "_family == 'debian'" in copy["when"] and "my_cnf is defined" in copy["when"]
    assert params["my_cnf"]["widget"] == "text" and params["my_cnf"]["secret"] is True
    assert params["my_cnf"]["families"] == ["debian"]
