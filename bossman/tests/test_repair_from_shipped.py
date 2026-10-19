"""The repair chain on a model template that switched commented examples on (barman's shape), and the driver's
keep-only-what-helps rule."""

import json

from bossman.tools.activate_commented_settings import deactivate_model_activations
from bossman.tools.repair_from_shipped import better
from bossman.tools.template_repair_chain import repair_template

SHIPPED = "[barman]\n; Default compression\n;compression = gzip\n;parallel_jobs = 1\nlog_level = INFO\n"


def test_a_filtered_activation_is_put_back_behind_its_comment():
    body = "compression = {{ compression | default('none') }}\n"
    got, n = deactivate_model_activations(body, SHIPPED, vars_out := [])
    assert n == 1 and vars_out == ["compression"]
    assert ";compression = gzip" in got and "compression is defined" in got


def test_the_chain_makes_the_defaults_render_the_shipped_file(tmp_path):
    import jinja2

    t = tmp_path / "barman"
    t.mkdir()
    (t / "template.j2").write_text("[barman]\n; Default compression\ncompression = {{ compression | default('none') }}\n"
                                   "parallel_jobs = {{ parallel_jobs | default(1) }}\nlog_level = {{ log_level }}\n")
    (t / "schema.json").write_text(json.dumps({"compression": {"type": "string", "default": "none"},
                                               "parallel_jobs": {"type": "number", "default": 1},
                                               "log_level": {"type": "string", "default": "INFO"}}))
    repair_template(t, SHIPPED)
    schema = json.loads((t / "schema.json").read_text())
    defaults = {k: v["default"] for k, v in schema.items() if v.get("default") is not None}
    assert jinja2.Template((t / "template.j2").read_text(), keep_trailing_newline=True).render(**defaults) == SHIPPED
    assert "compression = bzip2" in jinja2.Template((t / "template.j2").read_text()).render(**defaults, compression="bzip2")


def test_keep_only_what_helps():
    d = lambda v, r=0, s=0: {"verdict": v, "counts": {"only_in_render": r, "only_in_shipped": s}}
    assert better(d("differs", 3, 0), d("same-settings"))
    assert better(d("differs", 3, 2), d("differs", 1, 0))
    assert not better(d("differs", 1, 0), d("differs", 1, 0))
    assert not better(d("same-settings"), d("differs", 1, 0))


def test_a_glued_one_line_block_is_split_only_when_both_halves_are_shipped():
    from bossman.tools.template_repair_chain import split_merged_blocks

    glued = "{% if p is defined %}parallel_jobs = {{ p }}{% else %};parallel_jobs = 1{% endif %}log_level = {{ l }}"
    out, n = split_merged_blocks(glued, SHIPPED)
    assert n == 1 and out.endswith("{% endif %}\nlog_level = {{ l }}")
    inline = "server a{% if c %} check{% else %} nocheck{% endif %} weight 1"   # inline by design: not shipped halves
    assert split_merged_blocks(inline, SHIPPED) == (inline, 0)


def test_an_inline_default_of_an_undeclared_field_comes_from_the_shipped_line():
    from bossman.tools.template_repair_chain import align_inline_defaults

    body = "dump inter = {{ scan_interval | default(30) }}\nlog = {{ lf | default('/tmp/x') }}\n"
    shipped = "# arpalert\ndump inter = 5\nlog = /var/log/arpalert.log\n"
    out, n = align_inline_defaults(body, {}, shipped)
    assert n == 2 and "default(5)" in out and "default('/var/log/arpalert.log')" in out
    # a field with a schema default is align's business, not this step's
    assert align_inline_defaults(body, {"scan_interval": {"default": 7}}, shipped)[1] == 1


def test_a_comment_about_a_loop_item_is_never_switched_on():
    """postfix: `# TLS setting: {{ key }}` inside `{% for key, value in tls | dictsort %}` was activated as a
    setting (the loop runs zero times with defaults, so stage 5 could not see it) and postfix refused main.cf."""
    from bossman.tools.activate_commented_settings import activate_expressions, deactivate_model_activations

    body = ("{% for key, value in tls | dictsort %}\n# TLS setting: {{ key }}\n{{ key }} = {{ value }}\n{% endfor %}\n"
            "# myhostname = {{ hostname }}\n")
    shipped = "# TLS CONFIGURATION\n#myhostname = host.domain.tld\n"
    out, activated, _ = activate_expressions(body, shipped, {"hostname": {"type": "string"}, "tls": {"type": "object"}})
    assert "# TLS setting: {{ key }}" in out and "key" not in activated
    out2, n = deactivate_model_activations("{% for ns in servers %}\nnameserver {{ ns | default('x') }}\n{% endfor %}",
                                           "#nameserver 1.1.1.1\n", [], {"servers": {}})
    assert n == 0


def test_a_family_template_built_from_the_shipped_file_takes_the_roles_field_names():
    """G5: postfix-redhat built from the RPM's main.cf names `myhostname` like the role does (`hostname`), anchors a
    directive the role asks for at its first commented example, fields the one ACTIVE line of a directive with
    commented examples, and leaves loop items and prose alone. Defaults still render the shipped file."""
    import jinja2

    from bossman.tools.template_from_shipped import build, role_names

    role = ("{% if hostname is defined %}myhostname = {{ hostname }}{% else %}#myhostname = x{% endif %}\n"
            "inet_interfaces = {{ inet_interfaces | default('all') }}\n"
            "{% for key, value in tls | dictsort %}\n# TLS setting: {{ key }}\n{% endfor %}\n")
    names = role_names(role)
    assert names == {"myhostname": "hostname", "inet_interfaces": "inet_interfaces"}
    shipped = ("# The myhostname parameter specifies the host name\n#myhostname = host.domain.tld\n"
               "#myhostname = virtual.domain.tld\n#inet_interfaces = all\ninet_interfaces = localhost\n")
    body, schema = build(shipped, names=names, role_schema={"hostname": {"type": "string", "description": "FQDN"}})
    assert set(schema) == {"hostname", "inet_interfaces"} and schema["inet_interfaces"]["default"] == "localhost"
    assert schema["hostname"]["description"].startswith("FQDN") and schema["hostname"]["default"] is None
    defaults = {k: v["default"] for k, v in schema.items() if v.get("default") is not None}
    assert jinja2.Template(body, keep_trailing_newline=True).render(**defaults) == shipped
    assert "myhostname = mx.example.org" in jinja2.Template(body).render(**defaults, hostname="mx.example.org")


def test_a_repair_that_worsens_another_unit_of_the_same_template_is_not_kept(tmp_path, monkeypatch):
    """c-icap (and 16 others) is bound on both families; repaired against the EL file it got worse for Debian."""
    from bossman.tools import repair_from_shipped as R

    t = tmp_path / "x"
    t.mkdir()
    (t / "template.j2").write_text("a = {{ a | default('1') }}\n")
    (t / "schema.json").write_text(json.dumps({}))
    monkeypatch.setattr(R.F, "TEMPLATES", tmp_path)
    texts = {"redhat": "#a = 2\n", "debian": "a = 1\n"}
    monkeypatch.setattr(R, "shipped_text", lambda u: texts[u["family"]])
    unit = {"template": "x", "family": "redhat", "path": "/etc/x", "package": "x", "verdict": "differs",
            "counts": {"only_in_render": 1, "only_in_shipped": 0}}
    sib = {"template": "x", "family": "debian", "path": "/etc/x", "package": "x", "verdict": "identical"}
    alone = R.repair_one(unit, write=False)
    with_sib = R.repair_one(unit, write=False, siblings=[sib])
    assert alone["kept"] is True
    assert with_sib["kept"] is False and "debian unit" in with_sib["why"]


def test_the_builder_keeps_the_files_own_braces_continuations_and_reserved_words_out_of_the_engine():
    """php-fpm's `%{%Y-%m-%d}t`, exim's line continuations and collectd's `Include`/`In` directives each broke a
    template built from the shipped file."""
    import jinja2

    from bossman.tools.template_from_shipped import build

    shipped = ("access.format = \"%{%Y-%m-%dT%H:%M:%S%z}t\"\nlog_selector = +a \\\n  +b\nInclude \"/etc/x.d\"\n"
               "In 1\nmode = fast\n")
    body, schema = build(shipped)
    assert "log_selector" not in schema and "include_directive" in schema and "in_directive" in schema
    defaults = {k: v["default"] for k, v in schema.items() if v.get("default") is not None}
    assert jinja2.Template(body, keep_trailing_newline=True).render(**defaults) == shipped


def test_a_path_directive_set_to_no_is_not_a_switch():
    from bossman.tools.template_from_shipped import build

    _body, schema = build("html_directory = no\nUseSendfile off\n")
    assert "enum" not in schema["html_directory"]
    assert schema["use_sendfile"]["enum"] == ["on", "off"]


def test_an_inline_default_and_the_same_schema_guess_both_take_the_shipped_value():
    from bossman.tools.template_repair_chain import align_inline_defaults

    schema = {"scan_interval": {"type": "number", "default": 30}}
    out, n = align_inline_defaults("dump inter = {{ scan_interval | default(30) }}", schema, "dump inter = 5\n")
    assert n == 1 and "default(5)" in out and schema["scan_interval"]["default"] == 5
    other = {"scan_interval": {"type": "number", "default": 10}}       # a deliberate schema default: not touched
    assert align_inline_defaults("dump inter = {{ scan_interval | default(30) }}", other, "dump inter = 5\n")[1] == 0


def test_the_qualify_batch_leaves_catalog_and_repaired_templates_alone(tmp_path, monkeypatch):
    """The 2026-10-14 Debian worklist pass regenerated 17 fixed templates (charon-systemd stopped rendering again,
    flim and xrdp.ini are catalog roles). A catalog role's template and a verified repair are curated."""
    import json as _json

    from bossman.tools import qualify_packages as Q

    tdir = tmp_path / "config_templates"
    for name, meta in (("x-repaired", {"repaired": "2026-10-14"}), ("x-plain", {"source": "qualify"})):
        (tdir / name).mkdir(parents=True)
        (tdir / name / "meta.json").write_text(_json.dumps(meta))
    monkeypatch.setattr(Q, "TEMPLATES_DIR", tdir)
    monkeypatch.setattr(Q, "_CATALOG_TEMPLATES", {"x-role"})
    assert Q._curated("x-repaired") and Q._curated("x-role")
    assert not Q._curated("x-plain")
