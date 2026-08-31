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


_SNMP_VERSIONS = ("v2c", "v3")
_SEC_LEVELS = ("noAuthNoPriv", "authNoPriv", "authPriv")


class DeviceIn(BaseModel):
    name: str
    kind: str = "snmp"  # snmp | ssh
    target: str  # IP / hostname the poller reaches
    # SNMP: v2c uses `community`; v3 uses the USM security params below.
    snmp_version: str = "v2c"  # v2c | v3
    community: str = "public"  # snmp v2c community
    sec_level: str = "authPriv"  # v3: noAuthNoPriv | authNoPriv | authPriv
    sec_name: str = ""  # v3 USM user
    auth_proto: str = "SHA"  # v3: MD5 | SHA | SHA-224/256/384/512 (net-snmp -a)
    auth_pass: str = ""  # v3 auth passphrase (-A)
    priv_proto: str = "AES"  # v3: DES | AES | AES-192/256 (net-snmp -x)
    priv_pass: str = ""  # v3 privacy passphrase (-X)
    context: str = ""  # v3 context name (-n), optional
    user: str = ""  # ssh user
    password: str = ""  # ssh password (key auth is a follow-up)
    check_names: list[str] = []


class DeviceOut(BaseModel):
    id: UUID
    name: str
    kind: str
    target: str
    snmp_version: str
    community: str
    # v3 params — passphrases are NEVER returned (only whether they are set), the
    # same posture as the netboot secret.
    sec_level: str
    sec_name: str
    auth_proto: str
    priv_proto: str
    context: str
    auth_pass_set: bool
    priv_pass_set: bool
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
        snmp_version=meta.get("snmp_version", "v2c"),
        community=meta.get("community", meta.get("snmp_community", "public")),
        sec_level=meta.get("sec_level", "authPriv"),
        sec_name=meta.get("sec_name", ""),
        auth_proto=meta.get("auth_proto", "SHA"),
        priv_proto=meta.get("priv_proto", "AES"),
        context=meta.get("context", ""),
        auth_pass_set=bool(meta.get("auth_pass")),
        priv_pass_set=bool(meta.get("priv_pass")),
        user=meta.get("user", ""), check_names=checks, last_seen_at=a.last_seen_at,
    )


@router.get("/api/v1/devices", response_model=list[DeviceOut])
async def list_devices(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[DeviceOut]:
    """Agent-less devices: switches, printers, PDUs and SSH-only hosts.

    Each is polled **on its behalf** by the co-located poller agent — `snmp` (target plus community
    or v3 credentials) or `ssh` (target plus user and secret). They appear as hosts with services, so
    a switch's problem is acknowledged the same way a server's is; what differs is who does the
    measuring.
    """
    agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
    return [_to_out(a, await _device_checks(session, a.id)) for a in agents if _is_device(a)]


@router.post("/api/v1/devices", response_model=DeviceOut)
async def create_device(
    body: DeviceIn,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> DeviceOut:
    """Register an agent-less device to be polled by the poller agent.

    Secrets are stored with the device and **never returned** — a read reports only whether one is
    set. 409 when a host or device of that name already exists: two things answering to one name is
    how a check ends up polling the wrong box.
    """
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
        version = body.snmp_version if body.snmp_version in _SNMP_VERSIONS else "v2c"
        meta.update(snmp_version=version, snmp_target=target)
        if version == "v3":
            if body.sec_level not in _SEC_LEVELS:
                raise HTTPException(status_code=422, detail=f"sec_level must be one of {_SEC_LEVELS}")
            if not body.sec_name.strip():
                raise HTTPException(status_code=422, detail="sec_name (SNMPv3 user) is required for v3")
            meta.update(
                sec_level=body.sec_level, sec_name=body.sec_name.strip(),
                auth_proto=body.auth_proto, auth_pass=body.auth_pass,
                priv_proto=body.priv_proto, priv_pass=body.priv_pass,
                context=body.context.strip(),
            )
        else:
            meta.update(community=body.community or "public", snmp_community=body.community or "public")
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
    """Forget a device. Nothing is touched on the device itself — this stops the polling and
    removes its services, and the switch keeps switching."""
    device = await session.get(Agent, device_id)
    if device is None or not _is_device(device):
        raise HTTPException(status_code=404, detail="no such device")
    await session.execute(delete(CheckAssignment).where(CheckAssignment.agent_id == device_id))
    await session.execute(delete(ServiceStateHistory).where(ServiceStateHistory.agent_id == device_id))
    await session.execute(delete(Service).where(Service.agent_id == device_id))
    await session.delete(device)
    await session.commit()
    return {"deleted": str(device_id)}
