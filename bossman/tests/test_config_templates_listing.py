"""GET /api/v1/config-templates — the listing carries no bodies.

Called as a function rather than through TestClient: the endpoint's only input is a directory, and going
through the app would need a DB and a token to test a `for` loop over `iterdir()`.

WHY THIS IS PINNED. It used to return every template's j2 body, schema and sample. Against the real catalog
that is a 36 MB JSON document assembled on every call, and it stayed that way because each caller looked
correct on its own — seven package snapins fetched the whole catalog to `.find()` one hard-coded name. A body
creeping back into this reply would not fail anything visibly; it would just make one request cost 36 MB
again. So the absence of bodies is the assertion.
"""

from types import SimpleNamespace

from bossman.api.config_templates import get_config_template, list_config_templates

import pytest
from fastapi import HTTPException


def _catalog(tmp_path, templates: dict[str, dict]):
    """templates = {name: {"template.j2": ..., "meta.json": ...}} — files written verbatim."""
    root = tmp_path / "config_templates"
    root.mkdir()
    for name, files in templates.items():
        d = root / name
        d.mkdir()
        for fname, body in files.items():
            (d / fname).write_text(body)
    return SimpleNamespace(config_templates_dir=str(root))


async def test_listing_carries_names_and_targets_but_no_bodies(tmp_path):
    settings = _catalog(tmp_path, {
        "nginx": {"template.j2": "worker_processes {{ n }};\n",
                  "schema.json": '{"n": {"type": "int"}}',
                  "meta.json": '{"target_path": "/etc/nginx/nginx.conf", "source": "deb"}'},
        "bind9": {"template.j2": "options {};\n",
                  "meta.json": '{"target_path": "/etc/bind/named.conf", "source": "man"}'},
    })
    out = await list_config_templates(settings)
    assert [t["name"] for t in out["templates"]] == ["bind9", "nginx"]
    for entry in out["templates"]:
        assert "template" not in entry, f"{entry['name']} carries its body in the listing"
        assert "schema" not in entry, f"{entry['name']} carries its schema in the listing"
    by_name = {t["name"]: t for t in out["templates"]}
    # target_path is what makes the listing usable for choosing: a name alone does not say which file it
    # renders, and the name is frequently not the filename (template `aardvark_dns` renders forward.conf).
    assert by_name["nginx"]["target_path"] == "/etc/nginx/nginx.conf"
    assert by_name["bind9"]["source"] == "man"


async def test_a_directory_without_a_body_is_not_a_template(tmp_path):
    """5474 directories exist and not all of them hold a template.j2. A row for one would be a name the
    detail request cannot answer — offered, then 404."""
    settings = _catalog(tmp_path, {
        "nginx": {"template.j2": "worker_processes 4;\n"},
        "leftover": {"schema.json": "{}"},
    })
    out = await list_config_templates(settings)
    assert [t["name"] for t in out["templates"]] == ["nginx"]


async def test_unparsable_meta_costs_the_target_not_the_entry(tmp_path):
    """A broken meta.json must not remove the template from the listing: the body is still there and still
    editable. Losing the row would hide a working template because of a file that only annotates it."""
    settings = _catalog(tmp_path, {
        "nginx": {"template.j2": "worker_processes 4;\n", "meta.json": "{not json"},
    })
    out = await list_config_templates(settings)
    assert [t["name"] for t in out["templates"]] == ["nginx"]
    assert out["templates"][0]["target_path"] is None


async def test_the_body_comes_from_the_per_name_route(tmp_path):
    settings = _catalog(tmp_path, {
        "nginx": {"template.j2": "worker_processes {{ n }};\n", "schema.json": '{"n": {"type": "int"}}',
                  "sample.json": '{"n": 4}'},
    })
    got = await get_config_template("nginx", settings)
    assert "worker_processes" in got["template"]
    assert got["schema"]["n"]["type"] == "int"
    assert got["sample"] == {"n": 4}

    with pytest.raises(HTTPException) as absent:
        await get_config_template("doesnotexist", settings)
    assert absent.value.status_code == 404
