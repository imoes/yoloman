"""PXE nested-virt lab endpoints — install a template from an ISO, PXE-test a target end-to-end,
list and stop lab VMs. Bossman drives QEMU inside the pxe container via services/vm_lab.py; these
routes are the HTTP surface the disk-templates UI (noVNC console) calls. See docs/pxe-baremetal-imaging.md.

All routes 503 when the lab is not configured (BOSSMAN_PXE_CONTAINER empty), so a deployment without
the pxe profile degrades cleanly rather than 500-ing.
"""

from __future__ import annotations

import asyncio
import logging

import websockets
from fastapi import APIRouter, Depends, HTTPException, WebSocket
from pydantic import BaseModel, Field

from bossman.api.auth import get_current_identity
from bossman.config import get_settings
from bossman.services import vm_lab
from bossman.services.auth import AuthError, resolve_identity

logger = logging.getLogger(__name__)
router = APIRouter()

# Application-defined WS close codes surfaced to the noVNC page (mirrors api/console.py).
CLOSE_UNAUTHENTICATED = 4401
CLOSE_NO_VM = 4404
CLOSE_UPSTREAM = 4502


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


@router.websocket("/api/v1/vm/{name}/vnc")
async def vm_vnc(websocket: WebSocket, name: str) -> None:
    """Relay the browser's noVNC RFB WebSocket to the VM's websockify bridge in the pxe container.

    The bridge listens on the ens19 IP (not browser-reachable), so Bossman proxies it — the same
    pattern as the agent console (api/console.py), with the bearer token in the `token` query param
    since a browser can't set an Authorization header on a WebSocket. Frames are binary (RFB)."""
    settings = get_settings()
    token = websocket.query_params.get("token", "")
    if not token:
        await websocket.close(code=CLOSE_UNAUTHENTICATED)
        return
    async with websocket.app.state.session_factory() as session:
        try:
            await resolve_identity(session, settings, token)
        except AuthError:
            await websocket.close(code=CLOSE_UNAUTHENTICATED)
            return
    try:
        vms = await vm_lab.list_vms()
    except vm_lab.VmLabError:
        await websocket.close(code=CLOSE_NO_VM)
        return
    vm = next((v for v in vms if v.get("name") == name), None)
    if not vm:
        await websocket.close(code=CLOSE_NO_VM)
        return

    uri = f"ws://{settings.pxe_vnc_host}:{int(vm['ws_port'])}/"
    await websocket.accept(subprotocol="binary")
    try:
        async with websockets.connect(uri, max_size=None) as upstream:
            await _relay(websocket, upstream)
    except (OSError, websockets.WebSocketException) as exc:
        logger.warning("vnc upstream failed for %s: %s", name, exc)
        await websocket.close(code=CLOSE_UPSTREAM)


async def _relay(browser: WebSocket, upstream: "websockets.ClientConnection") -> None:
    """Pump frames both ways until either side closes (verbatim; RFB is binary)."""

    async def browser_to_upstream() -> None:
        while True:
            msg = await browser.receive()
            if msg["type"] == "websocket.disconnect":
                return
            if msg.get("bytes") is not None:
                await upstream.send(msg["bytes"])
            elif msg.get("text") is not None:
                await upstream.send(msg["text"])

    async def upstream_to_browser() -> None:
        async for msg in upstream:
            if isinstance(msg, bytes):
                await browser.send_bytes(msg)
            else:
                await browser.send_text(msg)

    tasks = [asyncio.create_task(browser_to_upstream()), asyncio.create_task(upstream_to_browser())]
    try:
        _done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
