"""C1/C2: cluster hosts — CRUD.

A cluster is created as an `agents` row with mode="cluster" and no address, so it appears in
the host list and carries services, problems, acknowledgement, downtime and notification
like any other host (see db.models.HostCluster for why). This module owns creating that pair
of rows together, because half a cluster — an agent with no config, or config with no agent —
is not a state anything else knows how to handle.

Validation worth naming:

- a node must be a real host, and must not be the cluster itself
- `aggregation_mode` must be one of worst|best|failover ("native" is deliberately absent,
  see services/clustering)
- failover's `primary_node_id` must be one of the cluster's own nodes; a primary that is not
  a member would silently fall back to "first by name" on every poll
- deleting the cluster deletes its membership and config (ON DELETE CASCADE) but never the
  nodes
"""

from __future__ import annotations

import uuid
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.etag import check_if_match, compute_version
from bossman.db.models import Agent, ClusterNode, HostCluster, Service
from bossman.db.session import get_session
from bossman.services import clustering

router = APIRouter()


class ClusterIn(BaseModel):
    name: str
    aggregation_mode: str = "worst"
    node_ids: list[UUID] = []
    primary_node_id: UUID | None = None
    # ["Memory", "Disk *"] — which services belong to the cluster rather than the node.
    service_patterns: list[str] = []


class ClusterNodeOut(BaseModel):
    id: UUID
    name: str
    is_primary: bool


class ClusterOut(BaseModel):
    id: UUID
    name: str
    aggregation_mode: str
    primary_node_id: UUID | None
    service_patterns: list[str]
    nodes: list[ClusterNodeOut]
    created_at: datetime
    # What the cluster currently reports, so the caller sees the effect of its patterns
    # without a second round trip. NOT part of `version` — it follows the fleet, and a
    # version that moves on its own would reject every save.
    service_states: dict[str, str] = {}
    # A3: send this back in If-Match on PUT — see api/etag.py.
    version: str = ""


async def _load(session: AsyncSession, agent_id: UUID) -> tuple[Agent, HostCluster]:
    agent = await session.get(Agent, agent_id)
    config = await session.get(HostCluster, agent_id)
    if agent is None or config is None:
        raise HTTPException(status_code=404, detail="no such cluster")
    return agent, config


async def _out(session: AsyncSession, agent: Agent, config: HostCluster) -> ClusterOut:
    node_ids = list(
        (
            await session.scalars(
                select(ClusterNode.node_agent_id).where(ClusterNode.cluster_agent_id == agent.id)
            )
        ).all()
    )
    nodes = (await session.scalars(select(Agent).where(Agent.id.in_(node_ids)))).all() if node_ids else []
    services = (await session.scalars(select(Service).where(Service.agent_id == agent.id))).all()
    out = ClusterOut(
        id=agent.id,
        name=agent.name,
        aggregation_mode=config.aggregation_mode,
        primary_node_id=config.primary_node_id,
        service_patterns=list(config.service_patterns or []),
        nodes=sorted(
            (
                ClusterNodeOut(id=n.id, name=n.name, is_primary=n.id == config.primary_node_id)
                for n in nodes
            ),
            key=lambda n: n.name,
        ),
        created_at=config.created_at,
        service_states={s.name: s.state for s in sorted(services, key=lambda s: s.name)},
    )
    out.version = compute_version(out)
    return out


async def _validate(body: ClusterIn, session: AsyncSession, *, cluster_id: UUID | None = None) -> None:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    if body.aggregation_mode not in clustering.MODES:
        raise HTTPException(
            status_code=422,
            detail=f"aggregation_mode must be one of {'|'.join(clustering.MODES)}",
        )
    for node_id in body.node_ids:
        if node_id == cluster_id:
            raise HTTPException(status_code=422, detail="a cluster cannot be its own node")
        if await session.get(Agent, node_id) is None:
            raise HTTPException(status_code=422, detail=f"no such host {node_id}")
    if body.primary_node_id is not None and body.primary_node_id not in body.node_ids:
        # Otherwise every poll silently falls back to "first by name" and the configured
        # preference does nothing at all.
        raise HTTPException(status_code=422, detail="primary_node_id must be one of the cluster's nodes")


async def _set_nodes(session: AsyncSession, cluster_id: UUID, node_ids: list[UUID]) -> None:
    await session.execute(delete(ClusterNode).where(ClusterNode.cluster_agent_id == cluster_id))
    for node_id in dict.fromkeys(node_ids):  # de-duplicate, keep order
        session.add(ClusterNode(cluster_agent_id=cluster_id, node_agent_id=node_id))


@router.get("/api/v1/clusters", response_model=list[ClusterOut])
async def list_clusters(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[ClusterOut]:
    """Cluster hosts — a cluster appears in the fleet as a host, on purpose.

    A cluster is an `agents` row with `mode="cluster"` and no address, so it carries services,
    problems, acknowledgements, downtime and notifications exactly like a real host. That is why it
    is here and not in a parallel object model: an operator should not need a second set of screens
    to acknowledge a cluster's problem.
    """
    configs = (await session.scalars(select(HostCluster))).all()
    out = []
    for config in configs:
        agent = await session.get(Agent, config.agent_id)
        if agent is not None:
            out.append(await _out(session, agent, config))
    return sorted(out, key=lambda c: c.name)


@router.post("/api/v1/clusters", response_model=ClusterOut, status_code=201)
async def create_cluster(
    body: ClusterIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ClusterOut:
    """Create a cluster — the agent row and its cluster config, together in one act.

    Deliberately not two calls: half a cluster (an agent with no config, or config with no agent)
    would appear in the host list as something nobody can explain or clean up.
    """
    await _validate(body, session)
    name = body.name.strip()
    if await session.scalar(select(Agent).where(Agent.name == name)) is not None:
        raise HTTPException(status_code=409, detail=f"a host named {name!r} already exists")
    # No address and a random token: nothing ever polls a cluster, its state is computed
    # from its nodes. enrollment_state="enrolled" so it shows up in the fleet like a host.
    agent = Agent(
        name=name, address=None, token=uuid.uuid4().hex, mode="cluster", enrollment_state="enrolled"
    )
    session.add(agent)
    await session.flush()
    session.add(
        HostCluster(
            agent_id=agent.id,
            aggregation_mode=body.aggregation_mode,
            primary_node_id=body.primary_node_id,
            service_patterns=list(body.service_patterns),
        )
    )
    await _set_nodes(session, agent.id, body.node_ids)
    await session.commit()
    return await _out(session, agent, await session.get(HostCluster, agent.id))


@router.put("/api/v1/clusters/{cluster_id}", response_model=ClusterOut)
async def update_cluster(
    cluster_id: UUID,
    body: ClusterIn,
    request: Request,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ClusterOut:
    """Change a cluster's members or quorum settings. Honours `If-Match` (412 when stale)."""
    agent, config = await _load(session, cluster_id)
    check_if_match(request, (await _out(session, agent, config)).version)
    await _validate(body, session, cluster_id=cluster_id)
    name = body.name.strip()
    if name != agent.name and await session.scalar(select(Agent).where(Agent.name == name)) is not None:
        raise HTTPException(status_code=409, detail=f"a host named {name!r} already exists")
    agent.name = name
    config.aggregation_mode = body.aggregation_mode
    config.primary_node_id = body.primary_node_id
    config.service_patterns = list(body.service_patterns)
    await _set_nodes(session, cluster_id, body.node_ids)
    await session.commit()
    return await _out(session, agent, config)


@router.delete("/api/v1/clusters/{cluster_id}", status_code=204)
async def delete_cluster(
    cluster_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    """Removes the cluster host and its aggregated services. The NODES are untouched —
    they are real hosts that existed before the cluster and keep their own services."""
    agent, _config = await _load(session, cluster_id)
    await session.execute(delete(Service).where(Service.agent_id == cluster_id))
    await session.delete(agent)  # cascades host_clusters + cluster_nodes
    await session.commit()
