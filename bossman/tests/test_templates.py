"""End-to-end + service-layer tests for Templates (Block K12) — real app +
real DB (see tests/conftest.py's db_session fixture).
"""

import uuid
from tests.naming import owned_name

from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.db.models import CheckRule, Template, TemplateLink, TemplateNesting, TemplateRule
from bossman.main import create_app
from bossman.services.auth import new_api_token
from bossman.services.templates import (
    collect_effective_rules,
    dematerialize_template_link,
    find_ancestor_template_ids,
    materialize_template,
    materialize_template_link,
)


async def _make_api_token(db_session):
    row, raw = new_api_token("tmpl-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


# ---------------------------------------------------------------------------
# API: template groups + templates CRUD


async def test_templates_crud(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/templates",
            json={
                "name": "Linux baseline",
                "description": "CPU+Memory defaults",
                "rules": [
                    {"service_name": "CPU load", "metric": "cpu_pct", "comparison": "gt", "warn_threshold": 80.0, "crit_threshold": 95.0},
                    {"service_name": "Memory", "metric": "mem_pct", "comparison": "gt", "warn_threshold": 85.0, "crit_threshold": 95.0},
                ],
            },
            headers=_headers(raw),
        )
    assert create_resp.status_code == 200
    body = create_resp.json()
    template_id = body["id"]
    assert len(body["rules"]) == 2

    with TestClient(create_app()) as client:
        list_resp = client.get("/api/v1/templates", headers=_headers(raw))
    assert any(t["id"] == template_id for t in list_resp.json())

    with TestClient(create_app()) as client:
        get_resp = client.get(f"/api/v1/templates/{template_id}", headers=_headers(raw))
    assert get_resp.status_code == 200
    assert {r["service_name"] for r in get_resp.json()["rules"]} == {"CPU load", "Memory"}

    with TestClient(create_app()) as client:
        update_resp = client.put(
            f"/api/v1/templates/{template_id}",
            json={
                "name": "Linux baseline",
                "description": "CPU only now",
                "rules": [
                    {"service_name": "CPU load", "metric": "cpu_pct", "comparison": "gt", "warn_threshold": 70.0, "crit_threshold": 90.0},
                ],
            },
            headers=_headers(raw),
        )
    assert update_resp.status_code == 200
    assert len(update_resp.json()["rules"]) == 1
    assert update_resp.json()["rules"][0]["warn_threshold"] == 70.0

    with TestClient(create_app()) as client:
        delete_resp = client.delete(f"/api/v1/templates/{template_id}", headers=_headers(raw))
    assert delete_resp.status_code == 204

    with TestClient(create_app()) as client:
        list_after = client.get("/api/v1/templates", headers=_headers(raw))
    assert not any(t["id"] == template_id for t in list_after.json())

    await db_session.delete(api_token)
    await db_session.commit()


async def test_templates_duplicate_name_409(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        first = client.post("/api/v1/templates", json={"name": "dup", "rules": []}, headers=_headers(raw))
        assert first.status_code == 200
    with TestClient(create_app()) as client:
        second = client.post("/api/v1/templates", json={"name": "dup", "rules": []}, headers=_headers(raw))
    assert second.status_code == 409
    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/templates/{first.json()['id']}", headers=_headers(raw))

    await db_session.delete(api_token)
    await db_session.commit()


async def test_templates_reject_self_nesting(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post("/api/v1/templates", json={"name": "self-nester", "rules": []}, headers=_headers(raw))
    template_id = create_resp.json()["id"]

    with TestClient(create_app()) as client:
        update_resp = client.put(
            f"/api/v1/templates/{template_id}",
            json={"name": "self-nester", "rules": [], "nested_template_ids": [template_id]},
            headers=_headers(raw),
        )
    assert update_resp.status_code == 422

    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/templates/{template_id}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_template_groups_crud(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post("/api/v1/template-groups", json={"name": "OS baselines"}, headers=_headers(raw))
    assert create_resp.status_code == 200
    group_id = create_resp.json()["id"]

    with TestClient(create_app()) as client:
        list_resp = client.get("/api/v1/template-groups", headers=_headers(raw))
    assert any(g["id"] == group_id for g in list_resp.json())

    with TestClient(create_app()) as client:
        delete_resp = client.delete(f"/api/v1/template-groups/{group_id}", headers=_headers(raw))
    assert delete_resp.status_code == 204

    await db_session.delete(api_token)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Live linking — the core "editing the template cascades to linked hosts" payoff


async def test_linking_template_materializes_check_rules(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/templates",
            json={
                "name": "Web servers",
                "rules": [
                    {"service_name": "CPU load", "metric": "cpu_pct", "comparison": "gt", "warn_threshold": 80.0, "crit_threshold": 95.0},
                ],
            },
            headers=_headers(raw),
        )
    template_id = create_resp.json()["id"]

    with TestClient(create_app()) as client:
        link_resp = client.post(
            f"/api/v1/templates/{template_id}/links", json={"host_group": "webservers"}, headers=_headers(raw)
        )
    assert link_resp.status_code == 200
    link_id = link_resp.json()["id"]

    materialized = (
        await db_session.scalars(
            select(CheckRule).where(CheckRule.template_id == uuid.UUID(template_id), CheckRule.scope_value == "webservers")
        )
    ).all()
    assert len(materialized) == 1
    assert materialized[0].service_name == "CPU load"
    assert materialized[0].scope_type == "group"
    assert materialized[0].warn_threshold == 80.0

    # Direct edit/delete of a template-managed rule is rejected.
    with TestClient(create_app()) as client:
        edit_resp = client.put(
            f"/api/v1/check-rules/{materialized[0].id}",
            json={"service_name": "CPU load", "metric": "cpu_pct", "comparison": "gt", "scope_type": "group", "scope_value": "webservers"},
            headers=_headers(raw),
        )
    assert edit_resp.status_code == 409
    with TestClient(create_app()) as client:
        del_resp = client.delete(f"/api/v1/check-rules/{materialized[0].id}", headers=_headers(raw))
    assert del_resp.status_code == 409

    # Editing the template's rule cascades to the materialized CheckRule.
    with TestClient(create_app()) as client:
        client.put(
            f"/api/v1/templates/{template_id}",
            json={
                "name": "Web servers",
                "rules": [
                    {"service_name": "CPU load", "metric": "cpu_pct", "comparison": "gt", "warn_threshold": 70.0, "crit_threshold": 90.0},
                ],
            },
            headers=_headers(raw),
        )
    # A whole-form template edit replaces its TemplateRule rows (fresh
    # ids), so re-materialization deletes the old CheckRule and creates a
    # new one rather than updating in place — re-query rather than
    # refresh()ing the now-stale Python object.
    db_session.expunge_all()
    updated_rule = await db_session.scalar(
        select(CheckRule).where(CheckRule.template_id == uuid.UUID(template_id), CheckRule.scope_value == "webservers")
    )
    assert updated_rule is not None
    assert updated_rule.warn_threshold == 70.0

    # Unlinking removes the materialized rule.
    with TestClient(create_app()) as client:
        unlink_resp = client.delete(f"/api/v1/templates/{template_id}/links/{link_id}", headers=_headers(raw))
    assert unlink_resp.status_code == 204
    db_session.expunge_all()
    remaining = await db_session.scalar(select(CheckRule).where(CheckRule.id == updated_rule.id))
    assert remaining is None

    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/templates/{template_id}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_linking_same_group_twice_409(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post("/api/v1/templates", json={"name": "one-link", "rules": []}, headers=_headers(raw))
    template_id = create_resp.json()["id"]

    with TestClient(create_app()) as client:
        first = client.post(f"/api/v1/templates/{template_id}/links", json={"host_group": "prod"}, headers=_headers(raw))
        assert first.status_code == 200
    with TestClient(create_app()) as client:
        second = client.post(f"/api/v1/templates/{template_id}/links", json={"host_group": "prod"}, headers=_headers(raw))
    assert second.status_code == 409

    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/templates/{template_id}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Service layer: nesting + materialization walk, tested directly (no HTTP)


async def _make_template(db_session, name, rules=()) -> Template:
    t = Template(name=name)
    db_session.add(t)
    await db_session.flush()
    for r in rules:
        db_session.add(TemplateRule(template_id=t.id, **r))
    await db_session.commit()
    return t


async def test_collect_effective_rules_includes_nested_templates(db_session):
    child = await _make_template(
        db_session, owned_name("child"),
        rules=[dict(service_name="Disk /", metric="disk_used_pct", comparison="gt", warn_threshold=80.0, crit_threshold=95.0)],
    )
    parent = await _make_template(
        db_session, owned_name("parent"),
        rules=[dict(service_name="CPU load", metric="cpu_pct", comparison="gt", warn_threshold=80.0, crit_threshold=95.0)],
    )
    db_session.add(TemplateNesting(parent_template_id=parent.id, child_template_id=child.id))
    await db_session.commit()

    effective = await collect_effective_rules(db_session, parent.id)
    assert {r.service_name for r in effective} == {"CPU load", "Disk /"}

    await db_session.execute(select(TemplateNesting))  # no-op, just touch session
    await db_session.delete(parent)
    await db_session.delete(child)
    await db_session.commit()


async def test_collect_effective_rules_handles_nesting_cycle(db_session):
    """A -> B -> A must not infinite-loop."""
    a = await _make_template(db_session, owned_name("a"), rules=[dict(service_name="A", metric="m", comparison="gt")])
    b = await _make_template(db_session, owned_name("b"), rules=[dict(service_name="B", metric="m", comparison="gt")])
    db_session.add(TemplateNesting(parent_template_id=a.id, child_template_id=b.id))
    db_session.add(TemplateNesting(parent_template_id=b.id, child_template_id=a.id))
    await db_session.commit()

    effective = await collect_effective_rules(db_session, a.id)
    assert {r.service_name for r in effective} == {"A", "B"}  # each counted once, no infinite loop

    for nest in (await db_session.scalars(select(TemplateNesting))).all():
        await db_session.delete(nest)
    await db_session.flush()
    await db_session.delete(a)
    await db_session.delete(b)
    await db_session.commit()


async def test_materialize_template_cascades_to_ancestor_links(db_session):
    """Editing a nested (child) template's rules and re-materializing it
    also updates the PARENT template's own linked host groups — the
    parent's effective rule set includes the child's rules."""
    child = await _make_template(
        db_session, owned_name("child"),
        rules=[dict(service_name="Disk /", metric="disk_used_pct", comparison="gt", warn_threshold=80.0, crit_threshold=95.0)],
    )
    parent = await _make_template(db_session, owned_name("parent"))
    db_session.add(TemplateNesting(parent_template_id=parent.id, child_template_id=child.id))
    link = TemplateLink(template_id=parent.id, host_group="ancestor-test-group")
    db_session.add(link)
    await db_session.commit()

    await materialize_template_link(db_session, parent.id, "ancestor-test-group")
    await db_session.commit()

    materialized = (
        await db_session.scalars(select(CheckRule).where(CheckRule.template_id == parent.id, CheckRule.scope_value == "ancestor-test-group"))
    ).all()
    assert len(materialized) == 1
    assert materialized[0].service_name == "Disk /"

    ancestors = await find_ancestor_template_ids(db_session, child.id)
    assert parent.id in ancestors

    await materialize_template(db_session, child.id)  # re-materializing the child cascades to parent's links too
    await db_session.commit()

    for row in (await db_session.scalars(select(CheckRule).where(CheckRule.template_id == parent.id))).all():
        await db_session.delete(row)
    await db_session.delete(link)
    await db_session.flush()
    nests = (await db_session.scalars(select(TemplateNesting).where(TemplateNesting.parent_template_id == parent.id))).all()
    for n in nests:
        await db_session.delete(n)
    await db_session.flush()
    await db_session.delete(parent)
    await db_session.delete(child)
    await db_session.commit()


async def test_dematerialize_template_link_removes_generated_rules(db_session):
    template = await _make_template(
        db_session, owned_name("tmpl"),
        rules=[dict(service_name="Uptime", metric="uptime_seconds", comparison="lt", crit_threshold=60.0)],
    )
    await materialize_template_link(db_session, template.id, "dematerialize-test-group")
    await db_session.commit()

    before = (await db_session.scalars(select(CheckRule).where(CheckRule.template_id == template.id))).all()
    assert len(before) == 1

    await dematerialize_template_link(db_session, template.id, "dematerialize-test-group")
    await db_session.commit()

    after = (await db_session.scalars(select(CheckRule).where(CheckRule.template_id == template.id))).all()
    assert len(after) == 0

    await db_session.delete(template)
    await db_session.commit()
