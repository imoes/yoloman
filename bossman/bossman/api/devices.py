"""Block 3 — agent-less monitored devices: network gear/hosts that run no agent
and are polled on their behalf by the co-located poller agent. Two kinds:

- **snmp**: switches/printers/PDUs polled over SNMP (target + v2c community).
- **ssh**: hosts reached over SSH (target + user + password/key) — for the SSH
  datasource checks (the poller runs sshpass/ssh-based checks against them).

A device is a satellite Agent row (parent = the poller, no address/token,
agent_metadata.kind = snmp|ssh + its connection params). Assigning a check to
the device (agent-scoped CheckAssignment) makes the poller run it each cycle
with the device's connection params merged in (Block 2b retargets SNMP), and the
resulting Services attribute to the device — so it shows up as a monitored host.
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

_KINDS = ("snmp", "ssh")


class DeviceIn(BaseModel):
    name: str
    kind: str = "snmp"  # snmp | ssh
    target: str  # IP / hostname the poller reaches
    community: str = "public"  # snmp v2c community
    user: str = ""  # ssh user
    password: str = ""  # ssh password (key auth is a follow-up)
    check_names: list[str] = []


class DeviceOut(BaseModel):
    id: UUID
    name: str
    kind: str
    target: str
    community: str
    user: str
    check_names: list[str]
    last_seen_at: Any | None


def _is_device(a: Agent) -> bool:
    return (a.agent_metadata or {}).get("kind") in _KINDS


async def _device_checks(session: AsyncSession, agent_id: UUID) -> list[str]:
    return list(
        (await session.scalars(
            select(CheckAssignment.check_name).where(CheckAssignment.agent_id == agent_id)
        )).all()
    )


def _to_out(a: Agent, checks: list[str]) -> DeviceOut:
    meta = a.agent_metadata or {}
    return DeviceOut(
        id=a.id, name=a.name, kind=meta.get("kind", "snmp"),
        target=meta.get("target", meta.get("snmp_target", "")),
        community=meta.get("community", meta.get("snmp_community", "public")),
        user=meta.get("user", ""), check_names=checks, last_seen_at=a.last_seen_at,
    )


@router.get("/api/v1/devices", response_model=list[DeviceOut])
async def list_devices(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[DeviceOut]:
    agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
    return [_to_out(a, await _device_checks(session, a.id)) for a in agents if _is_device(a)]


@router.post("/api/v1/devices", response_model=DeviceOut)
async def create_device(
    body: DeviceIn,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> DeviceOut:
    name = body.name.strip()
    target = body.target.strip()
    if body.kind not in _KINDS:
        raise HTTPException(status_code=422, detail=f"kind must be one of {_KINDS}")
    if not name or not target:
        raise HTTPException(status_code=422, detail="name and target are required")
    if await session.scalar(select(Agent).where(Agent.name == name)):
        raise HTTPException(status_code=409, detail=f"an agent/device named {name!r} already exists")

    poller = await session.scalar(select(Agent).where(Agent.name == settings.poller_agent_name))
    if poller is None:
        raise HTTPException(status_code=503, detail=f"poller agent {settings.poller_agent_name!r} not enrolled yet")

    # Connection params live in metadata under generic keys the poller reads;
    # snmp_* aliases stay for back-compat with pre-generalisation devices.
    meta: dict[str, Any] = {"kind": body.kind, "target": target}
    if body.kind == "snmp":
        meta.update(community=body.community or "public", snmp_target=target, snmp_community=body.community or "public")
    else:  # ssh
        meta.update(user=body.user, password=body.password)

    device = Agent(
        name=name, address=None, token="", mode="satellite",
        parent_agent_id=poller.id, enrollment_state="enrolled", agent_metadata=meta,
    )
    session.add(device)
    await session.flush()

    for cn in dict.fromkeys(body.check_names):
        session.add(CheckAssignment(
            tenant_id=DEFAULT_TENANT_ID, check_name=cn, scope_type="host",
            agent_id=device.id, parameters={}, source="device",
        ))
    await session.commit()
    return _to_out(device, await _device_checks(session, device.id))


@router.delete("/api/v1/devices/{device_id}")
async def delete_device(
    device_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    device = await session.get(Agent, device_id)
    if device is None or not _is_device(device):
        raise HTTPException(status_code=404, detail="no such device")
    await session.execute(delete(CheckAssignment).where(CheckAssignment.agent_id == device_id))
    await session.execute(delete(ServiceStateHistory).where(ServiceStateHistory.agent_id == device_id))
    await session.execute(delete(Service).where(Service.agent_id == device_id))
    await session.delete(device)
    await session.commit()
    return {"deleted": str(device_id)}
