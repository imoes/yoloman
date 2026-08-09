"""Unit tests for bossman.services.catalog.CatalogCache — no DB, no
network (plans are parsed straight from a tmp_path directory). The
behavioral proof that matters here: editing a plan file on disk does
*not* change what the cache returns until reload() runs — that's the
entire point of this cache existing (see docs/plan.md's chunked-plan-
caching refinement: every consumer used to re-parse every plan file on
every single call).
"""

from bossman.services.catalog import CatalogCache

PLAN_A = """
name: plan_a
description: "first plan"
params:
  message: { type: string, required: true, pattern: '^[a-z]+$' }
steps:
  - name: s
    copy:
      dest: /etc/motd
      content: "{{ message }}"
"""

PLAN_B = """
name: plan_b
description: "second plan"
steps:
  - name: s
    file:
      path: /tmp/x
      state: touch
"""


def test_construction_parses_plans_once(tmp_path):
    (tmp_path / "a.yaml").write_text(PLAN_A)
    cache = CatalogCache(str(tmp_path))

    assert [p.name for p in cache.plans] == ["plan_a"]


def test_get_returns_plan_by_name_or_none(tmp_path):
    (tmp_path / "a.yaml").write_text(PLAN_A)
    cache = CatalogCache(str(tmp_path))

    assert cache.get("plan_a") is not None
    assert cache.get("plan_a").name == "plan_a"
    assert cache.get("nonexistent") is None


def test_list_json_shape_matches_mcp_list_plans_contract(tmp_path):
    (tmp_path / "a.yaml").write_text(PLAN_A)
    cache = CatalogCache(str(tmp_path))

    assert cache.list_json == [
        {
            "name": "plan_a",
            "description": "first plan",
            "params": {"message": {"type": "string", "required": True, "default": None}},
        }
    ]


def test_catalog_markdown_matches_render_catalog_markdown(tmp_path):
    (tmp_path / "a.yaml").write_text(PLAN_A)
    cache = CatalogCache(str(tmp_path))

    assert "plan_a" in cache.catalog_markdown
    assert "message" in cache.catalog_markdown


def test_disk_change_invisible_until_reload(tmp_path):
    """The core caching proof: adding, removing, or editing a plan file on
    disk must not affect .plans/.get()/.list_json/.catalog_markdown until
    reload() is called."""
    (tmp_path / "a.yaml").write_text(PLAN_A)
    cache = CatalogCache(str(tmp_path))

    before_plans = [p.name for p in cache.plans]
    before_json = cache.list_json
    before_markdown = cache.catalog_markdown

    (tmp_path / "b.yaml").write_text(PLAN_B)  # a new plan appears on disk

    assert [p.name for p in cache.plans] == before_plans
    assert cache.list_json == before_json
    assert cache.catalog_markdown == before_markdown
    assert cache.get("plan_b") is None

    cache.reload()

    assert sorted(p.name for p in cache.plans) == ["plan_a", "plan_b"]
    assert cache.get("plan_b") is not None
    assert "plan_b" in cache.catalog_markdown


def test_reload_returns_the_new_catalog_markdown(tmp_path):
    (tmp_path / "a.yaml").write_text(PLAN_A)
    cache = CatalogCache(str(tmp_path))

    (tmp_path / "b.yaml").write_text(PLAN_B)
    returned = cache.reload()

    assert returned == cache.catalog_markdown
    assert "plan_b" in returned


def test_empty_plans_dir():
    cache = CatalogCache("/nonexistent/plans/dir")

    assert cache.plans == []
    assert cache.list_json == []
    assert "No plans are currently available" in cache.catalog_markdown
    assert cache.get("anything") is None
