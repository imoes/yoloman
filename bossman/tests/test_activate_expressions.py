"""activate_expressions: a commented setting with any expression becomes live when set, the shipped line when not."""

import jinja2

from bossman.tools.activate_commented_settings import activate_expressions, present

SHIPPED = "# Settings\n#DSHELL=/bin/bash\n# conf_x=YES\n# Only one of conf_x and conf_y should be set.\n# conf_y=YES\n"
BODY = ("# Settings\n#DSHELL={{ dshell | default('/bin/bash') }}\n# conf_x=YES\n"
        "# Only one of conf_x and conf_y should be set.\n# conf_y={{ conf_y }}\n")


def render(body, **values):
    return jinja2.Environment(keep_trailing_newline=True).from_string(body).render(**values)


def test_unset_renders_the_shipped_file():
    body, activated, left = activate_expressions(BODY, SHIPPED, {"dshell": {}, "conf_y": {}, "conf_x": {}})
    assert activated == {"dshell", "conf_y", "conf_x"} and not left
    assert render(body) == SHIPPED


def test_set_values_become_live_lines():
    body, _, _ = activate_expressions(BODY, SHIPPED, {"dshell": {}, "conf_y": {}, "conf_x": {}})
    out = render(body, dshell="/bin/zsh", conf_x="NO")
    assert "\nDSHELL=/bin/zsh\n" in out and "\nconf_x=NO\n" in out and "# conf_y=YES" in out


def test_empty_list_is_unset_and_zero_is_a_value():
    env = jinja2.Environment()
    guard = "{% if " + present("v") + " %}T{% else %}F{% endif %}"
    assert env.from_string(guard).render(v=[]) == "F"
    assert env.from_string(guard).render(v="") == "F"
    assert env.from_string(guard).render(v=0) == "T"
    assert env.from_string(guard).render(v=False) == "T"


def test_the_repair_chain_activates_and_keeps_the_shipped_file(tmp_path):
    import json

    from bossman.tools.template_repair_chain import repair_template

    (tmp_path / "template.j2").write_text("#DSHELL={{ dshell | default('/bin/bash') }}\n")
    (tmp_path / "schema.json").write_text(json.dumps({"dshell": {"type": "string", "default": "/bin/bash"}}))
    report = repair_template(tmp_path, "#DSHELL=/bin/bash\n")
    assert report["expressions_activated"] == 1
    schema = json.loads((tmp_path / "schema.json").read_text())
    assert schema["dshell"]["default"] is None
    body = (tmp_path / "template.j2").read_text()
    assert render(body) == "#DSHELL=/bin/bash\n" and render(body, dshell="/bin/zsh") == "DSHELL=/bin/zsh\n"


def test_an_escaped_literal_is_not_a_placeholder():
    body, activated, left = activate_expressions("#Format={{ '{{' }}date{{ '}}' }}\n", "#Format={{date}}\n", {})
    assert not activated and left == ["#Format={{ '{{' }}date{{ '}}' }}"]
