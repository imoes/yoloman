"""The stage-5 comparison: byte-identical, same settings with other comments/spacing, or different settings."""

from bossman.tools.template_shipped_fidelity import compare, units


def test_identical_only_when_byte_equal():
    assert compare("a = 1\n", "a = 1\n")["verdict"] == "identical"
    assert compare("a = 1\n", "a = 1")["verdict"] == "same-settings"


def test_comments_and_spacing_do_not_count_as_settings():
    shipped = "# the port\nport   8080\n\n; old\nname = x\n"
    rendered = "port 8080\nname = x\n"
    assert compare(rendered, shipped)["verdict"] == "same-settings"


def test_a_turned_on_example_differs_and_is_named():
    shipped = "port 8080\n#debug yes\n"
    rendered = "port 8080\ndebug yes\n"
    out = compare(rendered, shipped)
    assert out["verdict"] == "differs"
    assert out["only_in_render"] == ["debug yes"] and out["only_in_shipped"] == []


def test_a_repeated_line_is_counted_not_deduplicated():
    assert compare("acl a\nacl a\n", "acl a\n")["verdict"] == "differs"


def test_every_reachable_template_is_a_unit():
    """Nothing reachable vanishes from the measurement: a template without a concrete file is a no-target unit."""
    import runpy
    from pathlib import Path

    from bossman.tools import qualify_packages as Q

    stage = runpy.run_path(str(Q._CONFIGS.parent / "scripts" / "stage-agent-templates.py"), run_name="t")
    bound, referenced = stage["referenced_templates"]()
    on_disk = {p.name for p in Q.TEMPLATES_DIR.iterdir() if (p / "template.j2").is_file()}
    assert {u["template"] for u in units()} == (bound | referenced) & on_disk
