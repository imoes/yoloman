"""End-to-end REST tests for the Policy/Orchestration layer (Block L1) —
OU tree, host groups, orchestration plans/versions/links, and the compiled
desired-state read. Real app + real DB, same pattern as
tests/test_agents_api.py / tests/test_templates.py: TestClient writes
commit through a separate session than the db_session fixture, so created
rows are cleaned up explicitly rather than relying on the fixture's
rollback.
"""

import uuid
from tests.naming import owned_name, run_suffix

from fastapi.testclient import TestClient

from tests.metric_helpers import purge_metrics, write_metric
from bossman.db.models import Agent
from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {"name": owned_name("orch-agent"), "token": "tok", "mode": "standalone", "enrollment_state": "enrolled"}
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_api_token(db_session, name="orch-caller"):
    row, raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _delete_agent(db_session, agent):
    got = await db_session.get(Agent, agent.id)
    if got is not None:
        await db_session.delete(got)
    await db_session.commit()


# ---------------------------------------------------------------------------
# OU tree


async def test_ou_crud_and_ancestry(db_session):
    api_token, raw = await _make_api_token(db_session)
    sfx = run_suffix()

    with TestClient(create_app()) as client:
        root = client.post("/api/v1/ou", json={"name": f"Germany-{sfx}"}, headers=_headers(raw))
    assert root.status_code == 200
    root_id = root.json()["id"]
    assert root.json()["path"] == f"/Germany-{sfx}"

    with TestClient(create_app()) as client:
        child = client.post("/api/v1/ou", json={"name": "Munich", "parent_id": root_id}, headers=_headers(raw))
    assert child.status_code == 200
    child_id = child.json()["id"]
    assert child.json()["path"] == f"/Germany-{sfx}/Munich"

    with TestClient(create_app()) as client:
        ancestry = client.get(f"/api/v1/ou/{child_id}/ancestry", headers=_headers(raw))
    assert [n["id"] for n in ancestry.json()] == [root_id, child_id]

    with TestClient(create_app()) as client:
        listed = client.get("/api/v1/ou", headers=_headers(raw))
    assert {n["id"] for n in listed.json()} >= {root_id, child_id}

    # Can't delete a parent with children.
    with TestClient(create_app()) as client:
        blocked = client.delete(f"/api/v1/ou/{root_id}", headers=_headers(raw))
    assert blocked.status_code == 409

    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/ou/{child_id}", headers=_headers(raw))
        final = client.delete(f"/api/v1/ou/{root_id}", headers=_headers(raw))
    assert final.status_code == 204

    await db_session.delete(api_token)
    await db_session.commit()


async def test_assign_agent_ou(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = await _make_agent(db_session)

    with TestClient(create_app()) as client:
        ou = client.post("/api/v1/ou", json={"name": owned_name("assign-ou")}, headers=_headers(raw))
    ou_id = ou.json()["id"]

    with TestClient(create_app()) as client:
        resp = client.put(f"/api/v1/agents/{agent.id}/ou", json={"ou_id": ou_id}, headers=_headers(raw))
    assert resp.status_code == 200
    assert resp.json()["id"] == ou_id

    with TestClient(create_app()) as client:
        unassign = client.put(f"/api/v1/agents/{agent.id}/ou", json={"ou_id": None}, headers=_headers(raw))
    assert unassign.status_code == 200
    assert unassign.json() is None

    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/ou/{ou_id}", headers=_headers(raw))
    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Host groups + membership


async def test_host_group_crud_and_membership(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = await _make_agent(db_session)
    sfx = run_suffix()

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/host-groups", json={"name": f"webservers-{sfx}", "description": "web"}, headers=_headers(raw)
        )
    assert create_resp.status_code == 200
    group_id = create_resp.json()["id"]
    assert create_resp.json()["member_agent_ids"] == []

    with TestClient(create_app()) as client:
        dup = client.post("/api/v1/host-groups", json={"name": f"webservers-{sfx}"}, headers=_headers(raw))
    assert dup.status_code == 409

    with TestClient(create_app()) as client:
        members = client.put(
            f"/api/v1/host-groups/{group_id}/members", json={"agent_ids": [str(agent.id)]}, headers=_headers(raw)
        )
    assert members.status_code == 200
    assert members.json()["member_agent_ids"] == [str(agent.id)]

    with TestClient(create_app()) as client:
        cleared = client.put(f"/api/v1/host-groups/{group_id}/members", json={"agent_ids": []}, headers=_headers(raw))
    assert cleared.json()["member_agent_ids"] == []

    with TestClient(create_app()) as client:
        delete_resp = client.delete(f"/api/v1/host-groups/{group_id}", headers=_headers(raw))
    assert delete_resp.status_code == 204

    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Orchestration plans + versions + links + desired-state


async def test_orchestration_plan_full_lifecycle(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = await _make_agent(db_session)
    sfx = run_suffix()

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/orchestration/plans",
            json={
                "name": f"docker_host-{sfx}",
                "display_name": "Docker Host",
                "plan_type": "role",
                "version": {"generated_monitoring": {"checks": ["docker_daemon"], "thresholds": {}}},
            },
            headers=_headers(raw),
        )
    assert create_resp.status_code == 200
    plan = create_resp.json()
    assert plan["current_version"] == 1
    assert len(plan["versions"]) == 1

    with TestClient(create_app()) as client:
        dup = client.post(
            "/api/v1/orchestration/plans",
            json={"name": f"docker_host-{sfx}", "display_name": "x", "plan_type": "role"},
            headers=_headers(raw),
        )
    assert dup.status_code == 409

    with TestClient(create_app()) as client:
        bad_type = client.post(
            "/api/v1/orchestration/plans",
            json={"name": f"bad-{sfx}", "display_name": "x", "plan_type": "not-a-type"},
            headers=_headers(raw),
        )
    assert bad_type.status_code == 422

    # Link the plan directly to the host. auto_apply=True so this test
    # exercises compile mechanics directly rather than the L2 approval gate
    # (see test_orchestration_link_approval_gate for that).
    with TestClient(create_app()) as client:
        link_resp = client.post(
            f"/api/v1/orchestration/plans/{plan['id']}/links",
            json={"target_type": "host", "agent_id": str(agent.id), "auto_apply": True},
            headers=_headers(raw),
        )
    assert link_resp.status_code == 200
    assert link_resp.json()["status"] == "active"
    link_id = link_resp.json()["id"]

    # Desired state now reflects the role + generated monitoring.
    with TestClient(create_app()) as client:
        state_resp = client.get(f"/api/v1/agents/{agent.id}/desired-state", headers=_headers(raw))
    assert state_resp.status_code == 200
    state = state_resp.json()
    assert state["state"]["orchestration"]["roles"] == [plan["name"]]
    assert "docker_daemon" in state["state"]["monitoring"]["checks"]
    first_generation = state["generation"]

    # A repeat compile with nothing changed keeps the same generation.
    with TestClient(create_app()) as client:
        again = client.get(f"/api/v1/agents/{agent.id}/desired-state", headers=_headers(raw))
    assert again.json()["generation"] == first_generation

    # A new plan version with different generated_monitoring bumps the generation.
    with TestClient(create_app()) as client:
        client.post(
            f"/api/v1/orchestration/plans/{plan['id']}/versions",
            json={"generated_monitoring": {"checks": ["docker_daemon", "docker_disk_usage"], "thresholds": {}}},
            headers=_headers(raw),
        )
    with TestClient(create_app()) as client:
        bumped = client.get(f"/api/v1/agents/{agent.id}/desired-state", headers=_headers(raw))
    assert bumped.json()["generation"] > first_generation
    assert "docker_disk_usage" in bumped.json()["state"]["monitoring"]["checks"]

    # Unlinking removes the role from the next compile.
    with TestClient(create_app()) as client:
        unlink = client.delete(f"/api/v1/orchestration/plans/{plan['id']}/links/{link_id}", headers=_headers(raw))
    assert unlink.status_code == 204
    with TestClient(create_app()) as client:
        after_unlink = client.get(f"/api/v1/agents/{agent.id}/desired-state", headers=_headers(raw))
    assert after_unlink.json()["state"]["orchestration"]["roles"] == []

    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/orchestration/plans/{plan['id']}", headers=_headers(raw))

    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_plan_link_invalid_target_422(db_session):
    api_token, raw = await _make_api_token(db_session)
    sfx = run_suffix()

    with TestClient(create_app()) as client:
        plan = client.post(
            "/api/v1/orchestration/plans",
            json={"name": f"needs-target-{sfx}", "display_name": "x", "plan_type": "role"},
            headers=_headers(raw),
        ).json()

    with TestClient(create_app()) as client:
        missing_host_id = client.post(
            f"/api/v1/orchestration/plans/{plan['id']}/links", json={"target_type": "host"}, headers=_headers(raw)
        )
    assert missing_host_id.status_code == 422

    with TestClient(create_app()) as client:
        bad_target = client.post(
            f"/api/v1/orchestration/plans/{plan['id']}/links", json={"target_type": "nope"}, headers=_headers(raw)
        )
    assert bad_target.status_code == 422

    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/orchestration/plans/{plan['id']}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Block L2: approval gate + YOLO-MAN global switch


async def _set_yolo_mode(client, headers, enabled: bool):
    resp = client.put("/api/v1/system/yolo-mode", json={"enabled": enabled}, headers=headers)
    assert resp.status_code == 200
    return resp.json()


async def test_orchestration_link_approval_gate(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = await _make_agent(db_session)
    sfx = run_suffix()

    with TestClient(create_app()) as client:
        plan = client.post(
            "/api/v1/orchestration/plans",
            json={
                "name": f"gated-{sfx}", "display_name": "x", "plan_type": "role",
                "version": {"generated_monitoring": {"checks": ["docker_daemon"], "thresholds": {}}},
            },
            headers=_headers(raw),
        ).json()

        # Default require_approval=True, auto_apply=False -> pending_approval,
        # zero effect on the host's desired state.
        link_resp = client.post(
            f"/api/v1/orchestration/plans/{plan['id']}/links",
            json={"target_type": "host", "agent_id": str(agent.id)},
            headers=_headers(raw),
        )
        assert link_resp.status_code == 200
        link = link_resp.json()
        assert link["status"] == "pending_approval"

        state = client.get(f"/api/v1/agents/{agent.id}/desired-state", headers=_headers(raw)).json()
        assert state["state"]["orchestration"]["roles"] == []

        pending = client.get("/api/v1/orchestration/pending-links", headers=_headers(raw)).json()
        assert any(p["id"] == link["id"] for p in pending)

        # Approve -> active, host's desired state now shows the role.
        approve = client.post(f"/api/v1/orchestration/plans/{plan['id']}/links/{link['id']}/approve", headers=_headers(raw))
        assert approve.status_code == 200
        assert approve.json()["status"] == "active"

        state_after = client.get(f"/api/v1/agents/{agent.id}/desired-state", headers=_headers(raw)).json()
        assert plan["name"] in state_after["state"]["orchestration"]["roles"]

        # Re-approving an already-active link is a 409.
        re_approve = client.post(f"/api/v1/orchestration/plans/{plan['id']}/links/{link['id']}/approve", headers=_headers(raw))
        assert re_approve.status_code == 409

        client.delete(f"/api/v1/orchestration/plans/{plan['id']}", headers=_headers(raw))

    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_orchestration_link_reject(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = await _make_agent(db_session)
    sfx = run_suffix()

    with TestClient(create_app()) as client:
        plan = client.post(
            "/api/v1/orchestration/plans", json={"name": f"rej-{sfx}", "display_name": "x", "plan_type": "role"}, headers=_headers(raw)
        ).json()
        link = client.post(
            f"/api/v1/orchestration/plans/{plan['id']}/links", json={"target_type": "host", "agent_id": str(agent.id)}, headers=_headers(raw)
        ).json()

        reject = client.post(f"/api/v1/orchestration/plans/{plan['id']}/links/{link['id']}/reject", headers=_headers(raw))
        assert reject.status_code == 200
        assert reject.json()["status"] == "rejected"

        # A rejected link no longer shows up in the pending queue.
        pending = client.get("/api/v1/orchestration/pending-links", headers=_headers(raw)).json()
        assert not any(p["id"] == link["id"] for p in pending)

        client.delete(f"/api/v1/orchestration/plans/{plan['id']}", headers=_headers(raw))

    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_yolo_mode_toggle_and_link_bypass(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = await _make_agent(db_session)
    sfx = run_suffix()

    with TestClient(create_app()) as client:
        default_state = client.get("/api/v1/system/yolo-mode", headers=_headers(raw))
        assert default_state.status_code == 200
        assert default_state.json()["yolo_mode"] is False

    with TestClient(create_app()) as client:
        await _set_yolo_mode(client, _headers(raw), True)

    try:
        with TestClient(create_app()) as client:
            plan = client.post(
                "/api/v1/orchestration/plans", json={"name": f"yolo-{sfx}", "display_name": "x", "plan_type": "role"}, headers=_headers(raw)
            ).json()
            # No auto_apply passed at all -> still active, because the
            # global switch overrides the per-link default.
            link = client.post(
                f"/api/v1/orchestration/plans/{plan['id']}/links", json={"target_type": "host", "agent_id": str(agent.id)}, headers=_headers(raw)
            ).json()
            assert link["status"] == "active"
            client.delete(f"/api/v1/orchestration/plans/{plan['id']}", headers=_headers(raw))
    finally:
        with TestClient(create_app()) as client:
            await _set_yolo_mode(client, _headers(raw), False)

    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_preview_plan_link_endpoint_persists_nothing(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = await _make_agent(db_session)
    sfx = run_suffix()

    with TestClient(create_app()) as client:
        plan = client.post(
            "/api/v1/orchestration/plans",
            json={
                "name": f"preview-{sfx}", "display_name": "x", "plan_type": "role",
                "version": {"generated_monitoring": {"checks": ["docker_daemon"], "thresholds": {}}},
            },
            headers=_headers(raw),
        ).json()

        preview = client.post(
            f"/api/v1/orchestration/plans/{plan['id']}/preview-link",
            json={"target_type": "host", "agent_id": str(agent.id)},
            headers=_headers(raw),
        )
        assert preview.status_code == 200
        body = preview.json()
        assert body["affected_host_count"] == 1
        assert body["sample_diff"]["checks_added"] == ["docker_daemon"]

        links = client.get(f"/api/v1/orchestration/plans/{plan['id']}/links", headers=_headers(raw)).json()
        assert links == []  # preview never persists a link

        client.delete(f"/api/v1/orchestration/plans/{plan['id']}", headers=_headers(raw))

    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_desired_state_404_for_missing_agent(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{uuid.uuid4()}/desired-state", headers=_headers(raw))
    assert resp.status_code == 404
    await db_session.delete(api_token)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Block L3a: OU-scoped check rules, block_inheritance toggle, GET /ou/{id}/objects


async def test_ou_block_inheritance_toggle(db_session):
    api_token, raw = await _make_api_token(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        ou = client.post("/api/v1/ou", json={"name": f"BlockOU-{sfx}"}, headers=_headers(raw)).json()
        assert ou["block_inheritance"] is False
        assert ou["ltree_path"] == f"BlockOU-{sfx}"

        patched = client.patch(f"/api/v1/ou/{ou['id']}", json={"block_inheritance": True}, headers=_headers(raw))
        assert patched.status_code == 200
        assert patched.json()["block_inheritance"] is True

        client.delete(f"/api/v1/ou/{ou['id']}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_ou_scoped_check_rule_and_objects_listing(db_session):
    api_token, raw = await _make_api_token(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        ou = client.post("/api/v1/ou", json={"name": f"RuleOU-{sfx}"}, headers=_headers(raw)).json()

        # An OU-scoped check rule with enforced set.
        rule = client.post(
            "/api/v1/check-rules",
            json={
                "service_name": "CPU", "metric": "cpu_pct", "comparison": "gt",
                "warn_threshold": 85.0, "crit_threshold": 95.0,
                "scope_type": "ou", "scope_ou_id": ou["id"], "enforced": True, "link_order": 50,
            },
            headers=_headers(raw),
        )
        assert rule.status_code == 200
        assert rule.json()["scope_type"] == "ou"
        assert rule.json()["scope_ou_id"] == ou["id"]
        assert rule.json()["enforced"] is True
        assert rule.json()["link_order"] == 50
        rule_id = rule.json()["id"]

        # scope_type='ou' without scope_ou_id is rejected.
        bad = client.post(
            "/api/v1/check-rules",
            json={"service_name": "X", "metric": "m", "comparison": "gt", "scope_type": "ou"},
            headers=_headers(raw),
        )
        assert bad.status_code == 422

        # GET /ou/{id}/objects shows the rule as a check_rule child.
        objs = client.get(f"/api/v1/ou/{ou['id']}/objects", headers=_headers(raw)).json()
        assert any(o["kind"] == "check_rule" and o["id"] == rule_id and o["enforced"] for o in objs)

        client.delete(f"/api/v1/check-rules/{rule_id}", headers=_headers(raw))
        client.delete(f"/api/v1/ou/{ou['id']}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_notification_rule_ou_scope(db_session):
    api_token, raw = await _make_api_token(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        ou = client.post("/api/v1/ou", json={"name": f"NotifOU-{sfx}"}, headers=_headers(raw)).json()
        rule = client.post(
            "/api/v1/notification-rules",
            json={"name": f"noc-{sfx}", "channel": "email", "target": "noc@example.com", "ou_id": ou["id"], "enforced": True},
            headers=_headers(raw),
        )
        assert rule.status_code == 200
        assert rule.json()["ou_id"] == ou["id"]
        assert rule.json()["enforced"] is True
        rule_id = rule.json()["id"]

        objs = client.get(f"/api/v1/ou/{ou['id']}/objects", headers=_headers(raw)).json()
        assert any(o["kind"] == "notification" and o["id"] == rule_id for o in objs)

        client.delete(f"/api/v1/notification-rules/{rule_id}", headers=_headers(raw))
        client.delete(f"/api/v1/ou/{ou['id']}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_check_rule_patch_toggles(db_session):
    api_token, raw = await _make_api_token(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        ou = client.post("/api/v1/ou", json={"name": f"PatchOU-{sfx}"}, headers=_headers(raw)).json()
        rule = client.post(
            "/api/v1/check-rules",
            json={
                "service_name": "CPU", "metric": "cpu_pct", "comparison": "gt",
                "scope_type": "ou", "scope_ou_id": ou["id"], "enforced": False,
            },
            headers=_headers(raw),
        ).json()
        patched = client.patch(f"/api/v1/check-rules/{rule['id']}", json={"enforced": True}, headers=_headers(raw))
        assert patched.status_code == 200
        assert patched.json()["enforced"] is True
        assert patched.json()["scope_type"] == "ou"

        disabled = client.patch(f"/api/v1/check-rules/{rule['id']}", json={"enabled": False}, headers=_headers(raw))
        assert disabled.json()["enabled"] is False
        assert disabled.json()["enforced"] is True

        client.delete(f"/api/v1/check-rules/{rule['id']}", headers=_headers(raw))
        client.delete(f"/api/v1/ou/{ou['id']}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_notification_rule_patch_toggles(db_session):
    api_token, raw = await _make_api_token(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        rule = client.post(
            "/api/v1/notification-rules",
            json={"name": f"n-{sfx}", "channel": "email", "target": "x@example.com"},
            headers=_headers(raw),
        ).json()
        patched = client.patch(f"/api/v1/notification-rules/{rule['id']}", json={"enforced": True}, headers=_headers(raw))
        assert patched.status_code == 200
        assert patched.json()["enforced"] is True
        client.delete(f"/api/v1/notification-rules/{rule['id']}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_metric_catalog_returns_display_names(db_session):
    api_token, raw = await _make_api_token(db_session)
    # Seed one metric row so the catalog has something from the DB.
    from datetime import datetime, timezone
    from bossman.db.models import Metric
    agent = await _make_agent(db_session)
    await write_metric(db_session, agent.id, "cpu_pct", 42.0, when=datetime.now(timezone.utc))
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/metric-catalog", headers=_headers(raw))
    assert resp.status_code == 200
    entries = resp.json()
    cpu = next((e for e in entries if e["metric"] == "cpu_pct"), None)
    assert cpu is not None
    assert cpu["display_name"] == "CPU usage"
    assert cpu["unit"] == "%"

    # cleanup the seeded metric + agent. `metrics` is a VIEW and takes no DELETE either —
    # see tests/metric_helpers.
    await purge_metrics(db_session, agent.id)
    await db_session.commit()
    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_delete_link_by_id(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = await _make_agent(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        plan = client.post(
            "/api/v1/orchestration/plans",
            json={"name": f"linkdel-{sfx}", "display_name": "x", "plan_type": "role"},
            headers=_headers(raw),
        ).json()
        link = client.post(
            f"/api/v1/orchestration/plans/{plan['id']}/links",
            json={"target_type": "host", "agent_id": str(agent.id), "auto_apply": True},
            headers=_headers(raw),
        ).json()
        # Delete by link id alone (the OU-tree path).
        resp = client.delete(f"/api/v1/orchestration/links/{link['id']}", headers=_headers(raw))
        assert resp.status_code == 204
        remaining = client.get(f"/api/v1/orchestration/plans/{plan['id']}/links", headers=_headers(raw)).json()
        assert remaining == []
        client.delete(f"/api/v1/orchestration/plans/{plan['id']}", headers=_headers(raw))
    await _delete_agent(db_session, agent)
    await db_session.delete(api_token)
    await db_session.commit()
