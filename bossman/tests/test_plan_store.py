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
        file:
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
    file:
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
    j = canonical_from_source("json", '{"name":"j","steps":[{"name":"s","file":{"path":"/x"}}]}')
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


# ── Bulk / directory import (docs/foreign-dsl-import.md) ───────────────────────────────────────────
#
# The rules below were shaped by four REAL upstream checkouts (geerlingguy/ansible-role-nginx,
# saltstack-formulas/apache-formula, puppetlabs-apache, sous-chefs/nginx — 721 files). A directory import is
# mostly NOT plans, and an extension-only rule misclassifies badly: lib/puppet/functions/*.rb reads as Chef,
# kitchen.yml/pdk.yaml/hiera.yaml read as Ansible playbooks, test/**/*_spec.rb reads as Chef. Hence positive
# rules keyed on the directory where each framework keeps executable code.


def test_detection_only_picks_each_framework_s_own_code():
    from bossman.services.plan_store import detect_plan_format

    picks = {
        "role/tasks/main.yml": ("ansible", "yaml"),
        "role/handlers/main.yml": ("ansible", "yaml"),
        "playbooks/site.yml": ("ansible", "yaml"),
        "apache/init.sls": ("salt", "salt"),
        "manifests/vhost.pp": ("puppet", "puppet"),
        "cookbook/recipes/default.rb": ("chef", "chef"),
        "cookbook/resources/config.rb": ("chef", "chef"),
    }
    for path, want in picks.items():
        assert detect_plan_format(path) == want, path

    # …and skips everything a real checkout carries alongside it
    for path in (
        "role/meta/main.yml", "role/defaults/main.yml", "role/vars/main.yml",
        "role/templates/nginx.conf.j2", "kitchen.yml", "hiera.yaml", "pdk.yaml", ".kitchen.yml",
        "lib/puppet/functions/apache_pw_hash.rb",      # PUPPET ruby, not a Chef recipe
        "spec/unit/foo_spec.rb", "test/integration/controls/packages_spec.rb",   # tests
        "test/salt/pillar/default.sls",                # pillar DATA, not a state
        "types/loglevel.pp",                           # a data type, not a manifest
        "README.md", "metadata.rb", "Berksfile",
    ):
        assert detect_plan_format(path) is None, path


def test_plan_names_are_unique_by_construction():
    """A collision silently OVERWRITES a plan, and real trees collide: apache-formula has apache/clean.sls
    AND apache/config/certificates/clean.sls; an Ansible role has tasks/main.yml AND handlers/main.yml."""
    from bossman.services.plan_store import plan_name_from_path

    names = [
        plan_name_from_path("apache/clean.sls"),
        plan_name_from_path("apache/config/certificates/clean.sls"),
        plan_name_from_path("role/tasks/main.yml"),
        plan_name_from_path("role/handlers/main.yml"),
    ]
    assert len(set(names)) == len(names), names


def test_a_bare_task_list_imports_as_a_plan():
    """roles/*/tasks/main.yml is a bare LIST, which is the most common import there is — and it is not a plan
    mapping, so it used to be rejected with 'plan must be a mapping'."""
    from bossman.services.plan_store import canonical_from_source

    body = canonical_from_source("yaml", "- name: install\n  apt:\n    name: nginx\n", name="nginx-tasks")
    assert body["name"] == "nginx-tasks"
    # A plan step is module-as-key (see plan_loader), the same shape an Ansible task has — so the list needs
    # no translation, only the plan envelope. (The RUNBOOK canonical doc differs: {module, args}.)
    assert body["steps"][0]["apt"] == {"name": "nginx"}


def test_notify_in_a_plan_fails_loudly_rather_than_being_swallowed():
    """A known gap, pinned deliberately: the PLAN schema (plan_loader._STEP_META_KEYS) does not know
    `notify`, so a task carrying one is refused. Accepting a keyword the plan engine then ignores would be
    worse — the document would promise a handler that never runs. Real Ansible roles use notify heavily, so
    importing them needs handler support in the plan engine; until then the error must stay visible.

    (The RUNBOOK path DOES accept it, including Ansible's scalar shorthand — see nt_runbook._str_list.)
    """
    import pytest

    from bossman.services.plan_store import PlanError, canonical_from_source

    with pytest.raises(PlanError) as exc:
        canonical_from_source(
            "yaml", "- name: drop config\n  copy:\n    dest: /etc/x\n  notify: restart nginx\n", name="t")
    assert "notify" in str(exc.value)
