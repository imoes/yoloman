"""Block 3 — SNMP devices: agent-less network devices (switches, printers, PDUs)
monitored via SNMP checks that the co-located poller agent runs on their behalf.

A device is modelled as a satellite Agent row (mode=satellite, parent=the poller
agent, no address/token) tagged agent_metadata.kind="snmp" with its target +
community. Assigning an SNMP check to the device (agent-scoped CheckAssignment)
makes the poller run it each cycle with the device's target/community merged in
(Block 2b retargeting), attributing the resulting Service to the device — so the
device shows up as a monitored host in the fleet like any other.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, CheckAssignment, Service, ServiceStateHistory, DEFAULT_TENANT_ID
from bossman.db.session import get_session

router = APIRouter()


class SnmpDeviceIn(BaseModel):
    name: str
    target: str  # device IP / hostname the poller reaches over SNMP
    community: str = "public"  # v2c community (v3 not modelled yet)
    check_names: list[str] = []  # SNMP checks to assign


class SnmpDeviceOut(BaseModel):
    id: UUID
    name: str
    target: str
    community: str
    check_names: list[str]
    last_seen_at: Any | None


def _is_snmp(a: Agent) -> bool:
    return (a.agent_metadata or {}).get("kind") == "snmp"


async def _device_checks(session: AsyncSession, agent_id: UUID) -> list[str]:
    return list(
        (await session.scalars(
            select(CheckAssignment.check_name).where(CheckAssignment.agent_id == agent_id)
        )).all()
    )


def _to_out(a: Agent, checks: list[str]) -> SnmpDeviceOut:
    meta = a.agent_metadata or {}
    return SnmpDeviceOut(
        id=a.id, name=a.name, target=meta.get("snmp_target", ""),
        community=meta.get("snmp_community", "public"), check_names=checks, last_seen_at=a.last_seen_at,
    )


@router.get("/api/v1/snmp-devices", response_model=list[SnmpDeviceOut])
async def list_snmp_devices(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[SnmpDeviceOut]:
    agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
    out = []
    for a in agents:
        if _is_snmp(a):
            out.append(_to_out(a, await _device_checks(session, a.id)))
    return out


@router.post("/api/v1/snmp-devices", response_model=SnmpDeviceOut)
async def create_snmp_device(
    body: SnmpDeviceIn,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> SnmpDeviceOut:
    name = body.name.strip()
    target = body.target.strip()
    if not name or not target:
        raise HTTPException(status_code=422, detail="name and target are required")
    if await session.scalar(select(Agent).where(Agent.name == name)):
        raise HTTPException(status_code=409, detail=f"an agent/device named {name!r} already exists")

    poller = await session.scalar(select(Agent).where(Agent.name == settings.poller_agent_name))
    if poller is None:
        raise HTTPException(status_code=503, detail=f"poller agent {settings.poller_agent_name!r} not enrolled yet")

    device = Agent(
        name=name,
        address=None,
        token="",  # never polled directly — the poller reaches it over SNMP
        mode="satellite",
        parent_agent_id=poller.id,
        enrollment_state="enrolled",
        agent_metadata={"kind": "snmp", "snmp_target": target, "snmp_community": body.community or "public"},
    )
    session.add(device)
    await session.flush()

    for cn in dict.fromkeys(body.check_names):  # de-dup, keep order
        session.add(CheckAssignment(
            tenant_id=DEFAULT_TENANT_ID, check_name=cn, scope_type="host",
            agent_id=device.id, parameters={}, source="snmp-device",
        ))
    await session.commit()
    return _to_out(device, await _device_checks(session, device.id))


@router.delete("/api/v1/snmp-devices/{device_id}")
async def delete_snmp_device(
    device_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    device = await session.get(Agent, device_id)
    if device is None or not _is_snmp(device):
        raise HTTPException(status_code=404, detail="no such SNMP device")
    await session.execute(delete(CheckAssignment).where(CheckAssignment.agent_id == device_id))
    await session.execute(delete(ServiceStateHistory).where(ServiceStateHistory.agent_id == device_id))
    await session.execute(delete(Service).where(Service.agent_id == device_id))
    await session.delete(device)
    await session.commit()
    return {"deleted": str(device_id)}
