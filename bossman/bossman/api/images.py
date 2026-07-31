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
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import get_settings
from bossman.db.models import Agent, DiskImage, RestoreJob
from bossman.db.session import get_session
from bossman.services import imaging

router = APIRouter()


# ---------------------------------------------------------------------------
# Images


class ImageIn(BaseModel):
    name: str
    description: str = ""
    source_agent_id: UUID | None = None


class ImageOut(BaseModel):
    id: UUID
    name: str
    description: str
    source_agent_id: UUID | None
    status: str
    created_at: datetime
    error: str | None = None
    # Derived, so the caller does not have to understand the manifest to see the shape of an image.
    disk_size: int = 0
    volumes: list[dict] = []
    stored_bytes: int = 0

    @classmethod
    def from_model(cls, img: DiskImage) -> "ImageOut":
        manifest = img.manifest or {}
        files = img.files or {}
        return cls(
            id=img.id,
            name=img.name,
            description=img.description,
            source_agent_id=img.source_agent_id,
            status=img.status,
            created_at=img.created_at,
            error=img.error,
            disk_size=int(manifest.get("disk_size") or 0),
            volumes=[
                {
                    "role": v.get("role"),
                    "fs_type": v.get("fs_type"),
                    "size_bytes": v.get("size_bytes"),
                    "used_bytes": v.get("used_bytes"),
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
    target_mac: str
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
    mac = normalise_mac(body.target_mac)
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
        raise HTTPException(
            status_code=409, detail=f"{mac} already has an active job ({existing.status})"
        )
    job = RestoreJob(
        image_id=img.id, target_mac=mac, target_hostname=hostname, target_disk=body.target_disk
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
    steps: list[dict]


def _require_netboot_secret(settings, presented: str | None) -> None:
    if not settings.netboot_secret:
        # Fail closed: deploying this code must not open an unauthenticated install endpoint.
        raise HTTPException(status_code=403, detail="netboot check-in is disabled (no secret configured)")
    if presented != settings.netboot_secret:
        raise HTTPException(status_code=403, detail="bad netboot secret")


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
    _require_netboot_secret(settings, x_netboot_secret)
    mac = normalise_mac(body.mac)
    job = await session.scalar(
        select(RestoreJob)
        .where(RestoreJob.target_mac == mac, RestoreJob.status.in_(("pending", "running")))
        .order_by(RestoreJob.created_at)
    )
    if job is None:
        raise HTTPException(status_code=404, detail=f"no job armed for {mac}")
    img = await _image_or_404(session, job.image_id)

    try:
        layout = imaging.layout_from_dict(img.manifest or {})
        target = imaging.select_target_disk(body.blockdevices, prefer=job.target_disk)
        plan = imaging.plan_restore(layout, target)
        steps = imaging.restore_steps(
            layout, plan, image_url=_image_url(settings, img), hostname=job.target_hostname
        )
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
    job.steps = [
        {"name": s.name, "argv": list(s.argv), "shell": s.shell, "chroot": s.chroot} for s in steps
    ]
    job.step_index = 0
    job.started_at = job.started_at or datetime.now(timezone.utc)
    await session.commit()
    return CheckinOut(
        job_id=job.id,
        hostname=job.target_hostname,
        target_disk=target.name,
        image_base_url=_image_url(settings, img),
        sfdisk_script=imaging.sfdisk_script(layout) if layout.partitions else "",
        steps=job.steps,
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
    _require_netboot_secret(settings, x_netboot_secret)
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


def _image_url(settings, img: DiskImage) -> str:
    base = (settings.image_base_url or settings.public_url or "").rstrip("/")
    return f"{base}/images/{img.id}"
