"""Bare-metal deployment: golden images and the machines installed from them.

Three audiences, and they authenticate differently, which is the main thing to understand here:

* **Operators** manage images and create restore jobs — normal bearer auth like the rest of the API.
* **A netbooted target** checks in and reports progress. It has no token, no certificate and no
  identity beyond its MAC address; it presents the shared `netboot_secret` its PXE configuration put
  on the kernel command line. Empty secret ⇒ refused (see config for what that secret is and is not
  worth).
* The **capture** itself runs on a source host through the agent, which already has mTLS.

The plan for a restore is computed at **check-in**, not when the job is created, because the target
disk is not known until the machine boots and says what it has. That is also why the job carries its
computed steps: a retry then repeats exactly what was attempted, and a failure names the step rather
than a line number.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import get_settings
from bossman.db.models import SYSTEM_SETTINGS_ID, Agent, DeploymentTemplate, DiskImage, RestoreJob, SystemSettings, VmHost
from bossman.db.session import get_session
from bossman.services import hypervisor, imaging, offline_enroll, vm_lab
from bossman.services.vault import Vault

router = APIRouter()


def _firmware_of(manifest: dict) -> str:
    """Which boot path a captured image expects, read straight from the manifest — no re-inspection.

    UEFI leaves a fingerprint the capture already recorded: an EFI System Partition, which
    imaging._sfdisk_kind classifies as `uefi`. Its presence is the reliable signal; a BIOS disk (whether
    a plain DOS/MBR label or a GPT disk carrying a bios_boot partition) has no ESP. We only claim `unknown`
    when there are no partitions at all (an import that never recorded a table), rather than guessing.
    """
    parts = manifest.get("partitions")
    if not isinstance(parts, list) or not parts:
        return "unknown"
    if any((p or {}).get("kind") == "uefi" for p in parts):
        return "uefi"
    return "bios"


# ---------------------------------------------------------------------------
# Images


class ImageIn(BaseModel):
    name: str
    description: str = ""
    source_agent_id: UUID | None = None


class ImagePatch(BaseModel):
    """Operator edits to a template: mark it the active one and/or set its grow policy."""

    is_active: bool | None = None
    grow_policy: dict[str, int] | None = None
    grow_mode: str | None = None   # 'percent' | 'absolute'


class PlannedHostIn(BaseModel):
    """A bare-metal target planned before it exists: it becomes an Agent in state 'planned', configured
    with roles (via the normal Management tab) and network, then armed and installed."""

    hostname: str
    mac: str = ""
    network: dict = {}   # {mode: dhcp|static, interface?, address (CIDR), gateway?, dns: [...]}
    # Catalog roles/features (package_catalog names) chosen offline in the wizard. Stored on the planned
    # host now and PUSHED after the first boot — the host does not exist yet, so nothing is installed here.
    roles: list[str] = []


# The volume roles a grow policy may size — the ones imaging.classify_role can grow independently.
_GROWABLE_ROLES = {"root", "var", "home", "data"}


class ImageOut(BaseModel):
    id: UUID
    name: str
    description: str
    source_agent_id: UUID | None
    status: str
    created_at: datetime
    error: str | None = None
    progress: str = ""
    is_active: bool = False
    grow_policy: dict = {}
    grow_mode: str = "percent"
    # Derived, so the caller does not have to understand the manifest to see the shape of an image.
    disk_size: int = 0
    firmware: str = "unknown"   # uefi | bios | unknown — which boot path this image expects
    volumes: list[dict] = []
    stored_bytes: int = 0

    @classmethod
    def from_model(cls, img: DiskImage) -> "ImageOut":
        manifest = img.manifest or {}
        files = img.files or {}
        return cls(
            firmware=_firmware_of(manifest),
            id=img.id,
            name=img.name,
            description=img.description,
            source_agent_id=img.source_agent_id,
            status=img.status,
            created_at=img.created_at,
            error=img.error,
            progress=img.progress or "",
            is_active=bool(img.is_active),
            grow_policy=dict(img.grow_policy or {}),
            grow_mode=img.grow_mode or "percent",
            disk_size=int(manifest.get("disk_size") or 0),
            volumes=[
                {
                    "role": v.get("role"),
                    "fs_type": v.get("fs_type"),
                    "size_bytes": v.get("size_bytes"),
                    "used_bytes": v.get("used_bytes"),
                    # LVM info so the UI can show the VG/LV structure and which volumes are grow-adjustable.
                    "vg": v.get("vg"),
                    "lv": v.get("lv"),
                    "mountpoint": v.get("mountpoint"),
                }
                for v in manifest.get("volumes") or []
            ],
            stored_bytes=sum(int((f or {}).get("bytes") or 0) for f in files.values()),
        )


@router.get("/api/v1/images", response_model=list[ImageOut])
async def list_images(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[ImageOut]:
    rows = (await session.scalars(select(DiskImage).order_by(DiskImage.name))).all()
    return [ImageOut.from_model(i) for i in rows]


@router.get("/api/v1/images/{image_id}", response_model=ImageOut)
async def get_image(
    image_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ImageOut:
    return ImageOut.from_model(await _image_or_404(session, image_id))


@router.patch("/api/v1/images/{image_id}", response_model=ImageOut)
async def patch_image(
    image_id: UUID,
    body: ImagePatch,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ImageOut:
    """Mark a template active (only one at a time) and/or set its grow policy (root/var/home %)."""
    img = await _image_or_404(session, image_id)
    if body.grow_mode is not None:
        if body.grow_mode not in ("percent", "absolute"):
            raise HTTPException(status_code=422, detail="grow_mode must be 'percent' or 'absolute'")
        img.grow_mode = body.grow_mode
    if body.grow_policy is not None:
        policy = {k: int(v) for k, v in body.grow_policy.items()}
        unknown = set(policy) - _GROWABLE_ROLES
        if unknown:
            raise HTTPException(status_code=422, detail=f"unknown grow-policy roles: {sorted(unknown)}")
        if any(v < 0 for v in policy.values()):
            raise HTTPException(status_code=422, detail="grow-policy values must be non-negative")
        # Percentages must sum to 100; absolute GiB sizes have no such constraint (a 0 fills the rest, and
        # plan_restore checks the sizes fit the real target disk at check-in).
        mode = body.grow_mode if body.grow_mode is not None else (img.grow_mode or "percent")
        # No sum constraint here: the LAST growable volume absorbs whatever is left (+100%FREE), so the
        # percentages of the other volumes need not add up to any particular figure, and no volume is ever
        # shrunk below its own filesystem. Whether the requested sizes actually FIT is decided at restore
        # time against the real target disk (plan_restore raises "grow_policy does not fit" if they don't) —
        # it cannot be known here, where the target size is unknown.
        img.grow_policy = policy
    if body.is_active is not None:
        if body.is_active:
            if img.status != "ready":
                raise HTTPException(status_code=409, detail="only a ready image can be the active template")
            # Exactly one active template: clear the others first, then set this one (the partial
            # unique index would otherwise reject two actives within the same transaction).
            await session.execute(
                update(DiskImage).where(DiskImage.id != img.id, DiskImage.is_active.is_(True)).values(is_active=False)
            )
            await session.flush()
        img.is_active = body.is_active
    await session.commit()
    return ImageOut.from_model(img)


@router.post("/api/v1/provisioning/hosts", status_code=201)
async def create_planned_host(
    body: PlannedHostIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """Create a bare-metal target as an Agent in state 'planned'. It then shows up in the fleet like any
    host, so roles are assigned through the normal Management tab; the netboot check-in enrol-links it by
    hostname. The MAC + final network are kept in agent_metadata until the install writes them."""
    hostname = body.hostname.strip()
    if not hostname:
        raise HTTPException(status_code=422, detail="hostname is required")
    new_meta: dict = {}
    if body.mac:
        new_meta["provision_mac"] = normalise_mac(body.mac)
    if body.network:
        new_meta["provision_network"] = body.network
    if body.roles:
        # Kept offline until the host is up; the post-boot role push reads this back (Block B3).
        new_meta["provision_roles"] = list(body.roles)
    existing = await session.scalar(select(Agent).where(Agent.name == hostname))
    if existing is not None:
        # Re-provisioning (reimage): update the provisioning metadata and move the host back to 'planned'
        # rather than refusing — so an operator can re-arm an existing host with a fresh MAC/network,
        # which the check-in's offline-enrol then writes into the freshly restored root.
        meta = dict(existing.agent_metadata or {})
        meta.update(new_meta)
        existing.agent_metadata = meta
        existing.enrollment_state = "planned"
        await session.commit()
        return {"id": str(existing.id), "hostname": hostname, "enrollment_state": "planned",
                "mac": meta.get("provision_mac", ""), "network": body.network,
                "roles": meta.get("provision_roles", [])}
    agent = Agent(
        name=hostname, address=None, token=secrets.token_hex(16), mode="standalone",
        enrollment_state="planned", agent_metadata=new_meta,
    )
    session.add(agent)
    await session.commit()
    return {"id": str(agent.id), "hostname": hostname, "enrollment_state": "planned",
            "mac": new_meta.get("provision_mac", ""), "network": body.network,
            "roles": new_meta.get("provision_roles", [])}


# ---------------------------------------------------------------------------
# Deployment templates — reusable deploy recipes (image + grow policy + network + roles), so the wizard can
# prefill everything except the per-machine hostname/MAC.


class DeploymentTemplateIn(BaseModel):
    name: str
    description: str = ""
    image_id: UUID | None = None
    grow_mode: str = "percent"
    grow_policy: dict[str, int] = {}
    network: dict = {}
    roles: list[str] = []


class DeploymentTemplateOut(BaseModel):
    id: UUID
    name: str
    description: str
    image_id: UUID | None
    grow_mode: str
    grow_policy: dict
    network: dict
    roles: list[str]
    created_at: datetime

    @classmethod
    def from_model(cls, t: "DeploymentTemplate") -> "DeploymentTemplateOut":
        return cls(
            id=t.id, name=t.name, description=t.description, image_id=t.image_id,
            grow_mode=t.grow_mode, grow_policy=dict(t.grow_policy or {}),
            network=dict(t.network or {}), roles=list(t.roles or []), created_at=t.created_at,
        )


@router.get("/api/v1/provisioning/templates", response_model=list[DeploymentTemplateOut])
async def list_deployment_templates(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> list[DeploymentTemplateOut]:
    rows = (await session.scalars(select(DeploymentTemplate).order_by(DeploymentTemplate.name))).all()
    return [DeploymentTemplateOut.from_model(t) for t in rows]


@router.post("/api/v1/provisioning/templates", response_model=DeploymentTemplateOut, status_code=201)
async def save_deployment_template(
    body: DeploymentTemplateIn,
    session: AsyncSession = Depends(get_session), identity=Depends(get_current_identity),
) -> DeploymentTemplateOut:
    """Create or overwrite a template by name (idempotent save): re-saving under the same name updates it,
    so the wizard's "Save as template" is a plain upsert rather than a create-then-409."""
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="template name is required")
    if body.grow_mode not in ("percent", "absolute"):
        raise HTTPException(status_code=422, detail="grow_mode must be 'percent' or 'absolute'")
    existing = await session.scalar(select(DeploymentTemplate).where(DeploymentTemplate.name == name))
    t = existing or DeploymentTemplate(name=name)
    t.description = body.description
    t.image_id = body.image_id
    t.grow_mode = body.grow_mode
    t.grow_policy = {k: int(v) for k, v in body.grow_policy.items()}
    t.network = body.network
    t.roles = list(body.roles)
    if existing is None:
        t.created_by = getattr(identity, "name", None)
        session.add(t)
    await session.commit()
    return DeploymentTemplateOut.from_model(t)


@router.delete("/api/v1/provisioning/templates/{template_id}", status_code=204)
async def delete_deployment_template(
    template_id: UUID,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> None:
    t = await session.get(DeploymentTemplate, template_id)
    if t is not None:
        await session.delete(t)
        await session.commit()


# ---------------------------------------------------------------------------
# VM hosts — hypervisors (Proxmox / vCenter) the provisioner can create VMs on. Credentials are
# vault-encrypted; the kind is auto-detected from host+credentials, not chosen.


class VmHostIn(BaseModel):
    name: str
    host: str
    username: str
    password: str
    verify_tls: bool = False


class VmHostOut(BaseModel):
    id: UUID
    name: str
    kind: str
    host: str
    username: str
    verify_tls: bool
    created_at: datetime

    @classmethod
    def from_model(cls, h: "VmHost") -> "VmHostOut":
        return cls(id=h.id, name=h.name, kind=h.kind, host=h.host, username=h.username,
                   verify_tls=bool(h.verify_tls), created_at=h.created_at)


def _vault() -> Vault:
    s = get_settings()
    return Vault(s.vault_key, s.vault_key_path)


@router.get("/api/v1/provisioning/vm-hosts", response_model=list[VmHostOut])
async def list_vm_hosts(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> list[VmHostOut]:
    rows = (await session.scalars(select(VmHost).order_by(VmHost.name))).all()
    return [VmHostOut.from_model(h) for h in rows]


@router.post("/api/v1/provisioning/vm-hosts", response_model=VmHostOut, status_code=201)
async def create_vm_host(
    body: VmHostIn,
    session: AsyncSession = Depends(get_session), identity=Depends(get_current_identity),
) -> VmHostOut:
    """Register a hypervisor: detect whether it is Proxmox or vCenter from the host + credentials (the
    operator does not choose), then store it with the password vault-encrypted. Detection failure is a 422
    with the probe's reason, so a wrong host/credential is obvious."""
    name = body.name.strip()
    host = body.host.strip()
    if not name or not host:
        raise HTTPException(status_code=422, detail="name and host are required")
    try:
        kind = await hypervisor.detect(host, body.username, body.password, verify_tls=body.verify_tls)
    except hypervisor.HypervisorError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    existing = await session.scalar(select(VmHost).where(VmHost.name == name))
    row = existing or VmHost(name=name)
    row.kind = kind
    row.host = host
    row.username = body.username
    row.secret = _vault().encrypt(body.password)
    row.verify_tls = body.verify_tls
    if existing is None:
        row.created_by = getattr(identity, "name", None)
        session.add(row)
    await session.commit()
    return VmHostOut.from_model(row)


@router.delete("/api/v1/provisioning/vm-hosts/{host_id}", status_code=204)
async def delete_vm_host(
    host_id: UUID,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> None:
    row = await session.get(VmHost, host_id)
    if row is not None:
        await session.delete(row)
        await session.commit()


class VmCreateIn(BaseModel):
    """Create a VM on a registered hypervisor, set up to PXE-install. The MAC it returns is what the caller
    arms the restore job against."""
    node: str                       # Proxmox node (or ESXi host for vCenter, later)
    name: str
    storage: str                    # datastore/storage for the disk (+ EFI disk on UEFI)
    bridge: str                     # network/bridge/portgroup the NIC attaches to
    cores: int = 2
    memory_mb: int = 2048
    disk_gib: int = 32
    uefi: bool = False
    vlan: int | None = None         # optional NIC VLAN tag


@router.post("/api/v1/provisioning/vm-hosts/{host_id}/create-vm")
async def create_vm(
    host_id: UUID, body: VmCreateIn,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict:
    """Create + start a PXE-install VM on this hypervisor and return {vmid, mac}. The caller then creates a
    planned host with that MAC and arms the restore job — the VM PXE-boots into the restore. VM creation is
    optional provisioning: the bare-metal path (an operator-typed MAC) is unchanged."""
    row = await session.get(VmHost, host_id)
    if row is None:
        raise HTTPException(status_code=404, detail="no such VM host")
    password = _vault().decrypt(row.secret)
    try:
        client = (hypervisor.ProxmoxClient if row.kind == "proxmox" else hypervisor.VCenterClient)(
            row.host, row.username, password, verify_tls=row.verify_tls)
        return await client.create_vm(
            body.node, body.name.strip(), cores=body.cores, memory_mb=body.memory_mb,
            disk_gib=body.disk_gib, storage=body.storage, bridge=body.bridge,
            uefi=body.uefi, vlan=body.vlan)
    except hypervisor.HypervisorError as exc:
        raise HTTPException(status_code=502, detail=f"VM creation failed: {exc}") from exc


@router.get("/api/v1/provisioning/vm-hosts/{host_id}/placement")
async def vm_host_placement(
    host_id: UUID,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict:
    """What a VM needs placed on this hypervisor: nodes/hosts, the storages/datastores that can hold a disk,
    and the networks/bridges a NIC attaches to — so the wizard can offer them."""
    row = await session.get(VmHost, host_id)
    if row is None:
        raise HTTPException(status_code=404, detail="no such VM host")
    password = _vault().decrypt(row.secret)
    try:
        client = (hypervisor.ProxmoxClient if row.kind == "proxmox" else hypervisor.VCenterClient)(
            row.host, row.username, password, verify_tls=row.verify_tls)
        return await client.placement()
    except hypervisor.HypervisorError as exc:
        raise HTTPException(status_code=502, detail=f"hypervisor query failed: {exc}") from exc


@router.post("/api/v1/images", response_model=ImageOut, status_code=201)
async def create_image(
    body: ImageIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ImageOut:
    """Register an image and mark it `capturing`. The capture itself runs on the source host."""
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="name is required")
    if await session.scalar(select(DiskImage).where(DiskImage.name == name)) is not None:
        raise HTTPException(status_code=409, detail=f"an image named {name!r} already exists")
    if body.source_agent_id is not None and await session.get(Agent, body.source_agent_id) is None:
        raise HTTPException(status_code=422, detail=f"no such host {body.source_agent_id}")
    img = DiskImage(
        name=name, description=body.description, source_agent_id=body.source_agent_id, status="capturing"
    )
    session.add(img)
    await session.commit()
    return ImageOut.from_model(img)


class ImageImportIn(BaseModel):
    """Ingest an existing disk image already staged in the lab's DISK_DIR as a golden template — the
    'I already have an installed OS' path, parallel to installing from an ISO."""

    name: str
    source_file: str   # bare filename in the lab's DISK_DIR (vmdk/qcow2/raw/img)
    description: str = ""


@router.get("/api/v1/images/import/sources", response_model=list[str])
async def list_import_sources(_identity=Depends(get_current_identity)) -> list[str]:
    """Disk-image files staged in the lab (what the WebUI Import picker offers)."""
    try:
        return await vm_lab.list_sources()
    except vm_lab.VmLabError as exc:
        code = 503 if "not configured" in str(exc) else 400
        raise HTTPException(status_code=code, detail=str(exc))


@router.post("/api/v1/images/import", response_model=ImageOut, status_code=201)
async def import_existing_image(
    body: ImageImportIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ImageOut:
    """Create the DiskImage (capturing) and launch import-image.sh detached in the pxe container; it
    captures every volume and finishes the image itself (via the per-image token), so the WebUI just
    watches the image go capturing → ready (or failed)."""
    settings = get_settings()
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="name is required")
    source = body.source_file.strip()
    if not source or "/" in source:
        raise HTTPException(status_code=422, detail="source_file must be a bare filename in the lab's DISK_DIR")
    if await session.scalar(select(DiskImage).where(DiskImage.name == name)) is not None:
        raise HTTPException(status_code=409, detail=f"an image named {name!r} already exists")
    # The script calls back into this API, so it needs a Bossman URL reachable from the pxe container
    # (host network) — the same address agent enrolment uses.
    bossman_url = settings.public_url
    if not bossman_url:
        raise HTTPException(status_code=400, detail="set BOSSMAN_PUBLIC_URL (reachable from the pxe container) to import")
    img = DiskImage(name=name, description=body.description, status="capturing")
    session.add(img)
    await session.commit()
    token = image_upload_token(settings, img.id)
    try:
        await vm_lab.start_import(source, str(img.id), token, bossman_url.rstrip("/"))
    except vm_lab.VmLabError as exc:
        img.status = "failed"
        img.error = str(exc)
        await session.commit()
        code = 503 if "not configured" in str(exc) else 400
        raise HTTPException(status_code=code, detail=str(exc))
    return ImageOut.from_model(img)


class CapturePlanIn(BaseModel):
    lsblk: dict   # `lsblk -b --json -O <disk>` (top-level, with "blockdevices")
    sfdisk: dict = {}


@router.post("/api/v1/images/{image_id}/capture-plan")
async def capture_plan(
    image_id: UUID,
    body: CapturePlanIn,
    x_image_token: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Plan a capture the same way the restore plans an install: the container reports lsblk+sfdisk and
    gets back the manifest (layout_to_dict) plus the per-volume list (stem/fs/partclone tool + how to
    address the volume). Token-auth'd, since it is the capturing import driving it, not an operator."""
    settings = get_settings()
    _require_image_token(settings, image_id, x_image_token)
    img = await _image_or_404(session, image_id)
    if img.status != "capturing":
        raise HTTPException(status_code=409, detail=f"image is {img.status}; only a capturing image plans a capture")
    disks = (body.lsblk or {}).get("blockdevices") or []
    if not disks:
        raise HTTPException(status_code=422, detail="lsblk reported no block device")
    try:
        layout = imaging.parse_layout(sfdisk=body.sfdisk or None, lsblk_disk=disks[0])
    except imaging.ImagingError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    volumes = [
        {
            "stem": imaging.image_stem(v),
            "fs": v.fs_type,
            "tool": imaging.partclone_tool(v.fs_type),
            "partition": v.partition,
            "vg": v.vg,
            "lv": v.lv,
        }
        for v in layout.volumes
    ]
    return {"manifest": imaging.layout_to_dict(layout), "volumes": volumes}


class ImportProgressIn(BaseModel):
    message: str = ""
    percent: int | None = None


@router.post("/api/v1/images/{image_id}/import-progress", response_model=ImageOut)
async def import_progress(
    image_id: UUID,
    body: ImportProgressIn,
    x_image_token: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> ImageOut:
    """The import script reports progress so the WebUI can show a live bar while status is 'capturing'."""
    settings = get_settings()
    _require_image_token(settings, image_id, x_image_token)
    img = await _image_or_404(session, image_id)
    pct = "" if body.percent is None else f" · {max(0, min(100, int(body.percent)))}%"
    img.progress = (body.message + pct)[:200]
    await session.commit()
    return ImageOut.from_model(img)


class ImportFailedIn(BaseModel):
    error: str = "import failed"


@router.post("/api/v1/images/{image_id}/import-failed", response_model=ImageOut)
async def import_failed(
    image_id: UUID,
    body: ImportFailedIn,
    x_image_token: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> ImageOut:
    """The import script reports a failure so the WebUI shows the reason instead of a stuck 'capturing'."""
    settings = get_settings()
    _require_image_token(settings, image_id, x_image_token)
    img = await _image_or_404(session, image_id)
    if img.status == "ready":
        raise HTTPException(status_code=409, detail="image is already ready")
    img.status = "failed"
    img.error = body.error[:2000]
    await session.commit()
    return ImageOut.from_model(img)


@router.delete("/api/v1/images/{image_id}", status_code=204)
async def delete_image(
    image_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    """Deleting an image deletes its restore-job history with it (ON DELETE CASCADE), so an active
    job blocks the delete — otherwise a machine mid-install would lose the plan it is executing."""
    img = await _image_or_404(session, image_id)
    active = await session.scalar(
        select(RestoreJob).where(
            RestoreJob.image_id == image_id, RestoreJob.status.in_(("pending", "running"))
        )
    )
    if active is not None:
        raise HTTPException(
            status_code=409,
            detail=f"restore job {active.id} is still {active.status}; cancel it before deleting the image",
        )
    await session.delete(img)
    await session.commit()


# ---------------------------------------------------------------------------
# Restore jobs


class RestoreJobIn(BaseModel):
    image_id: UUID
    # Empty = a wildcard job: the next machine that PXE-boots (and check-ins with no MAC-specific job of
    # its own) claims it. With a MAC, only that exact machine installs.
    target_mac: str = ""
    target_hostname: str
    # An explicit disk choice; otherwise the largest non-removable one the target reports.
    target_disk: str | None = None


class RestoreJobOut(BaseModel):
    id: UUID
    image_id: UUID
    target_mac: str
    target_hostname: str
    target_disk: str | None
    status: str
    step_index: int
    step_count: int
    error: str | None
    created_at: datetime
    started_at: datetime | None
    finished_at: datetime | None

    @classmethod
    def from_model(cls, job: RestoreJob) -> "RestoreJobOut":
        return cls(
            id=job.id, image_id=job.image_id, target_mac=job.target_mac,
            target_hostname=job.target_hostname, target_disk=job.target_disk, status=job.status,
            step_index=job.step_index, step_count=len(job.steps or []), error=job.error,
            created_at=job.created_at, started_at=job.started_at, finished_at=job.finished_at,
        )


def normalise_mac(raw: str) -> str:
    """Lower-case, colon-separated. A MAC is the job's key, and the wire spells it many ways.

    PXE firmware, dnsmasq and operators typing by hand produce `AA-BB-CC-DD-EE-FF`,
    `aabb.ccdd.eeff` and `AA:BB:...` for the same machine. Without normalising, a target checks in
    and finds no job that plainly exists — the most confusing possible failure, because the row is
    right there.
    """
    hexes = "".join(c for c in (raw or "").lower() if c in "0123456789abcdef")
    if len(hexes) != 12:
        raise HTTPException(status_code=422, detail=f"not a MAC address: {raw!r}")
    return ":".join(hexes[i : i + 2] for i in range(0, 12, 2))


@router.get("/api/v1/restore-jobs", response_model=list[RestoreJobOut])
async def list_restore_jobs(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[RestoreJobOut]:
    rows = (await session.scalars(select(RestoreJob).order_by(RestoreJob.created_at.desc()))).all()
    return [RestoreJobOut.from_model(j) for j in rows]


@router.post("/api/v1/restore-jobs", response_model=RestoreJobOut, status_code=201)
async def create_restore_job(
    body: RestoreJobIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> RestoreJobOut:
    """Arm a machine for installation. No steps yet — they are computed when it checks in and says
    which disks it has, because that is the first moment anyone knows."""
    img = await _image_or_404(session, body.image_id)
    if img.status != "ready":
        raise HTTPException(
            status_code=409, detail=f"image {img.name!r} is {img.status}, not ready to deploy"
        )
    # MAC optional: blank arms a wildcard job (target_mac == "") that the next machine to boot claims.
    raw_mac = (body.target_mac or "").strip()
    mac = normalise_mac(raw_mac) if raw_mac else ""
    hostname = body.target_hostname.strip()
    if not hostname:
        raise HTTPException(status_code=422, detail="target_hostname is required")
    existing = await session.scalar(
        select(RestoreJob).where(
            RestoreJob.target_mac == mac, RestoreJob.status.in_(("pending", "running"))
        )
    )
    if existing is not None:
        # The database enforces this too (partial unique index); answering here makes it a clear
        # 409 instead of an integrity error.
        detail = (
            "a wildcard job is already armed (the next machine to boot claims it) — cancel it first"
            if mac == ""
            else f"{mac} already has an active job ({existing.status})"
        )
        raise HTTPException(status_code=409, detail=detail)
    # Link the job to a pre-planned host (an Agent already created + configured with roles/network) if one
    # exists for this hostname, so its config is in place before the install and check-in only has to
    # enrol-link it. The netboot check-in enrols by the same hostname, flipping 'planned' → 'enrolled'.
    planned = await session.scalar(select(Agent).where(Agent.name == hostname))
    job = RestoreJob(
        image_id=img.id, target_mac=mac, target_hostname=hostname, target_disk=body.target_disk,
        agent_id=planned.id if planned is not None else None,
    )
    session.add(job)
    await session.commit()
    return RestoreJobOut.from_model(job)


@router.post("/api/v1/restore-jobs/{job_id}/cancel", response_model=RestoreJobOut)
async def cancel_restore_job(
    job_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> RestoreJobOut:
    """Cancelling a *running* job does not stop the machine — it has the plan already and no channel
    back. It marks our intent and frees the MAC; the target has to be reset by hand."""
    job = await session.get(RestoreJob, job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="no such restore job")
    if job.status in ("done", "failed", "cancelled"):
        raise HTTPException(status_code=409, detail=f"job is already {job.status}")
    job.status = "cancelled"
    job.finished_at = datetime.now(timezone.utc)
    await session.commit()
    return RestoreJobOut.from_model(job)


@router.delete("/api/v1/restore-jobs/{job_id}", status_code=204)
async def delete_restore_job(
    job_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    """Remove a finished job from the list. A still-active job must be cancelled first — deleting one
    mid-install would just lose the record of what a machine is currently doing."""
    job = await session.get(RestoreJob, job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="no such restore job")
    if job.status in ("pending", "running"):
        raise HTTPException(status_code=409, detail=f"job is {job.status}; cancel it before deleting")
    await session.delete(job)
    await session.commit()


# ---------------------------------------------------------------------------
# The netboot helper's side


class CheckinIn(BaseModel):
    mac: str
    # `lsblk -b --json -o NAME,TYPE,RM,SIZE`'s blockdevices, verbatim.
    blockdevices: list[dict] = []


class CheckinOut(BaseModel):
    job_id: UUID
    hostname: str
    target_disk: str
    image_base_url: str
    sfdisk_script: str
    # Coarse phase list for progress/audit (RestoreJobOut.step_count). The real work is the two
    # Ansible restore runbooks below, run by the PE via `agentic-mcpd run-runbook`.
    steps: list[dict]
    # Phase 1 (PE context): canonical runbook doc + the vars it loops over (resolved from the layout).
    pe_runbook: dict = {}
    pe_vars: dict = {}
    # The ephemeral target-tree mounts the PE sets up between the two phases (parents-first).
    mounts: list[dict] = []
    # Phase 2 (chroot /mnt/target): canonical runbook doc + vars (firmware/hostname/network).
    target_runbook: dict = {}
    target_vars: dict = {}
    # The offline agent enrol, kept as chroot shell steps (token-specific dpkg install) run after phase 2.
    agent_install_steps: list[dict] = []


async def _require_netboot(session: AsyncSession, presented: str | None) -> None:
    """Gate the /netboot/* endpoints. The DB SystemSettings is authoritative: netboot must be enabled
    (WebUI toggle) and the presented secret must match the DB secret — or the BOSSMAN_NETBOOT_SECRET env
    when no DB secret is set (env is the fallback value, not a bypass). Fail closed on every check so
    deploying this code never opens an unauthenticated install endpoint."""
    sys = await session.get(SystemSettings, UUID(SYSTEM_SETTINGS_ID))
    env_secret = get_settings().netboot_secret
    db_secret = sys.netboot_secret if (sys and sys.netboot_secret) else ""
    if db_secret:
        # A secret was entered in the WebUI → the DB is authoritative and the toggle governs on/off.
        enabled, effective = bool(sys.netboot_enabled), db_secret
    else:
        # Legacy/bootstrap: no WebUI secret yet → the BOSSMAN_NETBOOT_SECRET env governs (its presence is
        # "on"). This keeps env-only deploys working; entering a secret in the UI switches to the toggle.
        enabled, effective = bool(env_secret), env_secret
    if not enabled:
        raise HTTPException(status_code=403, detail="netboot is disabled")
    if not effective:
        raise HTTPException(status_code=403, detail="netboot check-in is disabled (no secret configured)")
    if presented != effective:
        raise HTTPException(status_code=403, detail="bad netboot secret")


@router.get("/api/v1/netboot/pending")
async def netboot_pending(
    x_netboot_secret: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Whether the PXE DHCP should be answering right now: true iff a restore job is armed (pending) or
    mid-flight (running). The pxe container polls this and toggles dnsmasq's DHCP, so it only serves boot
    requests while there is actually an order to fulfil — no standing DHCP/PXE on the segment otherwise."""
    await _require_netboot(session, x_netboot_secret)
    count = await session.scalar(
        select(func.count()).select_from(RestoreJob).where(RestoreJob.status.in_(("pending", "running")))
    )
    return {"pending": int(count or 0), "dhcp": bool(count)}


@router.get("/api/v1/netboot/config")
async def netboot_config(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """The effective netboot state for the pxe container to consume, so the WebUI is the ONLY source of
    the secret — no env/override to keep in sync. Returns the secret only to an ENROLLED agent (the
    pxe-lab host proving itself with its own token) and only while netboot is enabled; the container
    stamps it onto the PXE kernel cmdline and gates DHCP on `dhcp`."""
    token = (authorization or "").removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="missing agent token")
    agent = await session.scalar(select(Agent).where(Agent.token == token))
    if agent is None:
        raise HTTPException(status_code=403, detail="not an enrolled agent")
    sys = await session.get(SystemSettings, UUID(SYSTEM_SETTINGS_ID))
    env_secret = get_settings().netboot_secret
    db_secret = sys.netboot_secret if (sys and sys.netboot_secret) else ""
    if db_secret:
        enabled, secret = bool(sys.netboot_enabled), db_secret
    else:
        enabled, secret = bool(env_secret), env_secret
    pending = await session.scalar(
        select(func.count()).select_from(RestoreJob).where(RestoreJob.status.in_(("pending", "running")))
    )
    return {
        "enabled": enabled,
        "secret": secret if enabled else "",
        "dhcp": bool(enabled and (pending or 0) > 0),
    }


@router.post("/api/v1/netboot/checkin", response_model=CheckinOut)
async def netboot_checkin(
    body: CheckinIn,
    request: Request,
    x_netboot_secret: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> CheckinOut:
    """A netbooted machine reports its MAC and disks and receives its plan.

    This is where the restore is planned, because it is the first moment the target's real disk size
    is known — and that size is what decides how far the last volume grows.
    """
    settings = get_settings()
    await _require_netboot(session, x_netboot_secret)
    mac = normalise_mac(body.mac)
    job = await session.scalar(
        select(RestoreJob)
        .where(RestoreJob.target_mac == mac, RestoreJob.status.in_(("pending", "running")))
        .order_by(RestoreJob.created_at)
    )
    if job is None:
        # No MAC-specific job — fall back to a wildcard job (armed without a MAC). The first machine to
        # boot claims it: stamp its MAC on now, so it becomes a normal per-MAC job (and progress/retries
        # find it by MAC like any other).
        job = await session.scalar(
            select(RestoreJob)
            .where(RestoreJob.target_mac == "", RestoreJob.status.in_(("pending", "running")))
            .order_by(RestoreJob.created_at)
        )
        if job is not None:
            job.target_mac = mac
    if job is None:
        raise HTTPException(status_code=404, detail=f"no job armed for {mac}")
    img = await _image_or_404(session, job.image_id)

    # The grow policy comes from the template (root/var/home sizes) and is snapshotted onto the job, so a
    # retry reproduces the exact partitioning even if the template is edited later. grow_mode says whether
    # the values are percentages of the leftover or absolute GiB.
    grow_policy = dict(img.grow_policy or {})
    grow_mode = img.grow_mode or "percent"
    # The FINAL network the target should boot onto (from the planned host's config), written into the
    # restored root so it comes up on its destination segment, not the rollout/PXE one.
    net = None
    if job.agent_id is not None:
        planned = await session.get(Agent, job.agent_id)
        if planned is not None:
            net = (planned.agent_metadata or {}).get("provision_network")
    try:
        layout = imaging.layout_from_dict(img.manifest or {})
        target = imaging.select_target_disk(body.blockdevices, prefer=job.target_disk)
        plan = imaging.plan_restore(layout, target, grow_policy or None, grow_mode=grow_mode)
        # The target's own agent, installed into the mounted root as the last configuring act. Minted
        # here rather than when the job was armed, because a token handed out before the machine even
        # netbooted would be a live credential sitting in the database for however long the job waited.
        install = offline_enroll.plan_offline_install(settings, job.target_hostname)
        # Playbook-driven restore: resolve the layout into the vars the two Ansible restore playbooks
        # loop over, and load the playbooks as canonical runbook docs. The PE runs them with run-runbook
        # (phase 1 in the PE, phase 2 chroot'd into /mnt/target). Network is a task in phase 2
        # (yoloman.network_interface, via target_vars.network); the agent enrol stays as chroot shell steps.
        rvars = imaging.restore_vars(
            layout, plan, image_url=_image_url(settings, img), hostname=job.target_hostname, network=net,
        )
        pe_runbook = _restore_runbook(settings, "restore-pe-phase")
        target_runbook = _restore_runbook(settings, "restore-target-phase")
        agent_install = offline_enroll.offline_install_steps(install, deb_url=_agent_deb_url(settings))
    except imaging.ImagingError as exc:
        # A plan that cannot be made is the job's failure, recorded where an operator will look,
        # rather than a 500 that only exists in a log.
        job.status = "failed"
        job.error = str(exc)
        job.finished_at = datetime.now(timezone.utc)
        await session.commit()
        raise HTTPException(status_code=409, detail=str(exc)) from exc

    job.status = "running"
    job.target_disk = target.name
    job.grow_policy = grow_policy
    # Coarse phase list — the PE reports progress per phase (the fine-grained per-module results live in
    # each run-runbook's own output). Keeps RestoreJobOut.step_count meaningful without tracking every task.
    job.steps = [
        {"name": "restore (PE phase): partition, LVM, image, grow"},
        {"name": "configure (target phase): bootloader, initramfs, identity, network"},
        {"name": "enrol the agent into the target"},
    ]
    job.step_index = 0
    job.started_at = job.started_at or datetime.now(timezone.utc)
    # Enrol now, not on first boot: the agent row is what lets the booting agent be recognised at all.
    # The downtime it opens is what keeps this from paging — an enrolled host that has not reported is
    # DOWN and CRITICAL (L1), and this one will not report until it has finished installing and
    # rebooted. Checkin is the right moment to start that window, since it is when the work begins.
    await offline_enroll.record_offline_agent(
        session,
        job.target_hostname,
        token=install.token,
        listen_port=install.listen_port,
    )
    await session.commit()
    return CheckinOut(
        job_id=job.id,
        hostname=job.target_hostname,
        target_disk=target.name,
        image_base_url=_image_url(settings, img),
        sfdisk_script=imaging.sfdisk_script(layout) if layout.partitions else "",
        steps=job.steps,
        pe_runbook=pe_runbook,
        pe_vars=rvars["pe_vars"],
        mounts=rvars["mounts"],
        target_runbook=target_runbook,
        target_vars=rvars["target_vars"],
        agent_install_steps=[
            {"name": s.name, "argv": list(s.argv), "shell": s.shell, "chroot": s.chroot} for s in agent_install
        ],
    )


class ProgressIn(BaseModel):
    step_index: int
    log: str = ""
    failed: bool = False
    error: str | None = None
    done: bool = False


@router.post("/api/v1/netboot/progress/{job_id}", response_model=RestoreJobOut)
async def netboot_progress(
    job_id: UUID,
    body: ProgressIn,
    x_netboot_secret: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> RestoreJobOut:
    """The helper reports how far it got. Append-only log, monotonic index.

    The index never moves backwards: a retried step would otherwise make progress look like it
    regressed, and an operator watching a long install would read that as a loop.
    """
    settings = get_settings()
    await _require_netboot(session, x_netboot_secret)
    job = await session.get(RestoreJob, job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="no such restore job")
    if job.status not in ("pending", "running"):
        raise HTTPException(status_code=409, detail=f"job is {job.status}")

    job.step_index = max(job.step_index, int(body.step_index))
    if body.log:
        job.log = (job.log + body.log)[-64_000:]  # bounded: a runaway helper must not fill the table
    if body.failed:
        job.status = "failed"
        job.error = body.error or "the helper reported a failure without a reason"
        job.finished_at = datetime.now(timezone.utc)
    elif body.done:
        job.status = "done"
        job.finished_at = datetime.now(timezone.utc)
    await session.commit()
    return RestoreJobOut.from_model(job)


# ---------------------------------------------------------------------------
# The capture's side: streaming an image file in, and finishing the image


def image_upload_token(settings, image_id: UUID) -> str:
    """A token that authorises writing THIS image's files, and nothing else.

    Derived rather than stored: `HMAC(jwt_secret, "image:<id>")`, so there is no column to migrate,
    nothing to leak from the database, and no cleanup to forget. It is scoped to one image, so
    handing it to a capture running on a source host grants exactly the permission that capture
    needs — not a general API credential. Rotating `jwt_secret` invalidates every outstanding one,
    which is the correct blast radius.
    """
    secret = (settings.jwt_secret or "").encode()
    if not secret:
        raise HTTPException(status_code=503, detail="no jwt_secret configured; cannot mint an upload token")
    return hmac.new(secret, f"image:{image_id}".encode(), hashlib.sha256).hexdigest()[:32]


def _require_image_token(settings, image_id: UUID, presented: str | None) -> None:
    expected = image_upload_token(settings, image_id)
    # compare_digest, not ==: a timing-comparable check on a token is a bad habit to leave in a
    # codebase even where the practical risk is small.
    if not presented or not hmac.compare_digest(presented, expected):
        raise HTTPException(status_code=403, detail="bad or missing image upload token")


@router.put("/api/v1/images/{image_id}/files/{stem}")
async def upload_image_file(
    image_id: UUID,
    stem: str,
    request: Request,
    x_image_token: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Stream one volume's compressed image in, hashing it as it lands.

    Streamed, never buffered: these files are gigabytes, and reading one into memory to hash it
    would take the process down on the first real capture.

    The checksum is computed HERE, on what actually arrived, rather than being reported by the
    sender. That is the whole point — a truncated upload is exactly what a sender cannot notice,
    and a truncated image written to a disk is an unbootable machine that looks like a successful
    restore.
    """
    settings = get_settings()
    _require_image_token(settings, image_id, x_image_token)
    img = await _image_or_404(session, image_id)
    if img.status != "capturing":
        raise HTTPException(status_code=409, detail=f"image is {img.status}; only a capturing image accepts files")
    safe = _safe_stem(stem)

    target_dir = Path(settings.image_store_dir) / str(image_id)
    target_dir.mkdir(parents=True, exist_ok=True)
    name = f"{safe}.pcl.zst"
    # Write to a temporary name and rename at the end, so an interrupted upload never leaves a
    # partial file under the name a restore would fetch.
    tmp = target_dir / f".{name}.part"
    digest = hashlib.sha256()
    written = 0
    try:
        with tmp.open("wb") as fh:
            async for chunk in request.stream():
                if not chunk:
                    continue
                digest.update(chunk)
                written += len(chunk)
                fh.write(chunk)
        if written == 0:
            raise HTTPException(status_code=422, detail="empty upload")
        tmp.replace(target_dir / name)
    except HTTPException:
        tmp.unlink(missing_ok=True)
        raise
    except OSError as exc:
        tmp.unlink(missing_ok=True)
        raise HTTPException(status_code=507, detail=f"could not store the image file: {exc}") from exc

    files = dict(img.files or {})
    files[safe] = {"name": name, "bytes": written, "sha256": digest.hexdigest()}
    img.files = files
    await session.commit()
    return {"stem": safe, "name": name, "bytes": written, "sha256": digest.hexdigest()}


class FinishIn(BaseModel):
    # imaging.layout_to_dict's document, as probed on the source host.
    manifest: dict
    # Used bytes per image stem, as partclone actually measured them.
    used_bytes: dict[str, int] = {}


@router.post("/api/v1/images/{image_id}/finish", response_model=ImageOut)
async def finish_image(
    image_id: UUID,
    body: FinishIn,
    x_image_token: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> ImageOut:
    """Record the manifest, fold in the measured usage, and mark the image deployable.

    The image only becomes `ready` if it is actually restorable: the manifest must parse, every
    volume must have a stored file, and the usage must be known — otherwise `plan_restore` cannot
    even decide whether a target is big enough, and the failure would surface at 3am on the machine
    being installed instead of here.
    """
    settings = get_settings()
    _require_image_token(settings, image_id, x_image_token)
    img = await _image_or_404(session, image_id)
    if img.status == "ready":
        raise HTTPException(status_code=409, detail="image is already ready")

    try:
        layout = imaging.layout_from_dict(body.manifest)
        layout = imaging.with_measured_usage(layout, dict(body.used_bytes or {}))
        if layout.unknown_usage:
            raise imaging.ImagingError(
                "used size still unknown for: " + ", ".join(v.role for v in layout.unknown_usage)
            )
        total = layout.used_total  # raises if anything is still unknown
        missing = [
            imaging.image_stem(v) for v in layout.volumes if imaging.image_stem(v) not in (img.files or {})
        ]
        if missing:
            raise imaging.ImagingError("no uploaded file for: " + ", ".join(missing))
    except imaging.ImagingError as exc:
        img.status = "failed"
        img.error = str(exc)
        await session.commit()
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    img.manifest = imaging.layout_to_dict(layout)
    img.status = "ready"
    img.error = None
    await session.commit()
    assert total >= 0  # documents that used_total was evaluated for its validation side effect
    return ImageOut.from_model(img)


def _safe_stem(stem: str) -> str:
    """A stem is a file name component, so it must not be able to become a path.

    `../../etc/shadow` as a stem would otherwise let an upload write anywhere the process can. The
    allow-list is deliberately narrow: image stems are `role` or `role-lv`, which only ever contain
    letters, digits, dash and underscore.
    """
    cleaned = (stem or "").strip()
    if not cleaned or not all(c.isalnum() or c in "-_" for c in cleaned):
        raise HTTPException(status_code=422, detail=f"not a valid image stem: {stem!r}")
    return cleaned


async def _image_or_404(session: AsyncSession, image_id: UUID) -> DiskImage:
    img = await session.get(DiskImage, image_id)
    if img is None:
        raise HTTPException(status_code=404, detail="no such image")
    return img


def _restore_runbook(settings, name: str) -> dict:
    """Load one of the bare-metal restore playbooks and parse it into the canonical runbook doc the PE's
    `run-runbook` consumes. The playbooks live beside the wizard playbooks (configs/wizard_playbooks/).

    Two candidate roots, because `config_templates_dir` defaults to the CONTAINER layout (/app/…): the
    settings-derived one wins in a deployment, and the repo-relative one makes a source checkout (and the
    test suite) work without setting an env var.
    """
    from bossman.services.ansible_playbook import parse_playbook

    candidates = [
        Path(settings.config_templates_dir).parent / "wizard_playbooks" / f"{name}.yml",
        Path(__file__).resolve().parents[3] / "configs" / "wizard_playbooks" / f"{name}.yml",
    ]
    for path in candidates:
        if path.is_file():
            return parse_playbook(path.read_text()).to_dict()
    raise HTTPException(
        status_code=500,
        detail=f"restore playbook {name!r} not found (looked in: {', '.join(str(c) for c in candidates)})",
    )


def _image_url(settings, img: DiskImage) -> str:
    base = (settings.image_base_url or settings.public_url or "").rstrip("/")
    return f"{base}/images/{img.id}"


def _agent_deb_url(settings) -> str:
    """Where a netbooted target fetches the agent package.

    Served from the same store as the images, unauthenticated, and deliberately so: a netbooting
    machine has no credential before it checks in, which is why the images work the same way. Nothing
    secret rides along here — the package is the same one on every host, and the target's token and
    keys travel inside the authenticated checkin response instead.

    Contract with the netboot container (Phase 1): the image store root is served at `<base>/`, images
    under `<base>/images/<id>/`, and the agent package at `<base>/agent.deb`.
    """
    base = (settings.image_base_url or settings.public_url or "").rstrip("/")
    return f"{base}/agent.deb"
