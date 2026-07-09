"""The canonical prefix-keyed plan store (docs/zielbestimmung.md principle 4).
Pure conversion tests need no DB; store/load/version tests use the db_session
fixture (skips without a reachable database).
"""

import pytest
from sqlalchemy import select

from bossman.db.models import PlanDocument
from bossman.services.plan_loader import PlanError, build_plan_from_raw
from bossman.services.plan_store import canonical_from_source, list_plans, load_plan, store_plan

# All values are strings, so NestedText and YAML normalize to the SAME
# canonical body (and thus the same content_hash) — the format-equivalence
# case. (Where YAML uses real bools/ints, the bodies legitimately differ,
# which is the intended NestedText semantics.)
NT_PLAN = """\
name: eqdemo
description:
    > A demo.
steps:
    -
        name: make_dir
        ansible.builtin.file:
            path: /etc/demo
            state: directory
            mode: 0755
    -
        name: reload
        pipeline:
            -
                - systemctl
                - daemon-reload
"""

YAML_PLAN = """\
name: eqdemo
description: >
  A demo.
steps:
  - name: make_dir
    ansible.builtin.file:
      path: /etc/demo
      state: directory
      mode: "0755"
  - name: reload
    pipeline:
      - [systemctl, daemon-reload]
"""


def _version(source_format, text):
    body = canonical_from_source(source_format, text)
    return build_plan_from_raw(body, __import__("pathlib").Path("eqdemo")).version()


def test_canonical_from_source_accepts_nt_yaml_json():
    for fmt, text in (("nestedtext", NT_PLAN), ("yaml", YAML_PLAN)):
        body = canonical_from_source(fmt, text)
        assert body["name"] == "eqdemo"
        assert body["steps"][0]["name"] == "make_dir"
    # JSON round-trips the same structure.
    j = canonical_from_source("json", '{"name":"j","steps":[{"name":"s","ansible.builtin.file":{"path":"/x"}}]}')
    assert j["name"] == "j"


def test_string_valued_nt_and_yaml_are_content_identical():
    # Same plan, string-only values → identical canonical hash across formats.
    assert _version("nestedtext", NT_PLAN) == _version("yaml", YAML_PLAN)


def test_canonical_rejects_bad_input():
    with pytest.raises(PlanError):
        canonical_from_source("nestedtext", "- just\n- a list\n")
    with pytest.raises(PlanError):
        canonical_from_source("json", "{not json")
    with pytest.raises(PlanError, match="unsupported source_format"):
        canonical_from_source("toml", "x = 1")
    with pytest.raises(PlanError, match="missing required 'name'"):
        canonical_from_source("yaml", "steps: []\n")


async def _cleanup(db_session, prefix, name):
    for row in (await db_session.scalars(select(PlanDocument).where(PlanDocument.prefix == prefix, PlanDocument.name == name))).all():
        await db_session.delete(row)
    await db_session.flush()


async def test_store_and_load_roundtrip(db_session):
    await store_plan(db_session, "ansible", "eqdemo", "nestedtext", NT_PLAN)
    plan = await load_plan(db_session, "ansible", "eqdemo")
    assert plan.name == "eqdemo"
    assert [c.name for c in plan.chunks] == ["main"]
    steps = plan.chunks[0].steps
    assert [s.name for s in steps] == ["make_dir", "reload"]
    assert steps[0].module == "file"
    assert steps[0].body["mode"] == "0755"
    assert steps[1].kind == "pipeline"
    await _cleanup(db_session, "ansible", "eqdemo")


async def test_restore_same_content_is_idempotent(db_session):
    d1 = await store_plan(db_session, "ansible", "idem", "nestedtext", NT_PLAN)
    d2 = await store_plan(db_session, "ansible", "idem", "nestedtext", NT_PLAN)
    assert d1.id == d2.id and d2.version == 1
    rows = (await db_session.scalars(select(PlanDocument).where(PlanDocument.name == "idem"))).all()
    assert len(rows) == 1
    await _cleanup(db_session, "ansible", "idem")


async def test_changed_content_bumps_version(db_session):
    await store_plan(db_session, "ansible", "ver", "nestedtext", NT_PLAN)
    changed = NT_PLAN.replace("/etc/demo", "/etc/demo2")
    d2 = await store_plan(db_session, "ansible", "ver", "nestedtext", changed)
    assert d2.version == 2
    # load newest vs a specific version
    newest = await load_plan(db_session, "ansible", "ver")
    v1 = await load_plan(db_session, "ansible", "ver", version=1)
    assert newest.chunks[0].steps[0].body["path"] == "/etc/demo2"
    assert v1.chunks[0].steps[0].body["path"] == "/etc/demo"
    await _cleanup(db_session, "ansible", "ver")


async def test_invalid_prefix_rejected(db_session):
    with pytest.raises(PlanError, match="invalid prefix"):
        await store_plan(db_session, "terraform", "x", "nestedtext", NT_PLAN)


async def test_list_plans_returns_latest_per_name(db_session):
    await store_plan(db_session, "ansible", "listed", "nestedtext", NT_PLAN)
    await store_plan(db_session, "ansible", "listed", "nestedtext", NT_PLAN.replace("/etc/demo", "/etc/demo9"))
    entries = [e for e in await list_plans(db_session, prefix="ansible") if e["name"] == "listed"]
    assert len(entries) == 1 and entries[0]["version"] == 2
    await _cleanup(db_session, "ansible", "listed")
