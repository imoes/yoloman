"""Block O3 — the host-group policy report endpoint. Real app + real DB,
same commit-through-a-separate-session pattern as tests/test_orchestration_api.py:
rows are created (and committed) via the db_session fixture so the app's own
session sees them, then cleaned up explicitly.
"""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.db.models import (
    Agent,
    HostGroup,
    HostGroupMember,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    OUNode,
)
from bossman.main import create_app
from bossman.services.auth import new_api_token

TENANT = "00000000-0000-0000-0000-000000000001"


def _sfx() -> str:
    return uuid.uuid4().hex[:8]


async def _token(db_session):
    row, raw = new_api_token(f"grp-caller-{_sfx()}")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, {"Authorization": f"Bearer {raw}"}


async def test_group_policy_report_unions_member_policies(db_session):
    api_token, headers = await _token(db_session)
    sfx = _sfx()

    # OU with a plan actively linked to it.
    ou = OUNode(id=uuid.uuid4(), tenant_id=TENANT, parent_id=None, name=f"ou-{sfx}", path=f"/ou-{sfx}", ltree_path=f"ou_{sfx}")
    plan = OrchestrationPlan(id=uuid.uuid4(), tenant_id=TENANT, name=f"plan-{sfx}", display_name="P", plan_type="role", current_version=1)
    db_session.add_all([ou, plan])
    await db_session.flush()
    db_session.add(OrchestrationPlanVersion(id=uuid.uuid4(), tenant_id=TENANT, plan_id=plan.id, version=1, default_parameters={}, generated_monitoring={}))
    link = OrchestrationPlanLink(
        id=uuid.uuid4(), tenant_id=TENANT, plan_id=plan.id, target_type="ou", ou_id=ou.id,
        parameters={}, priority=100, link_order=100, status="active",
    )
    db_session.add(link)

    # Two hosts in the OU, one outside; a group holding one in + one out.
    a_in = Agent(id=uuid.uuid4(), name=f"in-{sfx}", token="t", tenant_id=TENANT, ou_id=ou.id)
    a_out = Agent(id=uuid.uuid4(), name=f"out-{sfx}", token="t", tenant_id=TENANT, ou_id=None)
    db_session.add_all([a_in, a_out])
    await db_session.flush()
    group = HostGroup(id=uuid.uuid4(), tenant_id=TENANT, name=f"grp-{sfx}")
    db_session.add(group)
    await db_session.flush()
    db_session.add_all([
        HostGroupMember(id=uuid.uuid4(), tenant_id=TENANT, host_group_id=group.id, agent_id=a_in.id),
        HostGroupMember(id=uuid.uuid4(), tenant_id=TENANT, host_group_id=group.id, agent_id=a_out.id),
    ])
    await db_session.commit()

    try:
        with TestClient(create_app()) as client:
            resp = client.get(f"/api/v1/host-groups/{group.id}/policy-report", headers=headers)
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["member_count"] == 2
        names = {p["name"]: p for p in body["policies"]}
        assert plan.name in names, body
        # The plan is linked to the OU, so it applies only to the in-OU member.
        assert names[plan.name]["member_count"] == 1
        assert names[plan.name]["type"] == "role"
    finally:
        # Explicit cleanup (created rows were committed) — dependency order:
        # links + members + plan versions first, then agents/group/plan/ou/token.
        for m in (await db_session.scalars(select(HostGroupMember).where(HostGroupMember.host_group_id == group.id))).all():
            await db_session.delete(m)
        got_link = await db_session.get(OrchestrationPlanLink, link.id)
        if got_link:
            await db_session.delete(got_link)
        for v in (await db_session.scalars(select(OrchestrationPlanVersion).where(OrchestrationPlanVersion.plan_id == plan.id))).all():
            await db_session.delete(v)
        await db_session.flush()
        for obj_id, model in [(a_in.id, Agent), (a_out.id, Agent), (group.id, HostGroup), (plan.id, OrchestrationPlan), (ou.id, OUNode), (api_token.id, type(api_token))]:
            got = await db_session.get(model, obj_id)
            if got:
                await db_session.delete(got)
        await db_session.commit()


async def test_group_policy_report_404_for_unknown_group(db_session):
    _api_token, headers = await _token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/host-groups/{uuid.uuid4()}/policy-report", headers=headers)
    assert resp.status_code == 404
