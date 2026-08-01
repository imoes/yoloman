"""PXE nested-virt lab endpoints — install a template from an ISO, PXE-test a target end-to-end,
list and stop lab VMs. Bossman drives QEMU inside the pxe container via services/vm_lab.py; these
routes are the HTTP surface the disk-templates UI (noVNC console) calls. See docs/pxe-baremetal-imaging.md.

All routes 503 when the lab is not configured (BOSSMAN_PXE_CONTAINER empty), so a deployment without
the pxe profile degrades cleanly rather than 500-ing.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from bossman.api.auth import get_current_identity
from bossman.services import vm_lab

router = APIRouter()


class InstallIn(BaseModel):
    name: str = Field(..., description="VM name (also the disk/console handle)")
    iso: str = Field(..., description="Installer ISO filename in the lab's ISO dir")
    disk: str = Field(..., description="Template disk filename to create/attach")
    disk_gib: int = Field(40, ge=1, le=4096)


class PxeTestIn(BaseModel):
    name: str
    mac: str = Field(..., description="NIC MAC the DHCP/PXE flow keys on")
    disk: str = Field(..., description="Blank target disk to receive the restore")
    disk_gib: int = Field(60, ge=1, le=4096)


class VmOut(BaseModel):
    name: str
    display: int
    vnc_port: int
    ws_port: int
    kind: str
    disk: str


def _err(exc: vm_lab.VmLabError) -> HTTPException:
    # "not configured" is a 503 (the lab is optional); anything else is a 400 (bad request/args).
    msg = str(exc)
    code = 503 if "not configured" in msg else 400
    return HTTPException(status_code=code, detail=msg)


@router.post("/api/v1/vm/install", response_model=str)
async def vm_install(body: InstallIn, _identity=Depends(get_current_identity)) -> str:
    try:
        return await vm_lab.install(body.name, body.iso, body.disk, body.disk_gib)
    except vm_lab.VmLabError as exc:
        raise _err(exc)


@router.post("/api/v1/vm/pxe-test", response_model=str)
async def vm_pxe_test(body: PxeTestIn, _identity=Depends(get_current_identity)) -> str:
    try:
        return await vm_lab.pxe_test(body.name, body.mac, body.disk, body.disk_gib)
    except vm_lab.VmLabError as exc:
        raise _err(exc)


@router.get("/api/v1/vm", response_model=list[VmOut])
async def vm_list(_identity=Depends(get_current_identity)) -> list[dict]:
    try:
        return await vm_lab.list_vms()
    except vm_lab.VmLabError as exc:
        raise _err(exc)


@router.post("/api/v1/vm/{name}/stop", response_model=str)
async def vm_stop(name: str, _identity=Depends(get_current_identity)) -> str:
    try:
        return await vm_lab.stop(name)
    except vm_lab.VmLabError as exc:
        raise _err(exc)
