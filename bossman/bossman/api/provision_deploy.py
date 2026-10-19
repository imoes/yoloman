"""The deploy wizard's REST surface — the same implementation as the MCP tools vm_hosts, check_ip, suggest_free_ips,
deploy_vm and deployment_status (services/vm_provision.py, services/ip_check.py, services/netinstall.py).

A person in the wizard is a human caller: a finalization runbook may apply without YOLO mode, as with
POST /api/v1/agents/{id}/runbook/run. Every other rule (pre-flight checks, DHCP only for the new MAC, package and
memory checks) is the one the MCP tool applies, because it is the same code.
"""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import DiskImage, Runbook, VmHost
from bossman.db.session import get_session

router = APIRouter()


@router.get("/api/v1/provisioning/catalog")
async def deploy_catalog(placement: bool = True, session: AsyncSession = Depends(get_session),
                         _identity=Depends(get_current_identity)) -> dict[str, Any]:
    """Everything the wizard offers: hypervisors (with nodes, storages, bridges), golden images, network installs
    (with default packages and minimum memory) and the stored runbooks a deployment can be finalized with."""
    from bossman.services import hypervisor, netinstall
    from bossman.services import vm_provision as vp

    hosts = []
    for h in (await session.scalars(select(VmHost).order_by(VmHost.name))).all():
        row: dict[str, Any] = {"name": h.name, "kind": h.kind, "host": h.host}
        if placement:
            try:
                row["placement"] = await vp.client_for(h).placement()
            except hypervisor.HypervisorError as exc:
                row["placement_error"] = str(exc)[:300]
        hosts.append(row)
    from bossman.api.images import ImageOut
    from bossman.db.models import OrchestrationPlan

    # Images with their volumes and saved sizing: the wizard's sizing step edits a deployment's own copy.
    images = [{**ImageOut.from_model(i).model_dump(mode="json", include={"id", "name", "status", "description",
                                                                         "volumes", "grow_policy", "grow_mode",
                                                                         "disk_size", "firmware"})}
              for i in (await session.scalars(select(DiskImage).order_by(DiskImage.name))).all()]
    # The roles deploy() can bind (OrchestrationPlans of type role) — the same set its "role <name>" check uses.
    roles = [{"name": r.name, "display_name": r.display_name or r.name}
             for r in (await session.scalars(select(OrchestrationPlan).where(OrchestrationPlan.plan_type == "role")
                                             .order_by(OrchestrationPlan.name))).all()]
    runbooks = [{"name": r.name, "folder": r.folder, "description": (r.doc or {}).get("description", "")
                 if isinstance(r.doc, dict) else ""}
                for r in (await session.scalars(select(Runbook).order_by(Runbook.name))).all()]
    return {"vm_hosts": hosts, "images": images, "installs": netinstall.catalog(), "runbooks": runbooks, "roles": roles}


@router.get("/api/v1/provisioning/installs/{install}")
async def resolve_install(install: str, settings: Settings = Depends(get_settings),
                          _identity=Depends(get_current_identity)) -> dict[str, Any]:
    """The release `install` resolves to now (newest stable/LTS when no release is named) and its default packages
    with the ones its repositories lack — so the wizard shows "Ubuntu 26.04.1 LTS" before anything is created."""
    from bossman.services import netinstall

    try:
        distro, release = netinstall.parse_install(install)
        rel = await netinstall.resolve_release(settings, distro, release)
        pkgs, missing = await netinstall.missing_packages(settings, rel, None)
    except netinstall.NetinstallError as exc:
        raise HTTPException(status_code=exc.status, detail=str(exc)) from exc
    return {**rel, "default_packages": pkgs, "missing_packages": missing,
            "min_memory_mb": netinstall.DRIVERS[distro].min_memory_mb}


class CheckIpIn(BaseModel):
    addresses: list[str]
    prefix_len: int = 24


@router.post("/api/v1/provisioning/check-ip")
async def check_ip(body: CheckIpIn, session: AsyncSession = Depends(get_session),
                   settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
                   _identity=Depends(get_current_identity)) -> list[dict[str, Any]]:
    from bossman.services import ip_check

    try:
        return await ip_check.check(session, settings, client_factory, body.addresses, body.prefix_len)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/api/v1/provisioning/suggest-ips")
async def suggest_ips(prefix: str, count: int = 5, session: AsyncSession = Depends(get_session),
                      settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
                      _identity=Depends(get_current_identity)) -> dict[str, Any]:
    from bossman.services import ip_check

    try:
        return await ip_check.suggest(session, settings, client_factory, prefix, count)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


class DeployIn(BaseModel):
    target: str = "vm"          # vm | bare_metal
    vm_host: str = ""
    node: str = ""
    name: str
    storage: str = ""
    bridge: str = ""
    mac: str = ""               # bare metal
    address: str
    gateway: str
    dns: list[str] = []
    image: str | None = None
    install: str | None = None
    vlan: int | None = None
    hostname: str | None = None
    cores: int = 2
    memory_mb: int = 2048
    disk_gib: int = 32
    uefi: bool = False
    roles: list[Any] = []       # names or {"name", "params"}
    grow_policy: dict[str, int] | None = None
    grow_mode: str = "percent"
    production_vlan: int | None = None
    production_bridge: str | None = None
    packages: list[str] | None = None
    write: bool = True
    finalize_runbook: str | None = None
    finalize_variables: dict[str, Any] = {}
    finalize_apply: bool = False
    dry_run: bool = True


@router.post("/api/v1/provisioning/deploy")
async def deploy(body: DeployIn, session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
                 client_factory=Depends(get_client_factory), identity=Depends(get_current_identity)) -> dict[str, Any]:
    """dry_run=true (default): every pre-flight check, nothing created. dry_run=false: refused (409 with the checks)
    while one fails, then the VM is created and the restore or install armed."""
    from bossman.services import vm_provision as vp

    try:
        out = await vp.deploy(session, settings, client_factory, req=body.model_dump(),
                              requested_by=getattr(identity, "name", "wizard"), ai=False)
    except vp.ProvisionError as exc:
        raise HTTPException(status_code=exc.status, detail=str(exc)) from exc
    if not body.dry_run and not out.get("ok", True):
        raise HTTPException(status_code=409, detail={"message": "pre-flight checks failed", "checks": out["checks"]})
    return out


@router.get("/api/v1/provisioning/deployments/{hostname}")
async def deployment_status(hostname: str, request: Request, session: AsyncSession = Depends(get_session),
                            settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
                            _identity=Depends(get_current_identity)) -> dict[str, Any]:
    from bossman.services import finalize, vm_provision as vp

    await finalize.kick(session, session_factory=request.app.state.session_factory, settings=settings,
                        client_factory=client_factory)
    try:
        return await vp.status(session, hostname)
    except vp.ProvisionError as exc:
        raise HTTPException(status_code=exc.status, detail=str(exc)) from exc


@router.get("/api/v1/provisioning/deployments")
async def list_deployments(request: Request, limit: int = 50, session: AsyncSession = Depends(get_session),
                           settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
                           _identity=Depends(get_current_identity)) -> list[dict[str, Any]]:
    """Recent deployments, newest first: network installs and image restores with their state, the finalization's
    state and whether the new host has reported — what the deployments page lists."""
    from bossman.db.models import Agent, DeployFinalization, NetinstallJob, RestoreJob
    from bossman.services import finalize, netinstall

    await netinstall.reconcile(session)
    await finalize.kick(session, session_factory=request.app.state.session_factory, settings=settings,
                        client_factory=client_factory)
    rows: list[dict[str, Any]] = []
    for j in (await session.scalars(select(NetinstallJob).order_by(NetinstallJob.created_at.desc()).limit(limit))).all():
        label = netinstall.job_files(j)["release"].get("label") or f"{j.distro} {j.release}"
        rows.append({"hostname": j.hostname, "kind": "install", "os": label, "status": j.status, "error": j.error,
                     "address": (j.network or {}).get("address"), "mac": j.target_mac, "vmid": j.vm_id,
                     "agent_id": str(j.agent_id) if j.agent_id else None,
                     "created_at": j.created_at.isoformat(), "finished_at": j.finished_at.isoformat() if j.finished_at else None})
    images = {i.id: i.name for i in (await session.scalars(select(DiskImage))).all()}
    for j in (await session.scalars(select(RestoreJob).order_by(RestoreJob.created_at.desc()).limit(limit))).all():
        rows.append({"hostname": j.target_hostname, "kind": "image", "os": images.get(j.image_id, "image"),
                     "status": j.status, "error": j.error, "address": None, "mac": j.target_mac, "vmid": j.vm_id,
                     "agent_id": str(j.agent_id) if j.agent_id else None, "created_at": j.created_at.isoformat(),
                     "finished_at": j.finished_at.isoformat() if j.finished_at else None})
    rows.sort(key=lambda r: r["created_at"], reverse=True)
    rows = rows[:limit]
    fins: dict[str, DeployFinalization] = {}
    for f in (await session.scalars(select(DeployFinalization).order_by(DeployFinalization.created_at))).all():
        fins[f.hostname] = f
    for r in rows:
        agent = await session.get(Agent, uuid.UUID(r["agent_id"])) if r["agent_id"] else None
        r["last_seen_at"] = agent.last_seen_at.isoformat() if agent and agent.last_seen_at else None
        r["agent_version"] = agent.agent_version if agent else None
        f = fins.get(r["hostname"])
        r["finalize"] = {"runbook": f.runbook, "status": f.status, "apply": f.apply, "error": f.error} if f else None
    return rows
