"""C1/C2 through the DB and the API: a cluster is a host whose services are computed.

The semantics were also proven live on the real Proxmox trio (vpp0221/22/23): with vpp0221
CRIT and the other two OK, `best` reported OK pivoting on vpp0222 and `worst` reported CRIT
pivoting on vpp0221 — same node states, opposite verdicts.
"""

import uuid
from datetime import datetime, timezone

from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from bossman.db.models import AccessGrant, Agent, ClusterNode, HostCluster, Service, ServiceStateHistory
from bossman.main import create_app
from bossman.services.auth import new_api_token
from bossman.services.clustering import aggregate_all_clusters


async def _make_api_token(db_session):
    name = f"cl-caller-{uuid.uuid4().hex[:6]}"
    row, raw = new_api_token(name)
    db_session.add(row)
    db_session.add(AccessGrant(subject_kind="api_token", subject_ref=name, scope="all"))
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _node(db_session, name, services: dict[str, str]) -> Agent:
    agent = Agent(
        name=f"{name}-{uuid.uuid4().hex[:6]}", address="10.0.0.1:9000",
        token=uuid.uuid4().hex, enrollment_state="enrolled",
    )
    db_session.add(agent)
    await db_session.flush()
    now = datetime.now(timezone.utc)
    for svc_name, state in services.items():
        db_session.add(
            Service(
                agent_id=agent.id, name=svc_name, metric="", state=state, value=None,
                output=f"{state} on {agent.name}", last_state_change=now, last_checked=now,
                state_type="hard", attempt=3, max_attempts=3,
            )
        )
    await db_session.flush()
    return agent


async def _purge(db_session, *agents):
    for agent in agents:
        await db_session.execute(delete(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id))
        await db_session.execute(delete(Service).where(Service.agent_id == agent.id))
        await db_session.execute(delete(ClusterNode).where(ClusterNode.cluster_agent_id == agent.id))
        await db_session.execute(delete(ClusterNode).where(ClusterNode.node_agent_id == agent.id))
        await db_session.execute(delete(HostCluster).where(HostCluster.agent_id == agent.id))
    await db_session.flush()
    for agent in agents:
        await db_session.delete(agent)
    await db_session.commit()


async def _cluster(db_session, nodes, mode="worst", patterns=("Memory",), primary=None) -> Agent:
    agent = Agent(
        name=f"cluster-{uuid.uuid4().hex[:6]}", address=None, token=uuid.uuid4().hex,
        mode="cluster", enrollment_state="enrolled",
    )
    db_session.add(agent)
    await db_session.flush()
    db_session.add(
        HostCluster(
            agent_id=agent.id, aggregation_mode=mode, service_patterns=list(patterns),
            primary_node_id=primary.id if primary else None,
        )
    )
    for node in nodes:
        db_session.add(ClusterNode(cluster_agent_id=agent.id, node_agent_id=node.id))
    await db_session.commit()
    return agent


async def _cluster_service(db_session, cluster, name) -> Service | None:
    return await db_session.scalar(
        select(Service).where(Service.agent_id == cluster.id, Service.name == name)
    )


async def test_worst_mode_surfaces_one_bad_node(db_session):
    a = await _node(db_session, "n-a", {"Memory": "OK"})
    b = await _node(db_session, "n-b", {"Memory": "CRIT"})
    cluster = await _cluster(db_session, [a, b], mode="worst")

    await aggregate_all_clusters(db_session)
    await db_session.commit()

    svc = await _cluster_service(db_session, cluster, "Memory")
    assert svc.state == "CRIT"
    assert b.name in svc.output, "the pivot node must be named"
    await _purge(db_session, cluster, a, b)


async def test_best_mode_stays_ok_while_one_node_is_ok(db_session):
    """The reason clusters exist — and the opposite verdict from the same node states."""
    a = await _node(db_session, "n-a", {"Memory": "OK"})
    b = await _node(db_session, "n-b", {"Memory": "CRIT"})
    cluster = await _cluster(db_session, [a, b], mode="best")

    await aggregate_all_clusters(db_session)
    await db_session.commit()

    svc = await _cluster_service(db_session, cluster, "Memory")
    assert svc.state == "OK"
    assert a.name in svc.output
    await _purge(db_session, cluster, a, b)


async def test_only_claimed_services_are_aggregated(db_session):
    """A node service the cluster does not claim stays the node's business."""
    a = await _node(db_session, "n-a", {"Memory": "OK", "CPU load": "CRIT"})
    cluster = await _cluster(db_session, [a], mode="worst", patterns=("Memory",))

    await aggregate_all_clusters(db_session)
    await db_session.commit()

    assert await _cluster_service(db_session, cluster, "Memory") is not None
    assert await _cluster_service(db_session, cluster, "CPU load") is None
    await _purge(db_session, cluster, a)


async def test_a_prefix_pattern_claims_every_mount(db_session):
    a = await _node(db_session, "n-a", {"Disk /": "OK", "Disk /var": "WARN"})
    cluster = await _cluster(db_session, [a], mode="worst", patterns=("Disk *",))

    await aggregate_all_clusters(db_session)
    await db_session.commit()

    assert (await _cluster_service(db_session, cluster, "Disk /")).state == "OK"
    assert (await _cluster_service(db_session, cluster, "Disk /var")).state == "WARN"
    await _purge(db_session, cluster, a)


async def test_failover_warns_when_the_secondary_also_reports(db_session):
    active = await _node(db_session, "active", {"Memory": "OK"})
    standby = await _node(db_session, "standby", {"Memory": "OK"})
    cluster = await _cluster(db_session, [active, standby], mode="failover", primary=active)

    await aggregate_all_clusters(db_session)
    await db_session.commit()

    svc = await _cluster_service(db_session, cluster, "Memory")
    assert svc.state == "WARN", "two active nodes in a failover cluster is itself the news"
    assert "also reporting" in svc.output
    await _purge(db_session, cluster, active, standby)


async def test_a_cluster_with_no_nodes_produces_nothing(db_session):
    """Not an error and not an UNKNOWN service — just nothing to aggregate yet."""
    cluster = await _cluster(db_session, [], mode="worst")
    touched = await aggregate_all_clusters(db_session)
    await db_session.commit()
    assert [t for t in touched if t.agent_id == cluster.id] == []
    await _purge(db_session, cluster)


async def test_the_aggregate_recovers_with_its_nodes(db_session):
    """Proven live too: deleting the rule that broke vpp0221 returned the cluster to OK."""
    a = await _node(db_session, "n-a", {"Memory": "CRIT"})
    cluster = await _cluster(db_session, [a], mode="worst")
    await aggregate_all_clusters(db_session)
    await db_session.commit()
    assert (await _cluster_service(db_session, cluster, "Memory")).state == "CRIT"

    node_svc = await db_session.scalar(
        select(Service).where(Service.agent_id == a.id, Service.name == "Memory")
    )
    node_svc.state = "OK"
    node_svc.output = "recovered"
    await db_session.commit()
    await aggregate_all_clusters(db_session)
    await db_session.commit()

    assert (await _cluster_service(db_session, cluster, "Memory")).state == "OK"
    await _purge(db_session, cluster, a)


# ---------------------------------------------------------------------------
# API


async def test_create_lists_and_delete(db_session):
    token, raw = await _make_api_token(db_session)
    a = await _node(db_session, "api-n", {"Memory": "OK"})
    await db_session.commit()

    with TestClient(create_app()) as client:
        created = client.post(
            "/api/v1/clusters",
            json={"name": f"c-{uuid.uuid4().hex[:6]}", "aggregation_mode": "best",
                  "node_ids": [str(a.id)], "service_patterns": ["Memory"]},
            headers=_headers(raw),
        )
        assert created.status_code == 201, created.text
        cid = created.json()["id"]
        assert [n["name"] for n in created.json()["nodes"]] == [a.name]

        listed = client.get("/api/v1/clusters", headers=_headers(raw)).json()
        assert cid in [c["id"] for c in listed]

        assert client.delete(f"/api/v1/clusters/{cid}", headers=_headers(raw)).status_code == 204

    assert await db_session.get(Agent, uuid.UUID(cid)) is None, "the cluster host goes"
    assert await db_session.get(Agent, a.id) is not None, "the NODE must survive"
    await _purge(db_session, a)
    await db_session.delete(token)
    await db_session.commit()


async def test_an_unknown_aggregation_mode_is_refused(db_session):
    """"native" is deliberately absent: no check of ours has a cluster entry point, so the
    mode's only possible outcome would be Checkmk's "not implemented" UNKNOWN."""
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        for mode in ("native", "average", ""):
            resp = client.post(
                "/api/v1/clusters",
                json={"name": f"c-{uuid.uuid4().hex[:6]}", "aggregation_mode": mode, "node_ids": []},
                headers=_headers(raw),
            )
            assert resp.status_code == 422, mode
    await db_session.delete(token)
    await db_session.commit()


async def test_a_primary_outside_the_cluster_is_refused(db_session):
    """It would silently fall back to "first by name" on every poll, so the configured
    preference would do nothing at all."""
    token, raw = await _make_api_token(db_session)
    a = await _node(db_session, "in", {"Memory": "OK"})
    outsider = await _node(db_session, "out", {"Memory": "OK"})
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/clusters",
            json={"name": f"c-{uuid.uuid4().hex[:6]}", "aggregation_mode": "failover",
                  "node_ids": [str(a.id)], "primary_node_id": str(outsider.id)},
            headers=_headers(raw),
        )
    assert resp.status_code == 422
    await _purge(db_session, a, outsider)
    await db_session.delete(token)
    await db_session.commit()


async def test_a_duplicate_host_name_is_a_conflict(db_session):
    """A cluster IS a host, so it shares the host namespace."""
    token, raw = await _make_api_token(db_session)
    a = await _node(db_session, "dup", {"Memory": "OK"})
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/clusters",
            json={"name": a.name, "aggregation_mode": "worst", "node_ids": []},
            headers=_headers(raw),
        )
    assert resp.status_code == 409
    await _purge(db_session, a)
    await db_session.delete(token)
    await db_session.commit()


async def test_a_cluster_cannot_be_its_own_node(db_session):
    token, raw = await _make_api_token(db_session)
    a = await _node(db_session, "self", {"Memory": "OK"})
    await db_session.commit()
    with TestClient(create_app()) as client:
        created = client.post(
            "/api/v1/clusters",
            json={"name": f"c-{uuid.uuid4().hex[:6]}", "aggregation_mode": "worst", "node_ids": [str(a.id)]},
            headers=_headers(raw),
        )
        cid = created.json()["id"]
        resp = client.put(
            f"/api/v1/clusters/{cid}",
            json={"name": created.json()["name"], "aggregation_mode": "worst", "node_ids": [cid]},
            headers=_headers(raw),
        )
        assert resp.status_code == 422
        client.delete(f"/api/v1/clusters/{cid}", headers=_headers(raw))
    await _purge(db_session, a)
    await db_session.delete(token)
    await db_session.commit()
