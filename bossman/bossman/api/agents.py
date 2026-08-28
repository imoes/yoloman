"""GET /api/v1/agents, /api/v1/agents/{id}, and /api/v1/agents/{id}/metrics
— the fleet inventory + per-agent metric history views (see docs/plan.md's
Bossman plan, section B.7). These serve Bossman's own already-aggregated
Postgres data (see services/poller.py) — never a live pull from the agent
itself, which is exactly the point of polling ahead of time.
"""

from __future__ import annotations

import asyncio
import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, UploadFile
from pydantic import BaseModel
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.api.auth import get_current_identity, require_manage_agent
from bossman.services.auth import user_can_manage_agent
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, Metric, MetricRaw, MetricSeries
from bossman.db.session import get_session
from bossman.services import host_membership, module_library
from bossman.services.metrics_query import measurable_sql_filter
from bossman.services.monitoring import is_infra_agent
from bossman.services.agent_client import AgentClientError
from bossman.services.metrics_query import query_series
from bossman.services.poller import PollResult, poll_agent

router = APIRouter()


def get_session_factory(request: Request) -> async_sessionmaker[AsyncSession]:
    return request.app.state.session_factory


def _resolve_dns_name(agent: Agent) -> str | None:
    """A resolvable host name for `agent`, even when it has no `address`
    (satellites polled through a proxy carry none). Prefers the host part of
    `address`, then the inventory hostname (facts.os.hostname). This is what
    lets a run/inventory view show a DNS name instead of a blank for a
    satellite whose only identity is what its own inventory reported."""
    if agent.address:
        # Strip a trailing :port so the run/inventory view shows the host, not host:port.
        host = agent.address.rsplit(":", 1)[0] if ":" in agent.address else agent.address
        if host:
            return host
    os_facts = (agent.facts or {}).get("os") or {}
    hostname = os_facts.get("hostname")
    return hostname or None


class AgentOut(BaseModel):
    id: UUID
    name: str
    address: str | None
    mode: str
    enrollment_state: str
    agent_version: str
    last_seen_at: datetime | None
    metadata: dict
    groups: list[str]
    parent_agent_id: UUID | None
    # The host's HW/SW inventory document (Block H2) + when it last changed.
    facts: dict
    facts_updated_at: datetime | None
    # Block K7 (tagging): name or name:value pairs, inherited onto every
    # problem this host raises.
    tags: dict
    # Block L3d: which OU the host is placed in (AD-style, exactly one) —
    # NULL = unassigned. Drives the host-placement tree.
    ou_id: UUID | None
    # First-class searchable facets (crit:/site:) — NULL = unset.
    criticality: str | None
    site: str | None
    # A resolvable name for the host even when `address` is null (a satellite
    # polled through a proxy has no direct address). Falls back to the
    # inventory hostname (facts.os.hostname), so a run/inventory view can show
    # a DNS name instead of a blank. None only when neither is known.
    dns_name: str | None

    @classmethod
    def from_model(cls, agent: Agent) -> "AgentOut":
        return cls(
            id=agent.id,
            name=agent.name,
            address=agent.address,
            mode=agent.mode,
            enrollment_state=agent.enrollment_state,
            agent_version=agent.agent_version,
            last_seen_at=agent.last_seen_at,
            metadata=agent.agent_metadata,
            groups=agent.groups,
            parent_agent_id=agent.parent_agent_id,
            facts=agent.facts or {},
            facts_updated_at=agent.facts_updated_at,
            tags=agent.tags or {},
            ou_id=agent.ou_id,
            criticality=agent.criticality,
            site=agent.site,
            dns_name=_resolve_dns_name(agent),
        )


class MetricPointOut(BaseModel):
    time: datetime
    value: float
    labels: dict
    # Populated only for the hourly/daily tiers (Block K1b) — the
    # consolidated bucket's spread; None for a true raw sample.
    min_value: float | None = None
    max_value: float | None = None


class LatestMetricOut(BaseModel):
    """One metric's most recent sample — the "Last value / Last check" row of
    a Zabbix-style latest-data list (see the host-detail Metrics tab). One
    row per metric *name*; multi-series metrics (e.g. disk_used_pct per mount)
    collapse to their single newest point, and the full per-label history is
    still one click away via the per-metric series endpoint."""

    metric: str
    time: datetime
    value: float
    labels: dict


@router.get("/api/v1/agents", response_model=list[AgentOut])
async def list_agents(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[AgentOut]:
    """Every host in the fleet, with its facts, its state and its addresses.

    This is the call that maps a host **name** to the **agent id** the rest of the API
    is addressed by. Names are not unique over a fleet's lifetime; an endpoint that
    took a name would act on the wrong host after a rebuild.

    One deliberate omission: **infrastructure agents are not listed.** The silent
    poller that reaches SNMP and SSH devices ("selecta") is an agent in the database
    and not a monitored host, so it would appear as a host that never has any of the
    things a host has. It is filtered here rather than in the UI, so every client sees
    the same fleet.
    """
    # Hide infrastructure agents (the silent SNMP/SSH poller "selecta") from the
    # Hosts list — it isn't a monitored host, just the engine behind devices.
    agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
    return [AgentOut.from_model(a) for a in agents if not is_infra_agent(a)]


async def _get_agent_or_404(session: AsyncSession, agent_id: UUID) -> Agent:
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    return agent


@router.get("/api/v1/agents/{agent_id}", response_model=AgentOut)
async def get_agent(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> AgentOut:
    """One host: its facts, its enrollment state, its addresses and its versions.

    404 when there is no such id — including for an infrastructure agent's id, which
    `list_agents` does not return either.
    """
    return AgentOut.from_model(await _get_agent_or_404(session, agent_id))


# Tables whose FK to agents is NO ACTION (verified against the live schema):
# they won't cascade on an agent delete, so they're cleared explicitly, in
# FK-safe order, before the agent row goes. Everything else
# (agent_acks/agent_config_delivery/compiled_host_state/graph_items/
# host_group_members/orchestration_plan_links) is ON DELETE CASCADE and goes
# automatically. metrics + service_state_history are TimescaleDB hypertables,
# which is exactly why a plain FK-cascade wasn't put on them and we delete
# by agent_id here instead. plan_run_steps cascades from plan_runs.
_AGENT_CHILD_DELETES = (
    "DELETE FROM host_edges WHERE src_agent_id = :id OR dst_agent_id = :id",
    "DELETE FROM connection_events WHERE src_agent_id = :id",
    "DELETE FROM plan_runs WHERE agent_id = :id",
    "DELETE FROM downtimes WHERE agent_id = :id",
    "DELETE FROM service_state_history WHERE agent_id = :id",
    "DELETE FROM services WHERE agent_id = :id",
    # metrics is now a view, and its points must go FIRST because metrics_raw's FK to metric_series
    # does NOT cascade (migration e7a1c93b5d21: a cascade against a compressed hypertable decompresses
    # wholesale and aborts).
    #
    # ALL OF THEM, not the last day. The time bound that used to be here left older series in place and
    # then deleted `metric_series` only where no points remained — but `agents` cascades to
    # metric_series, so the rows the bound had spared were deleted anyway, by the cascade, straight into
    # the FK: "update or delete on table metric_series violates ... Key (series_id)=(73834791) is still
    # referenced from table metrics_raw". Measured while removing one leftover test host: deleting ANY
    # host with metrics older than a day was impossible, and the 500 said nothing an operator could act
    # on. The decompression cap is already disabled for this transaction (above), which is what the
    # bound was working around.
    "DELETE FROM metrics_raw WHERE series_id IN "
    "(SELECT series_id FROM metric_series WHERE agent_id = :id)",
    "DELETE FROM metric_series WHERE agent_id = :id",
    # The host's own record of what it DID. Deleted with it: the rows carry the agent's id and nothing
    # else identifies the host, so keeping them would leave a log nobody can attribute.
    "DELETE FROM operation_log WHERE agent_id = :id",
)


@router.delete("/api/v1/agents/{agent_id}", status_code=204)
async def delete_agent(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(require_manage_agent),
) -> None:
    """Remove a host (agent) and everything it owns. Satellites that used this
    agent as their proxy parent are orphaned (parent_agent_id → NULL), not
    deleted — deleting a proxy must not silently take its satellites with it.
    All in one transaction, so a mid-delete failure leaves the host intact."""
    agent = await _get_agent_or_404(session, agent_id)
    params = {"id": str(agent_id)}
    # TimescaleDB caps how many rows one DML statement may decompress
    # (max_tuples_decompressed_per_dml_transaction, default 100000). A host with a few
    # weeks of compressed metrics blows straight through it — measured on this fleet:
    # "tuple decompression limit exceeded ... tuples decompressed: 3394018", i.e. deleting
    # a host was simply IMPOSSIBLE once its data had been compressed, which is not an
    # acceptable state for a basic operation. 0 disables the cap, and SET LOCAL scopes it
    # to this transaction so nothing else inherits an unbounded delete budget.
    await session.execute(text("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0"))
    # Orphan any satellites polled through this agent (self-referential FK).
    await session.execute(
        text("UPDATE agents SET parent_agent_id = NULL WHERE parent_agent_id = :id"), params
    )
    for stmt in _AGENT_CHILD_DELETES:
        await session.execute(text(stmt), params)
    await session.delete(agent)  # cascade clears the ON DELETE CASCADE tables
    await session.commit()


class UpdateGroupsRequest(BaseModel):
    groups: list[str]


@router.patch("/api/v1/agents/{agent_id}/groups", response_model=AgentOut)
async def update_agent_groups(
    agent_id: UUID,
    body: UpdateGroupsRequest,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(require_manage_agent),
) -> AgentOut:
    """Host-group membership (see docs/plan.md's monitoring Block E2/E3) —
    the unit a check_rules row can target with scope_type=group, which a
    host-scoped rule can then override. Replaces the whole list rather
    than adding/removing one at a time, matching how the Settings UI's
    host-groups editor naturally works (a multi-select, not a diff).

    Writes through services/host_membership, which owns `host_group_members` and derives
    `agents.groups` from it. Assigning the array directly (as this did) left the membership
    table untouched, so the group editor and this endpoint reported different memberships for
    the same host — see that module's header for the measurement."""
    agent = await _get_agent_or_404(session, agent_id)
    await host_membership.set_agent_groups(session, agent, list(body.groups))
    await session.commit()
    return AgentOut.from_model(agent)


class UpdateTagsRequest(BaseModel):
    tags: dict[str, str]


@router.patch("/api/v1/agents/{agent_id}/tags", response_model=AgentOut)
async def update_agent_tags(
    agent_id: UUID,
    body: UpdateTagsRequest,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(require_manage_agent),
) -> AgentOut:
    """Block K7 (Zabbix gap-analysis, tagging): name or name:value host
    tags (empty-string value = name-only), inherited onto every problem
    this host raises (GET /api/v1/problems?tag=) and matchable by
    NotificationRule.tag_filter. Replaces the whole dict, matching
    update_agent_groups's replace-not-diff shape."""
    agent = await _get_agent_or_404(session, agent_id)
    agent.tags = body.tags
    await session.commit()
    return AgentOut.from_model(agent)


class MassUpdateGroupsRequest(BaseModel):
    agent_ids: list[UUID]
    op: str  # add | replace | remove
    groups: list[str]


@router.post("/api/v1/agents/mass-update/groups", response_model=list[AgentOut])
async def mass_update_agent_groups(
    body: MassUpdateGroupsRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> list[AgentOut]:
    """Zabbix gap-analysis Block K2c ("Mass update"): bulk-edit host-group
    membership across many selected agents in one call, instead of one
    PATCH per host. Scoped to the one field Bossman's Agent model actually
    has a bulk-editable equivalent for today (groups) — templates/macros/
    inventory/encryption mass-editing has no Bossman counterpart yet (see
    docs/zabbix-gap-analysis.md's Batch 2)."""
    if body.op not in ("add", "replace", "remove"):
        raise HTTPException(status_code=422, detail="op must be one of: add, replace, remove")
    if not body.agent_ids:
        raise HTTPException(status_code=422, detail="agent_ids must not be empty")

    agents = (await session.scalars(select(Agent).where(Agent.id.in_(body.agent_ids)))).all()
    found_ids = {a.id for a in agents}
    missing = set(body.agent_ids) - found_ids
    if missing:
        raise HTTPException(status_code=404, detail=f"no such agent(s): {sorted(str(m) for m in missing)}")

    # Block M: the caller must be allowed to manage every host in the batch.
    for agent in agents:
        if not await user_can_manage_agent(session, identity, agent.id):
            raise HTTPException(status_code=403, detail=f"not authorized to manage host {agent.name!r}")

    # Through services/host_membership so the bulk editor writes the same source of truth as
    # the single-host and group-side editors (it used to touch only agents.groups).
    for agent in agents:
        if body.op == "replace":
            await host_membership.set_agent_groups(session, agent, list(body.groups))
        elif body.op == "add":
            await host_membership.add_agent_groups(session, agent, list(body.groups))
        else:  # remove
            await host_membership.remove_agent_groups(session, agent, list(body.groups))

    await session.commit()
    return [AgentOut.from_model(a) for a in agents]


class MassAssignFacetsRequest(BaseModel):
    agent_ids: list[UUID]
    # Omit a field to leave it unchanged. For criticality/site, "" clears
    # (→ NULL); a value sets it. add_tags merges; remove_tags deletes keys.
    criticality: str | None = None
    site: str | None = None
    add_tags: dict[str, str] = {}
    remove_tags: list[str] = []


@router.post("/api/v1/agents/mass-update/facets", response_model=list[AgentOut])
async def mass_assign_facets(
    body: MassAssignFacetsRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> list[AgentOut]:
    """Bulk-assign the searchable host facets — criticality, site and tags —
    across many selected hosts in one call (the 'select rows in a search
    result → tag/criticality/site them' flow). Same per-host manage ACL as
    mass_update_agent_groups."""
    if not body.agent_ids:
        raise HTTPException(status_code=422, detail="agent_ids must not be empty")
    if body.criticality not in (None, "", "test", "stage", "prod"):
        raise HTTPException(status_code=422, detail="criticality must be test|stage|prod or \"\" to clear")

    agents = (await session.scalars(select(Agent).where(Agent.id.in_(body.agent_ids)))).all()
    missing = set(body.agent_ids) - {a.id for a in agents}
    if missing:
        raise HTTPException(status_code=404, detail=f"no such agent(s): {sorted(str(m) for m in missing)}")
    for agent in agents:
        if not await user_can_manage_agent(session, identity, agent.id):
            raise HTTPException(status_code=403, detail=f"not authorized to manage host {agent.name!r}")

    for agent in agents:
        if body.criticality is not None:
            agent.criticality = body.criticality or None
        if body.site is not None:
            agent.site = body.site or None
        if body.add_tags or body.remove_tags:
            tags = dict(agent.tags or {})
            tags.update(body.add_tags)
            for k in body.remove_tags:
                tags.pop(k, None)
            agent.tags = tags

    await session.commit()
    return [AgentOut.from_model(a) for a in agents]


@router.get("/api/v1/agents/{agent_id}/disks")
async def get_agent_disks(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """The host's disk + partition layout (gparted-style Disks view, read-only):
    disks with their partitions (fs, mount, used/avail, flags), the partition-table
    type, and FREE segments. Live read over the agent (lsblk + parted)."""
    from bossman.services import disk_layout

    agent = await _get_agent_or_404(session, agent_id)
    return await disk_layout.read_disk_layout(agent, client_factory, settings)


class DiskPlanBody(BaseModel):
    """A gparted-style op queue. `allow_nonloop` must be set to touch a real disk;
    without it, apply refuses anything but a loopback scratch device."""
    ops: list = []
    allow_nonloop: bool = False


class ScratchBody(BaseModel):
    action: str = "create"           # create | destroy
    size_mb: int = 256
    device: str | None = None        # destroy: the loop device
    backing_file: str | None = None  # destroy: its backing file


@router.post("/api/v1/agents/{agent_id}/disks/preview")
async def preview_disk_plan(
    agent_id: UUID, body: DiskPlanBody, session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Compile the op queue to concrete commands + a safety verdict — nothing runs."""
    from bossman.services import disk_layout, disk_ops

    agent = await _get_agent_or_404(session, agent_id)
    layout = await disk_layout.read_disk_layout(agent, client_factory, settings)
    steps = disk_ops.compile({"ops": body.ops})
    problems = disk_ops.safety_check(steps, layout, allow_nonloop=body.allow_nonloop)
    return {"steps": steps, "problems": problems,
            "ok": not any(p["severity"] == "error" for p in problems)}


@router.post("/api/v1/agents/{agent_id}/disks/apply")
async def apply_disk_plan(
    agent_id: UUID, body: DiskPlanBody, session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Run the op queue on the host (guarded: loop-only unless allow_nonloop)."""
    from bossman.services import disk_layout, disk_ops

    agent = await _get_agent_or_404(session, agent_id)
    layout = await disk_layout.read_disk_layout(agent, client_factory, settings)
    return await disk_ops.apply(agent, client_factory, settings, {"ops": body.ops}, layout,
                                allow_nonloop=body.allow_nonloop)


class DiskToolsBody(BaseModel):
    """Binaries to provide — only ones the disk editor drives are accepted."""
    bins: list[str] = []


@router.post("/api/v1/agents/{agent_id}/disks/tools")
async def install_disk_tools(
    agent_id: UUID, body: DiskToolsBody, session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Install the packages that provide the disk tools a host is missing (the Disks
    view's "install missing tools" button). The read-only scan only REPORTS what is
    missing — installing on a mere page view would be a surprising side effect — while
    `disks/apply` still auto-installs whatever its plan needs."""
    from bossman.services import disk_ops

    agent = await _get_agent_or_404(session, agent_id)
    if not body.bins:
        raise HTTPException(422, "bins must not be empty")
    return await disk_ops.install_tools(agent, client_factory, settings, body.bins)


@router.post("/api/v1/agents/{agent_id}/disks/scratch")
async def disk_scratch(
    agent_id: UUID, body: ScratchBody, session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Create/destroy a throwaway loopback disk so partition ops can be tested for
    real without a spare disk."""
    from bossman.services import disk_ops

    agent = await _get_agent_or_404(session, agent_id)
    if body.action == "create":
        return await disk_ops.scratch_setup(agent, client_factory, settings, size_mb=body.size_mb)
    if body.action == "destroy":
        if not body.device:
            raise HTTPException(422, "destroy needs the loop device")
        return await disk_ops.scratch_teardown(agent, client_factory, settings,
                                               device=body.device, backing_file=body.backing_file or "")
    raise HTTPException(422, "action must be create|destroy")


@router.post("/api/v1/agents/{agent_id}/update")
async def update_agent(
    agent_id: UUID,
    file: UploadFile = File(...),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Push a new agent .deb to an ENROLLED host over the existing mTLS
    channel; the agent installs it (dpkg → postinst restart) and returns on
    the new version — the "Update" half of the deploy button. Works even for a
    write=false agent (the self-update carve-out). Requires a direct address +
    that the agent trusts Bossman's client cert (a satellite reachable only via
    its proxy has no direct address → 409; push it through its proxy or set an
    address)."""
    agent = await _get_agent_or_404(session, agent_id)
    if not agent.address:
        raise HTTPException(
            status_code=409,
            detail="agent has no direct address (satellite/unenrolled) — cannot push an update to it directly",
        )
    data = await file.read()
    if not data:
        raise HTTPException(status_code=422, detail="empty upload — select the agent .deb")
    client = client_factory(agent, settings)
    try:
        result = await client.self_update(data)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "result": result}


@router.post("/api/v1/agents/{agent_id}/update-bundled")
async def update_agent_bundled(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Push the package Bossman ships to an enrolled host — no upload needed. The
    right one is chosen by the host's OS family: RHEL/Fedora/SUSE get the .rpm
    (BOSSMAN_AGENT_RPM_PATH), everything else the .deb (BOSSMAN_AGENT_DEB_PATH).
    The agent installs whichever it receives (dpkg / rpm)."""
    from bossman.api.package_wizard import _family

    agent = await _get_agent_or_404(session, agent_id)
    if not agent.address:
        raise HTTPException(status_code=409, detail="agent has no direct address — cannot push an update to it directly")
    family = _family(agent.facts or {})
    path = settings.agent_rpm_path if family in ("redhat", "suse") else settings.agent_deb_path
    kind = "rpm" if family in ("redhat", "suse") else "deb"
    if not path:
        raise HTTPException(status_code=409, detail=f"no bundled {kind} configured (set BOSSMAN_AGENT_{kind.upper()}_PATH)")
    if not Path(path).is_file():
        raise HTTPException(status_code=409, detail=f"bundled {kind} not found at {path}")
    data = Path(path).read_bytes()
    client = client_factory(agent, settings)
    try:
        result = await client.self_update(data)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "family": family, "package": kind, "result": result}


class CollectConfigRequest(BaseModel):
    """A partial patch of the agent's self-configurable settings. Every field optional; only the ones
    provided are changed. It cannot touch the agent's auth, listen address or TLS (the agent's endpoint
    has no field for those). It CAN toggle the master `write` gate: a PXE-provisioned host enrols
    read-only, and this owner-scoped, mTLS-authenticated carve-out is the only way to enable writes
    without SSH so the host can converge its assigned roles."""

    write: bool | None = None    # master write gate — enable so a provisioned host can converge its roles
    services: bool | None = None
    psi: bool | None = None
    docker: bool | None = None
    drbd_devices: bool | None = None
    interval: str | None = None  # a Go duration string, e.g. "60s"


@router.post("/api/v1/agents/{agent_id}/collect-config")
async def set_agent_collect_config(
    agent_id: UUID,
    body: CollectConfigRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Change what this host collects and let its agent restart to apply — without SSH.

    The reason this exists: `update-bundled` replaces only the binary, config.yaml is noreplace, so
    turning off an unread high-cardinality family (service_* was 38.8% of the metrics DB) otherwise
    meant editing /etc/agentic-mcp/config.yaml on every host by hand. The agent's collect-config
    endpoint is a deliberate write-gate carve-out (like self-update), scoped strictly to the collect
    block, so a read-only host is still reconfigurable by its owner over the existing mTLS channel."""
    agent = await _get_agent_or_404(session, agent_id)
    if not agent.address:
        raise HTTPException(status_code=409, detail="agent has no direct address — cannot reach it")
    patch = body.model_dump(exclude_none=True)
    if not patch:
        raise HTTPException(status_code=422, detail="no collect settings provided")
    client = client_factory(agent, settings)
    try:
        result = await client.set_collect_config(patch)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "applied": patch, "result": result}


_SERVICE_ACTION_STATE = {"restart": "restarted", "stop": "stopped", "start": "started"}
# Block J4a — boot-state actions map to the systemd module's `enabled` param
# (no running-state change), so they can be issued independently of start/stop.
_SERVICE_ACTION_ENABLED = {"enable": True, "disable": False}


class ServiceControlRequest(BaseModel):
    service: str
    action: str  # restart | stop | start | enable | disable


@router.post("/api/v1/agents/{agent_id}/service-control")
async def service_control(
    agent_id: UUID,
    body: ServiceControlRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Block J2/J4a — safe service control. Restart/stop/start a systemd
    unit's running state, or enable/disable its start-at-boot state, on an
    enrolled host through the agent's idempotent `systemd` module (which is
    write-gated + ACL-checked + audited on the agent). No raw PID-kill
    (deliberate). A read-only agent (write=false) rejects it (surfaced as
    502 from the agent's 403)."""
    action = body.action.strip().lower()
    if action in _SERVICE_ACTION_STATE:
        tool_params: dict = {"state": _SERVICE_ACTION_STATE[action]}
    elif action in _SERVICE_ACTION_ENABLED:
        tool_params = {"enabled": _SERVICE_ACTION_ENABLED[action]}
    else:
        raise HTTPException(
            status_code=422,
            detail="action must be one of: restart, stop, start, enable, disable",
        )
    if not body.service.strip():
        raise HTTPException(status_code=422, detail="service must not be empty")
    agent = await _get_agent_or_404(session, agent_id)
    if not agent.address:
        raise HTTPException(status_code=409, detail="agent has no direct address (satellite/unenrolled)")
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("systemd", {"name": body.service.strip(), **tool_params})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "service": body.service.strip(), "action": action, "result": result}


class SyncModulesRequest(BaseModel):
    # None → push every translated module in the library; a list → just those.
    fqcns: list[str] | None = None


@router.post("/api/v1/agents/{agent_id}/modules/sync")
async def sync_agent_modules(
    agent_id: UUID,
    body: SyncModulesRequest | None = None,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Push the library's translated Starlark modules (or a given subset) to
    an enrolled host (Block G3), so it can EXECUTE them. Reads each module's
    .star + metadata sidecar from the library and delivers them over the
    existing mTLS channel; the agent validates, persists, and live-registers
    them. Requires a direct address (a proxy-only satellite → 409) and the
    agent's write gate open (the agent returns 403 otherwise, surfaced here)."""
    agent = await _get_agent_or_404(session, agent_id)
    if not agent.address:
        raise HTTPException(
            status_code=409,
            detail="agent has no direct address (satellite/unenrolled) — cannot push modules to it directly",
        )

    entries = module_library.list_modules(settings.modules_dir, settings.module_sources_dir)
    translated = [e for e in entries if e.get("translated")]
    if body and body.fqcns:
        wanted = set(body.fqcns)
        translated = [e for e in translated if e["fqcn"] in wanted]

    payload: list[dict] = []
    for entry in translated:
        fqcn = entry["fqcn"]
        try:
            mod = module_library.load_module(settings.modules_dir, fqcn)
            meta_path = Path(module_library.metadata_path(settings.modules_dir, fqcn))
            sidecar_text = meta_path.read_text(encoding="utf-8")
        except (module_library.ModuleLibraryError, OSError) as exc:
            raise HTTPException(status_code=500, detail=f"reading module {fqcn!r}: {exc}") from exc
        star_code = mod["star_code"]
        payload.append(
            {
                "fqcn": fqcn,
                "star": star_code,
                "sidecar": sidecar_text,
                # Always yaml — the only sidecar format left. Deriving it from the suffix kept a branch alive
                # for a file type nothing writes any more.
                "sidecar_format": "yaml",
                "sha256": hashlib.sha256(star_code.encode()).hexdigest(),
            }
        )

    if not payload:
        return {"pushed": 0, "result": {"applied": 0, "results": []}}

    client = client_factory(agent, settings)
    try:
        result = await client.push_modules(payload)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"pushed": len(payload), "result": result}


@router.post("/api/v1/agents/{agent_id}/poll-now")
async def poll_agent_now(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    session_factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _identity=Depends(require_manage_agent),
) -> dict:
    """Zabbix gap-analysis Block K5 ("Execute now"): force one agent to be
    polled immediately instead of waiting for the next
    settings.poll_interval_seconds tick — the same poll_agent the
    background loop uses (metrics/edges/hosts-overview pull, state
    evaluation, notification dispatch), just triggered on demand."""
    await _get_agent_or_404(session, agent_id)
    semaphore = asyncio.Semaphore(1)
    result: PollResult = await poll_agent(session_factory, agent_id, settings, semaphore, client_factory)
    return {
        "agent_id": result.agent_id,
        "agent_name": result.agent_name,
        "metrics_written": result.metrics_written,
        "satellites_discovered": result.satellites_discovered,
        "edges_written": result.edges_written,
        "errors": result.errors,
    }


@router.get("/api/v1/agents/{agent_id}/metrics")
async def get_agent_metrics(
    agent_id: UUID,
    metric: str | None = Query(None, description="Metric name to fetch points for; omit for catalog discovery"),
    since: datetime | None = Query(None, description="Only points at or after this time"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict:
    """This host's metrics: the catalogue, or the points of one series.

    **Two modes in one endpoint, and the parameter decides which.** Without `metric`
    you get the *catalogue* — which series this host has ever reported, so a caller
    can find out what is measurable before asking for numbers. With `metric` you get
    that series' points, optionally from `since` onwards.

    The catalogue is what a host *has reported*, not what it *could* report: a series
    appears once the first sample arrives and stays afterwards. For the newest sample
    of every series in one call, use `.../metrics/latest` instead of fanning out one
    request per name.
    """
    await _get_agent_or_404(session, agent_id)

    if metric is None:
        # Catalog discovery (see docs/plan.md's "Offene Punkte"): let a
        # caller find out what metric names exist for this agent before
        # asking for any specific one's history.
        # The SAME exclusion rule the fleet-wide /metric-catalog uses
        # (services/metrics_query.measurable_sql_filter): a check's 0/1/2/3 verdict and the
        # per-PID process_* series are not pickable metrics. This endpoint used to drop only
        # process_*, so the two catalogs answered "which metrics exist?" differently — and the
        # chart editor's picker had to filter check_*_state again on the client.
        names = (
            await session.scalars(
                select(Metric.metric)
                .where(Metric.agent_id == agent_id, measurable_sql_filter(Metric.metric))
                .distinct()
                .order_by(Metric.metric)
            )
        ).all()
        return {"metrics": list(names)}

    # Block K1b: a `since` reaching further back than raw metrics' 14-day
    # TimescaleDB retention transparently reads the metrics_hourly/
    # metrics_daily continuous aggregates instead of coming back empty.
    tier, points = await query_series(session, settings, agent_id, metric, since)
    return {
        "metric": metric,
        "resolution": tier,
        "points": [
            MetricPointOut(
                time=p.time, value=p.value, labels=p.labels, min_value=p.min_value, max_value=p.max_value
            ).model_dump()
            for p in points
        ],
    }


@router.get("/api/v1/agents/{agent_id}/metrics/latest")
async def get_agent_metrics_latest(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """The whole latest-data snapshot in one call: the newest sample of every
    metric this agent has ever reported. Powers the host-detail Metrics tab's
    list view (a metric name + last value + last check per row) so it no
    longer has to fan out one series request per metric just to show a
    value. `DISTINCT ON (metric)` + `time DESC` = Postgres' idiomatic
    latest-per-group; ordered by metric name for a stable list."""
    await _get_agent_or_404(session, agent_id)

    # process_* are per-PID history series (potentially hundreds); they power
    # the Processes tab's per-process chart via a dedicated endpoint, not this
    # aggregate list, so they're excluded here to keep the metric list clean.
    stmt = (
        select(Metric)
        .where(Metric.agent_id == agent_id, Metric.metric.not_like("process_%"))
        .order_by(Metric.metric, Metric.time.desc())
        .distinct(Metric.metric)
    )
    rows = (await session.scalars(stmt)).all()
    return {
        "metrics": [
            LatestMetricOut(metric=r.metric, time=r.time, value=r.value, labels=r.labels).model_dump() for r in rows
        ]
    }


@router.get("/api/v1/agents/{agent_id}/metrics/snapshot")
async def get_agent_metrics_snapshot(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """Latest sample per unique (metric, labels) SERIES — one row per filesystem
    for disk_used_pct, one per check_*_state — powering the host Overview
    cockpit's per-mount gauges + services grid.

    Served straight off the normalized base tables (`metrics_raw` + `metric_series`)
    with DISTINCT ON (series_id), which rides the series_id segmentation +
    time-DESC ordering instead of sorting the (metric, labels) view — and bounded
    to the last hour so it scans only recent chunks. Measured on docker-test:
    540ms (old, view, full 2-day scan) → ~30ms. The 1h window also drops genuinely
    STALE series (removed containers' PSI, ended-flow eBPF histograms) that a live
    cockpit should not show; every polled vital/check reports far more often than
    hourly, so nothing live is lost."""
    await _get_agent_or_404(session, agent_id)
    since = datetime.now(timezone.utc) - timedelta(hours=1)
    stmt = (
        select(MetricSeries.metric, MetricSeries.labels, MetricRaw.time, MetricRaw.value)
        .join(MetricRaw, MetricRaw.series_id == MetricSeries.series_id)
        .where(
            MetricSeries.agent_id == agent_id,
            MetricSeries.metric.not_like("process_%"),
            MetricRaw.time > since,
        )
        .order_by(MetricRaw.series_id, MetricRaw.time.desc())
        .distinct(MetricRaw.series_id)
    )
    rows = (await session.execute(stmt)).all()
    return {
        "metrics": [
            LatestMetricOut(metric=r.metric, time=r.time, value=r.value, labels=r.labels).model_dump() for r in rows
        ]
    }

class HostParentsRequest(BaseModel):
    parent_agent_ids: list[UUID]


class HostParentsOut(BaseModel):
    agent_id: UUID
    # Explicitly configured parents only.
    parent_agent_ids: list[UUID]
    # Everything treated as a parent when judging reachability, including the implicit proxy
    # relation — which is what the poller actually uses, so it is what an operator needs to
    # see. Names, because an id tells nobody anything.
    effective_parents: list[str]


@router.get("/api/v1/agents/{agent_id}/parents", response_model=HostParentsOut)
async def get_host_parents(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> HostParentsOut:
    """L6: this host's reachability parents. A host that cannot be reached while ALL of its
    parents are down is UNREACHABLE rather than DOWN, and does not page."""
    from bossman.db.models import HostParent
    from bossman.services.monitoring import parent_ids

    agent = await _get_agent_or_404(session, agent_id)
    explicit = list(
        (
            await session.scalars(
                select(HostParent.parent_agent_id).where(HostParent.child_agent_id == agent_id)
            )
        ).all()
    )
    effective = await parent_ids(session, agent)
    names = list(
        (await session.scalars(select(Agent.name).where(Agent.id.in_(effective)))).all()
    ) if effective else []
    return HostParentsOut(agent_id=agent_id, parent_agent_ids=explicit, effective_parents=sorted(names))


@router.put("/api/v1/agents/{agent_id}/parents", response_model=HostParentsOut)
async def set_host_parents(
    agent_id: UUID,
    body: HostParentsRequest,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(require_manage_agent),
) -> HostParentsOut:
    """Replaces the explicit parent list. A cycle is refused: a host that is (transitively)
    its own parent could never be judged, since "are all my parents down" would never
    terminate — and a self-parent would additionally excuse its own outage forever."""
    from bossman.db.models import HostParent

    await _get_agent_or_404(session, agent_id)
    wanted = list(dict.fromkeys(body.parent_agent_ids))
    for parent_id in wanted:
        if parent_id == agent_id:
            raise HTTPException(status_code=422, detail="a host cannot be its own parent")
        if await session.get(Agent, parent_id) is None:
            raise HTTPException(status_code=422, detail=f"no such host {parent_id}")
        if await _would_cycle(session, agent_id, parent_id):
            raise HTTPException(
                status_code=422,
                detail="that would create a parent cycle (the host is already an ancestor of this parent)",
            )
    await session.execute(text("DELETE FROM host_parents WHERE child_agent_id = :id"), {"id": str(agent_id)})
    for parent_id in wanted:
        session.add(HostParent(child_agent_id=agent_id, parent_agent_id=parent_id))
    await session.commit()
    return await get_host_parents(agent_id, session, _identity)


async def _would_cycle(session: AsyncSession, child_id: UUID, parent_id: UUID) -> bool:
    """Walk up from `parent_id`: does `child_id` appear as an ancestor? Bounded by `seen`, so
    an already-corrupt graph cannot make this loop forever either."""
    from bossman.db.models import HostParent

    seen: set[UUID] = set()
    frontier = [parent_id]
    while frontier:
        current = frontier.pop()
        if current == child_id:
            return True
        if current in seen:
            continue
        seen.add(current)
        rows = list(
            (
                await session.scalars(
                    select(HostParent.parent_agent_id).where(HostParent.child_agent_id == current)
                )
            ).all()
        )
        agent = await session.get(Agent, current)
        if agent is not None and agent.parent_agent_id:
            rows.append(agent.parent_agent_id)
        frontier.extend(rows)
    return False
